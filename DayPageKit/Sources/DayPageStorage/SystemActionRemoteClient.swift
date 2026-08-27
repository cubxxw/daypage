import Foundation
import DayPageModels

public struct SystemActionRemoteAcknowledgement: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let entityType: String
    public let entityID: UUID
    public let revision: Int64
    public let status: String
    public let changeSequence: Int64
    public let record: SystemActionJSONValue

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case revision
        case status
        case changeSequence = "change_sequence"
        case record
    }

    public init(
        operationID: UUID,
        entityType: String,
        entityID: UUID,
        revision: Int64,
        status: String,
        changeSequence: Int64,
        record: SystemActionJSONValue
    ) {
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.revision = revision
        self.status = status
        self.changeSequence = changeSequence
        self.record = record
    }
}

public struct SystemActionRemoteRejection: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let entityType: String
    public let entityID: UUID
    public let errorCode: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case errorCode = "reason"
    }

    public init(operationID: UUID, entityType: String, entityID: UUID, errorCode: String) {
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.errorCode = errorCode
    }
}

public struct SystemActionRemotePushResult: Codable, Equatable, Sendable {
    public let accepted: [SystemActionRemoteAcknowledgement]
    public let rejected: [SystemActionRemoteRejection]

    public init(accepted: [SystemActionRemoteAcknowledgement], rejected: [SystemActionRemoteRejection]) {
        self.accepted = accepted
        self.rejected = rejected
    }
}

public struct SystemActionRemoteChange: Codable, Equatable, Sendable {
    public let sequence: Int64
    public let payload: SystemActionOutboxPayload

    public init(sequence: Int64, payload: SystemActionOutboxPayload) {
        self.sequence = sequence
        self.payload = payload
    }
}

public struct SystemActionRemotePullPage: Codable, Equatable, Sendable {
    public let fromCursor: Int64
    public let nextCursor: Int64
    public let hasMore: Bool
    public let changes: [SystemActionRemoteChange]

    public init(fromCursor: Int64, nextCursor: Int64, hasMore: Bool, changes: [SystemActionRemoteChange]) {
        self.fromCursor = fromCursor
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.changes = changes
    }

    public func isValid(limit: Int) -> Bool {
        guard fromCursor >= 0, nextCursor >= fromCursor, changes.count <= limit else { return false }
        guard !hasMore || !changes.isEmpty else { return false }
        var previous = fromCursor
        for change in changes {
            guard change.sequence > previous, change.sequence <= nextCursor else { return false }
            previous = change.sequence
        }
        return previous == nextCursor
    }
}

public struct SystemActionExecutionClaimRequest: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let proposalID: UUID
    public let phase: SystemActionExecutionPhase
    public let proposalRevision: Int64
    public let payloadHash: String
    public let deviceID: String
    public let leaseSeconds: Int

    public init(
        operationID: UUID,
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        proposalRevision: Int64,
        payloadHash: String,
        deviceID: String,
        leaseSeconds: Int = 120
    ) {
        self.operationID = operationID
        self.proposalID = proposalID
        self.phase = phase
        self.proposalRevision = proposalRevision
        self.payloadHash = payloadHash
        self.deviceID = deviceID
        self.leaseSeconds = min(max(leaseSeconds, 30), 300)
    }
}

public enum SystemActionExecutionClaimResult: Equatable, Sendable {
    case leased(SystemActionExecutionLease)
    case busy(expiresAt: Date?)
    case alreadyCompleted(receiptID: UUID)
    case attemptCompleted(receiptID: UUID)
}

public protocol SystemActionRemoteClientProtocol: Sendable {
    func push(operations: [SystemActionOutboxOperation]) async throws -> SystemActionRemotePushResult
    func pull(after cursor: Int64, limit: Int) async throws -> SystemActionRemotePullPage
    func claimExecution(_ request: SystemActionExecutionClaimRequest) async throws -> SystemActionExecutionClaimResult
}

public enum SystemActionRemoteError: Error, Equatable, Sendable {
    case notConfigured
    case networkUnavailable
    case insecureScheme
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: Int)
    case invalidResponse
    case exactReceiptMissing
    case rejected(String)
    case serverError(status: Int)
}

/// Supabase RPC transport for system actions. Endpoint names are injectable so
/// a future versioned RPC can coexist without changing the coordinator API.
public struct SupabaseSystemActionRemoteClient: SystemActionRemoteClientProtocol {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    public struct Endpoints: Sendable {
        public let apply: URL
        public let pull: URL
        public let claim: URL

        public init(apply: URL, pull: URL, claim: URL) {
            self.apply = apply
            self.pull = pull
            self.claim = claim
        }

        public init(supabaseURL: URL) {
            let rpc = supabaseURL
                .appendingPathComponent("rest", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("rpc", isDirectory: true)
            self.init(
                apply: rpc.appendingPathComponent("daypage_apply_system_action_operations_v1"),
                pull: rpc.appendingPathComponent("daypage_pull_system_action_changes_v1"),
                claim: rpc.appendingPathComponent("daypage_claim_system_action_execution_v1")
            )
        }
    }

