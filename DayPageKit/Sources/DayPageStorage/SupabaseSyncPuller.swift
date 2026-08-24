import Foundation
import DayPageModels

public struct SyncRemoteChange: Decodable, Equatable, Sendable {
    public struct Location: Decodable, Equatable, Sendable {
        public let name: String?
        public let address: String?
        public let lat: Double?
        public let lng: Double?
    }

    public struct Weather: Decodable, Equatable, Sendable {
        public let condition: String?

        private enum CodingKeys: String, CodingKey {
            case condition
            case weather
        }

        public init(from decoder: Decoder) throws {
            if let scalar = try? decoder.singleValueContainer(),
               let value = try? scalar.decode(String.self) {
                condition = value
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            condition = try container.decodeIfPresent(String.self, forKey: .condition)
                ?? container.decodeIfPresent(String.self, forKey: .weather)
        }
    }

    public let id: UUID
    public let type: String
    public let body: String
    public let createdAt: Date
    public let pinnedAt: Date?
    public let location: Location?
    public let weather: Weather?
    public let device: String?
    public let source: String
    public let vaultPath: String?
    public let sourceModifiedAt: Date?
    public let contentHash: String?
    public let syncRevision: Int64
    public let lastSyncDeviceId: String?
    public let deletedAt: Date?
    public let changeSequence: Int64

    public var isDeleted: Bool { deletedAt != nil }

    public func makeMemo(preservingLocalMetadata local: Memo? = nil) -> Memo {
        let memoType: Memo.MemoType
        switch type {
        case "voice": memoType = .voice
        case "photo": memoType = .photo
        default: memoType = .text
        }
        return Memo(
            id: id,
            type: memoType,
            created: createdAt,
            pinnedAt: pinnedAt,
            location: location.map {
                Memo.Location(name: $0.name ?? $0.address, lat: $0.lat, lng: $0.lng)
            },
            weather: weather?.condition,
            device: device,
            attachments: local?.attachments ?? [],
            mood: local?.mood,
            entityMentions: local?.entityMentions ?? [],
            marginNote: local?.marginNote,
            body: body
        )
    }
}

public struct SyncPullPage: Decodable, Equatable, Sendable {
    public let changes: [SyncRemoteChange]
    public let nextCursor: Int64
    public let hasMore: Bool

    /// A malformed page must never advance the durable cursor past a change
    /// that was not applied locally. The RPC promises strict sequence order
    /// and sets `next_cursor` to the final returned sequence.
    public func isValid(after cursor: Int64) -> Bool {
        let sequences = changes.map(\.changeSequence)
        guard nextCursor >= cursor,
              sequences == sequences.sorted(),
              Set(sequences).count == sequences.count,
              !sequences.contains(where: { $0 <= cursor }) else {
            return false
        }
        guard let last = sequences.last else {
            return nextCursor == cursor && !hasMore
        }
        return nextCursor == last
    }
}

public struct SyncRemoteApplyResult: Equatable, Sendable {
    public let appliedCount: Int
    public let deletedCount: Int
    public let conflictCopies: [UUID]

    public init(appliedCount: Int, deletedCount: Int, conflictCopies: [UUID]) {
        self.appliedCount = appliedCount
        self.deletedCount = deletedCount
        self.conflictCopies = conflictCopies
    }
}

public protocol RemotePuller: Sendable {
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage
}

/// Incremental, user-session-backed reader for the monotonic Supabase change
/// sequence. The same user access token used for push is passed through RLS.
public struct SupabaseSyncPuller: RemotePuller {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private struct RequestBody: Encodable {
        let afterSequence: Int64
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case afterSequence = "p_after_sequence"
            case limit = "p_limit"
        }
    }

    public let endpoint: URL
    public let anonKey: String
    public let transport: HTTPTransport
    public let accessTokenProvider: AccessTokenProvider

    public init(
        supabaseURL: URL,
        anonKey: String,
        transport: HTTPTransport = HTTPTransports.shared,
        accessTokenProvider: @escaping AccessTokenProvider
    ) {
        self.endpoint = supabaseURL
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rpc", isDirectory: true)
            .appendingPathComponent("daypage_pull_sync_changes")
        self.anonKey = anonKey
        self.transport = transport
        self.accessTokenProvider = accessTokenProvider
    }

    public func pull(after cursor: Int64, limit: Int = 200) async throws -> SyncPullPage {
        #if !DEBUG
        guard endpoint.scheme?.lowercased() == "https" else {
            throw MemoSyncError.insecureScheme
        }
        #endif
        guard !anonKey.isEmpty else { throw MemoSyncError.notConfigured }
        let accessToken = try await accessTokenProvider()
        guard !accessToken.isEmpty else { throw MemoSyncError.unauthorized }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(RequestBody(
            afterSequence: max(0, cursor),
            limit: min(max(limit, 1), 500)
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: value) { return date }
                let standard = ISO8601DateFormatter()
                standard.formatOptions = [.withInternetDateTime]
                if let date = standard.date(from: value) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 timestamp"
                )
            }
            do {
                return try decoder.decode(SyncPullPage.self, from: data)
            } catch {
                throw MemoSyncError.invalidResponse
            }
        case 401:
            throw MemoSyncError.unauthorized
        case 403:
            throw MemoSyncError.forbidden
        case 429:
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw MemoSyncError.rateLimited(retryAfter: retry)
        default:
            throw MemoSyncError.serverError(status: http.statusCode)
        }
    }
}
