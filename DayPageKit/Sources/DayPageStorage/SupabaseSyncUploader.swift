import Foundation

/// Session-backed uploader for the revisioned Supabase sync RPC. It receives
/// only the public anon key and the current user's access token; service-role
/// and direct database credentials never enter the app.
public struct SupabaseSyncUploader: RemoteUploader {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private struct RequestBody: Encodable {
        let pOperations: [SyncOutboxOperation]

        enum CodingKeys: String, CodingKey {
            case pOperations = "p_operations"
        }
    }

    private struct ResponseBody: Decodable {
        struct Accepted: Decodable {
            let operationID: UUID
            let status: String
            let remoteRevision: Int64?

            enum CodingKeys: String, CodingKey {
                case operationID = "operation_id"
                case status
                case remoteRevision = "remote_revision"
            }
        }

        struct Rejected: Decodable {
            let operationID: String?
            let reason: String

            enum CodingKeys: String, CodingKey {
                case operationID = "operation_id"
                case reason
            }
        }

        let accepted: [Accepted]
        let rejected: [Rejected]
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
            .appendingPathComponent("daypage_apply_sync_operations")
        self.anonKey = anonKey
        self.transport = transport
        self.accessTokenProvider = accessTokenProvider
    }

    public func upload(operation: SyncOutboxOperation) async throws -> Int {
        #if !DEBUG
        guard endpoint.scheme?.lowercased() == "https" else {
            throw MemoSyncError.insecureScheme
        }
        #endif
        guard !anonKey.isEmpty else { throw MemoSyncError.notConfigured }
        let accessToken = try await accessTokenProvider()
        guard !accessToken.isEmpty else { throw MemoSyncError.unauthorized }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(RequestBody(pOperations: [operation]))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
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
            let decoded: ResponseBody
            do {
                decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            } catch {
                throw MemoSyncError.invalidResponse
            }
            if let rejection = decoded.rejected.first(where: {
                $0.operationID?.lowercased() == operation.operationID.uuidString.lowercased()
            }) {
                throw MemoSyncError.rejected(reason: rejection.reason)
            }
            guard let receipt = decoded.accepted.first(where: {
                $0.operationID == operation.operationID
            }) else {
                throw MemoSyncError.rejected(reason: "operation was not acknowledged")
            }
            if receipt.status == "stale" {
                throw MemoSyncError.conflict(remoteRevision: receipt.remoteRevision ?? 0)
            }
            guard receipt.status == "applied" else {
                throw MemoSyncError.rejected(reason: "unknown receipt status")
            }
            return body.count
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