    private struct ApplyBody: Encodable {
        let operations: [SystemActionRemoteOperationDTO]
        enum CodingKeys: String, CodingKey { case operations = "p_operations" }
    }

    private struct PullBody: Encodable {
        let afterSequence: Int64
        let limit: Int
        enum CodingKeys: String, CodingKey {
            case afterSequence = "p_after_sequence"
            case limit = "p_limit"
        }
    }

    private struct PullResponse: Decodable {
        struct Change: Decodable {
            let changeSequence: Int64
            let entityType: String
            let entityID: UUID
            let record: SystemActionJSONValue

            enum CodingKeys: String, CodingKey {
                case changeSequence = "change_sequence"
                case entityType = "entity_type"
                case entityID = "entity_id"
                case record
            }
        }

        let changes: [Change]
        let nextCursor: Int64
        let hasMore: Bool

        enum CodingKeys: String, CodingKey {
            case changes
            case nextCursor = "next_cursor"
            case hasMore = "has_more"
        }
    }

    private struct ClaimBody: Encodable {
        let operationID: UUID
        let proposalID: UUID
        let phase: SystemActionExecutionPhase
        let proposalRevision: Int64
        let payloadHash: String
        let deviceIDHash: String
        let leaseSeconds: Int

        enum CodingKeys: String, CodingKey {
            case operationID = "p_operation_id"
            case proposalID = "p_proposal_id"
            case phase = "p_phase"
            case proposalRevision = "p_proposal_revision"
            case payloadHash = "p_payload_hash"
            case deviceIDHash = "p_device_id_hash"
            case leaseSeconds = "p_lease_seconds"
        }
    }

    private struct ClaimResponse: Decodable {
        let operationID: UUID
        let proposalID: UUID
        let phase: SystemActionExecutionPhase
        let proposalRevision: Int64
        let payloadHash: String
        let deviceIDHash: String
        let status: String
        let leaseID: UUID?
        let issuedAt: Date?
        let expiresAt: Date?
        let receiptID: UUID?

        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id"
            case proposalID = "proposal_id"
            case phase
            case proposalRevision = "proposal_revision"
            case payloadHash = "payload_hash"
            case deviceIDHash = "device_id_hash"
            case status
            case leaseID = "lease_id"
            case issuedAt = "issued_at"
            case expiresAt = "expires_at"
            case receiptID = "receipt_id"
        }
    }

    public let endpoints: Endpoints
    public let anonKey: String
    public let transport: HTTPTransport
    public let accessTokenProvider: AccessTokenProvider

    public init(
        supabaseURL: URL,
        anonKey: String,
        transport: HTTPTransport = HTTPTransports.shared,
        accessTokenProvider: @escaping AccessTokenProvider
    ) {
        self.init(
            endpoints: Endpoints(supabaseURL: supabaseURL),
            anonKey: anonKey,
            transport: transport,
            accessTokenProvider: accessTokenProvider
        )
    }

    public init(
        endpoints: Endpoints,
        anonKey: String,
        transport: HTTPTransport = HTTPTransports.shared,
        accessTokenProvider: @escaping AccessTokenProvider
    ) {
        self.endpoints = endpoints
        self.anonKey = anonKey
        self.transport = transport
        self.accessTokenProvider = accessTokenProvider
    }

    public func push(operations: [SystemActionOutboxOperation]) async throws -> SystemActionRemotePushResult {
        guard !operations.isEmpty else { return SystemActionRemotePushResult(accepted: [], rejected: []) }
        guard operations.count <= 100 else { throw SystemActionRemoteError.invalidResponse }
        let remoteOperations = try operations.map(SystemActionRemoteContractMapper.operation)
        let result: SystemActionRemotePushResult = try await post(
            to: endpoints.apply,
            body: ApplyBody(operations: remoteOperations)
        )
        let expected = Dictionary(uniqueKeysWithValues: remoteOperations.map { ($0.operationID, $0) })
        let validRejectionReasons = Set([
            "invalid_operation", "operation_id_reuse_mismatch", "stale_revision",
            "approval_mismatch", "lease_required", "conflict",
        ])
        var seen = Set<UUID>()
        for acknowledgement in result.accepted {
            guard let sent = expected[acknowledgement.operationID],
                  acknowledgement.entityType == sent.entityType,
                  acknowledgement.entityID == sent.entityID,
                  acknowledgement.revision == sent.revision,
                  acknowledgement.status == "applied" || acknowledgement.status == "replayed",
                  acknowledgement.changeSequence > 0,
                  acknowledgement.record == sent.record,
                  seen.insert(acknowledgement.operationID).inserted else {
                throw SystemActionRemoteError.invalidResponse
            }
        }
        for rejection in result.rejected {
            guard let sent = expected[rejection.operationID],
                  rejection.entityType == sent.entityType,
                  rejection.entityID == sent.entityID,
                  validRejectionReasons.contains(rejection.errorCode),
                  seen.insert(rejection.operationID).inserted else {
                throw SystemActionRemoteError.invalidResponse
            }
        }
        guard seen.count == operations.count else { throw SystemActionRemoteError.exactReceiptMissing }
        return result
    }

