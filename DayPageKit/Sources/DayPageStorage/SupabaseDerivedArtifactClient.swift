import Foundation

/// JSON value used by backend artifact payloads. Keeping the payload typed at
/// the boundary avoids `Any`/`Sendable` holes while still allowing versioned
/// Skill schemas to evolve independently of the native release cadence.
public enum ArtifactJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ArtifactJSONValue])
    case array([ArtifactJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: ArtifactJSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([ArtifactJSONValue].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported artifact JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var stringArrayValue: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    public var objectValue: [String: ArtifactJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

public struct RemoteDerivedArtifact: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: String
    public let schemaVersion: Int
    public let logicalKey: String
    public let payload: [String: ArtifactJSONValue]
    public let bodyMarkdown: String?
    public let status: String
    public let revision: Int
    public let sourceSetHash: String?
    public let localDate: String?
    public let timezone: String?
    public let perspectiveKey: String
    public let finalizedAt: Date?
    public let createdAt: Date
    public let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, kind, payload, status, revision, timezone
        case schemaVersion = "schema_version"
        case logicalKey = "logical_key"
        case bodyMarkdown = "body_md"
        case sourceSetHash = "source_set_hash"
        case localDate = "local_date"
        case perspectiveKey = "perspective_key"
        case finalizedAt = "finalized_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public protocol DerivedArtifactRemote: Sendable {
    func fetchCanonicalArtifacts(limit: Int) async throws -> [RemoteDerivedArtifact]
    @discardableResult
    func requestDaily(localDate: String, timezone: String, finalize: Bool, explicitRetry: Bool) async throws -> UUID
    @discardableResult
    func requestWeekly(weekStart: String, timezone: String, explicitRetry: Bool) async throws -> UUID
}

/// User-session-backed PostgREST client for the backend-first derived plane.
/// It can read canonical artifacts and enqueue reducer work, but RLS grants it
/// no ability to author Agent Runs, steps, artifacts, or execution receipts.
public struct SupabaseDerivedArtifactClient: DerivedArtifactRemote {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private struct DailyRequest: Encodable {
        let localDate: String
        let timezone: String
        let finalize: Bool
        let explicitRetry: Bool

        enum CodingKeys: String, CodingKey {
            case localDate = "p_local_date"
            case timezone = "p_timezone"
            case finalize = "p_finalize"
            case explicitRetry = "p_explicit_retry"
        }
    }

    private struct WeeklyRequest: Encodable {
        let weekStart: String
        let timezone: String
        let explicitRetry: Bool

        enum CodingKeys: String, CodingKey {
            case weekStart = "p_week_start"
            case timezone = "p_timezone"
            case explicitRetry = "p_explicit_retry"
        }
    }

    public let supabaseURL: URL
    public let anonKey: String
    public let transport: HTTPTransport
    public let accessTokenProvider: AccessTokenProvider

    public init(
        supabaseURL: URL,
        anonKey: String,
        transport: HTTPTransport = HTTPTransports.shared,
        accessTokenProvider: @escaping AccessTokenProvider
    ) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.transport = transport
        self.accessTokenProvider = accessTokenProvider
    }

    public func fetchCanonicalArtifacts(limit: Int = 500) async throws -> [RemoteDerivedArtifact] {
        var components = URLComponents(
            url: restURL.appendingPathComponent("agent_artifacts"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,kind,schema_version,logical_key,payload,body_md,status,revision,source_set_hash,local_date,timezone,perspective_key,finalized_at,created_at,updated_at"),
            URLQueryItem(name: "perspective_key", value: "eq.canonical"),
            URLQueryItem(name: "status", value: "in.(live,needs_review)"),
            URLQueryItem(name: "kind", value: "in.(daily_page,weekly_review,observation)"),
            URLQueryItem(name: "order", value: "updated_at.desc"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 1_000))),
        ]
        guard let url = components?.url else { throw MemoSyncError.invalidResponse }
        let data = try await perform(url: url, method: "GET", body: Optional<Data>.none)
        do {
            return try Self.decoder.decode([RemoteDerivedArtifact].self, from: data)
        } catch {
            throw MemoSyncError.invalidResponse
        }
    }

    @discardableResult
    public func requestDaily(
        localDate: String,
        timezone: String,
        finalize: Bool = false,
        explicitRetry: Bool = false
    ) async throws -> UUID {
        try await requestJob(
            function: "daypage_request_daily_run",
            body: DailyRequest(
                localDate: localDate,
                timezone: timezone,
                finalize: finalize,
                explicitRetry: explicitRetry
            )
        )
    }

    @discardableResult
    public func requestWeekly(
        weekStart: String,
        timezone: String,
        explicitRetry: Bool = false
    ) async throws -> UUID {
        try await requestJob(
            function: "daypage_request_weekly_run",
            body: WeeklyRequest(
                weekStart: weekStart,
                timezone: timezone,
                explicitRetry: explicitRetry
            )
        )
    }

    private var restURL: URL {
        supabaseURL
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    private func requestJob<Body: Encodable>(function: String, body: Body) async throws -> UUID {
        let encoded = try JSONEncoder().encode(body)
        let data = try await perform(
            url: restURL.appendingPathComponent("rpc", isDirectory: true).appendingPathComponent(function),
            method: "POST",
            body: encoded
        )
        guard let raw = try? JSONDecoder().decode(String.self, from: data),
              let id = UUID(uuidString: raw) else {
            throw MemoSyncError.invalidResponse
        }
        return id
    }

    private func perform(url: URL, method: String, body: Data?) async throws -> Data {
        #if !DEBUG
        guard url.scheme?.lowercased() == "https" else { throw MemoSyncError.insecureScheme }
        #endif
        guard !anonKey.isEmpty else { throw MemoSyncError.notConfigured }
        let accessToken = try await accessTokenProvider()
        guard !accessToken.isEmpty else { throw MemoSyncError.unauthorized }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MemoSyncError.invalidResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401: throw MemoSyncError.unauthorized
        case 403: throw MemoSyncError.forbidden
        case 429:
            throw MemoSyncError.rateLimited(
                retryAfter: Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            )
        default: throw MemoSyncError.serverError(status: http.statusCode)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid artifact timestamp")
            )
        }
        return decoder
    }()
}