    public func pull(after cursor: Int64, limit: Int = 200) async throws -> SystemActionRemotePullPage {
        let boundedLimit = min(max(limit, 1), 200)
        let response: PullResponse = try await post(
            to: endpoints.pull,
            body: PullBody(afterSequence: max(0, cursor), limit: boundedLimit)
        )
        let changes = try response.changes.map { change -> SystemActionRemoteChange in
            let payload = try SystemActionRemoteContractMapper.localPayload(
                entityType: change.entityType,
                record: change.record
            )
            guard payload.recordID == change.entityID.uuidString.lowercased() else {
                throw SystemActionRemoteError.invalidResponse
            }
            return SystemActionRemoteChange(sequence: change.changeSequence, payload: payload)
        }
        let page = SystemActionRemotePullPage(
            fromCursor: max(0, cursor),
            nextCursor: response.nextCursor,
            hasMore: response.hasMore,
            changes: changes
        )
        guard page.fromCursor == max(0, cursor), page.isValid(limit: boundedLimit) else {
            throw SystemActionRemoteError.invalidResponse
        }
        return page
    }

    public func claimExecution(_ request: SystemActionExecutionClaimRequest) async throws -> SystemActionExecutionClaimResult {
        let response: ClaimResponse = try await post(
            to: endpoints.claim,
            body: ClaimBody(
                operationID: request.operationID,
                proposalID: request.proposalID,
                phase: request.phase,
                proposalRevision: request.proposalRevision,
                payloadHash: request.payloadHash,
                deviceIDHash: SystemActionRemoteContractMapper.hash(request.deviceID),
                leaseSeconds: request.leaseSeconds
            )
        )
        guard response.operationID == request.operationID,
              response.proposalID == request.proposalID,
              response.phase == request.phase,
              response.proposalRevision == request.proposalRevision,
              response.payloadHash == request.payloadHash,
              response.deviceIDHash == SystemActionRemoteContractMapper.hash(request.deviceID) else {
            throw SystemActionRemoteError.invalidResponse
        }
        switch response.status {
        case "claimed", "replayed":
            guard let leaseID = response.leaseID,
                  let issuedAt = response.issuedAt,
                  let expiresAt = response.expiresAt,
                  expiresAt > issuedAt,
                  response.receiptID == nil else {
                throw SystemActionRemoteError.invalidResponse
            }
            return .leased(SystemActionExecutionLease(
                id: leaseID,
                proposalID: response.proposalID,
                phase: response.phase,
                proposalRevision: response.proposalRevision,
                payloadHash: response.payloadHash,
                deviceID: request.deviceID,
                issuedAt: issuedAt,
                expiresAt: expiresAt
            ))
        case "busy":
            // A busy response identifies the competing lease for exact
            // contract validation, but that lease is never exposed as an
            // executable lease to this device.
            guard response.leaseID != nil,
                  let issuedAt = response.issuedAt,
                  let expiresAt = response.expiresAt,
                  expiresAt > issuedAt,
                  response.receiptID == nil else {
                throw SystemActionRemoteError.invalidResponse
            }
            return .busy(expiresAt: expiresAt)
        case "already_completed", "attempt_completed":
            guard response.leaseID == nil,
                  response.issuedAt == nil,
                  response.expiresAt == nil,
                  let receiptID = response.receiptID else {
                throw SystemActionRemoteError.invalidResponse
            }
            return response.status == "already_completed"
                ? .alreadyCompleted(receiptID: receiptID)
                : .attemptCompleted(receiptID: receiptID)
        default:
            throw SystemActionRemoteError.invalidResponse
        }
    }

    private func post<Body: Encodable, Response: Decodable>(
        to url: URL,
        body: Body
    ) async throws -> Response {
        #if !DEBUG
        guard url.scheme?.lowercased() == "https" else { throw SystemActionRemoteError.insecureScheme }
        #endif
        guard !anonKey.isEmpty else { throw SystemActionRemoteError.notConfigured }
        let token = try await accessTokenProvider()
        guard !token.isEmpty else { throw SystemActionRemoteError.unauthorized }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch let error as URLError where Self.isOffline(error.code) {
            throw SystemActionRemoteError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else { throw SystemActionRemoteError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            do { return try Self.decoder.decode(Response.self, from: data) }
            catch { throw SystemActionRemoteError.invalidResponse }
        case 401: throw SystemActionRemoteError.unauthorized
        case 403: throw SystemActionRemoteError.forbidden
        case 409: throw SystemActionRemoteError.rejected("conflict")
        case 429:
            let retry = Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 60
            throw SystemActionRemoteError.rateLimited(retryAfter: retry)
        default: throw SystemActionRemoteError.serverError(status: http.statusCode)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = SystemActionCanonicalJSON.date(fromCanonicalTimestamp: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Timestamp must use canonical UTC millisecond form"
            )
        }
        return decoder
    }

    private static func isOffline(_ code: URLError.Code) -> Bool {
        [
            .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
            .cannotConnectToHost, .dnsLookupFailed, .timedOut,
            .internationalRoamingOff, .dataNotAllowed,
        ].contains(code)
    }
}
