import Foundation
import DayPageModels

/// Session-backed protocol-v2 uploader. Memo capture stays local-first; this
/// component prepares immutable media objects, transfers them, and only then
/// asks Postgres for one memo + manifest + receipt transaction.
public struct SupabaseSyncUploader: RemoteUploader {
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private struct V2Payload: Encodable {
        let type: String
        let body: String
        let createdAt: Date
        let pinnedAt: Date?
        let location: SyncMemoPayload.Location?
        let weather: SyncMemoPayload.Weather?
        let device: String?
        let source: String
        let vaultPath: String
        let attachments: [SyncAttachmentDescriptor]

        enum CodingKeys: String, CodingKey {
            case type
            case body
            case createdAt = "created_at"
            case pinnedAt = "pinned_at"
            case location
            case weather
            case device
            case source
            case vaultPath = "vault_path"
            case attachments
        }
    }

    private struct V2Operation: Encodable {
        let protocolVersion = 2
        let operationID: UUID
        let memoID: UUID
        let kind: SyncOutboxOperation.Kind
        let revision: Int64
        let modifiedAt: Date
        let contentHash: String?
        let attachmentManifestHash: String?
        let deviceID: String
        let payload: V2Payload?
        let sizeBytes: Int

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case operationID = "operation_id"
            case memoID = "memo_id"
            case kind
            case revision
            case modifiedAt = "modified_at"
            case contentHash = "content_hash"
            case attachmentManifestHash = "attachment_manifest_hash"
            case deviceID = "device_id"
            case payload
            case sizeBytes = "size_bytes"
        }
    }

    private struct RequestBody: Encodable {
        let pOperations: [V2Operation]

        enum CodingKeys: String, CodingKey {
            case pOperations = "p_operations"
        }
    }

    private struct PrepareRequest: Encodable {
        let memoID: UUID
        let contentSHA256: String
        let sizeBytes: Int64
        let mimeType: String
        let fileExtension: String

        enum CodingKeys: String, CodingKey {
            case memoID = "p_memo_id"
            case contentSHA256 = "p_content_sha256"
            case sizeBytes = "p_size_bytes"
            case mimeType = "p_mime_type"
            case fileExtension = "p_extension"
        }
    }

    private struct PreparedUpload: Decodable {
        let reservationID: UUID
        let objectKey: String
        let expiresAt: Date
        let alreadyExists: Bool

        enum CodingKeys: String, CodingKey {
            case reservationID = "reservation_id"
            case objectKey = "object_key"
            case expiresAt = "expires_at"
            case alreadyExists = "already_exists"
        }
    }

    private struct ResponseBody: Decodable {
        struct Accepted: Decodable {
            let operationID: UUID
            let status: String
            let remoteRevision: Int64?
            let attachmentManifestHash: String?

            enum CodingKeys: String, CodingKey {
                case operationID = "operation_id"
                case status
                case remoteRevision = "remote_revision"
                case attachmentManifestHash = "attachment_manifest_hash"
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

    public let supabaseURL: URL
    public let endpoint: URL
    public let prepareEndpoint: URL
    public let anonKey: String
    public let userID: UUID?
    public let transport: HTTPTransport
    public let fileTransport: AttachmentFileTransport
    public let accessTokenProvider: AccessTokenProvider

    private let standardUploadMaximum: Int64 = 6 * 1_024 * 1_024
    private let tusChunkSize = 6 * 1_024 * 1_024

    public init(
        supabaseURL: URL,
        anonKey: String,
        userID: UUID? = nil,
        transport: HTTPTransport = HTTPTransports.shared,
        fileTransport: AttachmentFileTransport = URLSession.shared,
        accessTokenProvider: @escaping AccessTokenProvider
    ) {
        self.supabaseURL = supabaseURL
        self.endpoint = supabaseURL
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rpc", isDirectory: true)
            .appendingPathComponent("daypage_apply_sync_operations_v2")
        self.prepareEndpoint = supabaseURL
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rpc", isDirectory: true)
            .appendingPathComponent("daypage_prepare_attachment_upload")
        self.anonKey = anonKey
        self.userID = userID
        self.transport = transport
        self.fileTransport = fileTransport
        self.accessTokenProvider = accessTokenProvider
    }

    public func upload(operation: SyncOutboxOperation) async throws -> Int {
        try validateConfiguration()
        let accessToken = try await accessTokenProvider()
        guard !accessToken.isEmpty else { throw MemoSyncError.unauthorized }

        let v2Operation: V2Operation
        if operation.kind == .delete {
            v2Operation = V2Operation(
                operationID: operation.operationID,
                memoID: operation.memoID,
                kind: .delete,
                revision: operation.revision,
                modifiedAt: operation.modifiedAt,
                contentHash: nil,
                attachmentManifestHash: nil,
                deviceID: operation.deviceID,
                payload: nil,
                sizeBytes: 0
            )
        } else {
            guard let payload = operation.payload,
                  let (memo, _) = MemoSyncUploader.findMemo(
                      byID: operation.memoID.uuidString
                  ) else {
                throw MemoSyncError.memoNotFound(operation.memoID.uuidString)
            }
            guard operation.contentHash == SyncOutboxStore.contentHash(for: memo) else {
                throw AttachmentSyncError.localFileChanged(operation.memoID.uuidString)
            }
            let resolvedUserID = try resolveUserID(accessToken: accessToken)
            let items = try await Task.detached(priority: .utility) {
                try AttachmentTransferStore.prepareUploads(
                    operation: operation,
                    memo: memo,
                    userID: resolvedUserID
                )
            }.value
            for item in items {
                try await prepareAndUpload(item, memoID: memo.id, accessToken: accessToken)
            }
            let descriptors = items
                .map(\.descriptor)
                .sorted { $0.position < $1.position }
            let manifestHash = AttachmentManifest.hash(descriptors)
            v2Operation = V2Operation(
                operationID: operation.operationID,
                memoID: operation.memoID,
                kind: .upsert,
                revision: operation.revision,
                modifiedAt: operation.modifiedAt,
                contentHash: operation.contentHash,
                attachmentManifestHash: manifestHash,
                deviceID: operation.deviceID,
                payload: V2Payload(
                    type: payload.type,
                    body: payload.body,
                    createdAt: payload.createdAt,
                    pinnedAt: payload.pinnedAt,
                    location: payload.location,
                    weather: payload.weather,
                    device: payload.device,
                    source: payload.source,
                    vaultPath: payload.vaultPath,
                    attachments: descriptors
                ),
                sizeBytes: operation.sizeBytes
            )
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(RequestBody(pOperations: [v2Operation]))
        var request = authenticatedJSONRequest(
            url: endpoint,
            accessToken: accessToken,
            body: body
        )
        request.timeoutInterval = 30
        let (data, response) = try await transport.data(for: request)
        try assertReceipt(
            operation: operation,
            expectedManifestHash: v2Operation.attachmentManifestHash,
            data: data,
            response: response
        )
        return body.count
    }

    private func prepareAndUpload(
        _ item: AttachmentUploadItem,
        memoID: UUID,
        accessToken: String
    ) async throws {
        do {
            let fileExtension = URL(fileURLWithPath: item.descriptor.objectKey).pathExtension
            let encoder = JSONEncoder()
            let body = try encoder.encode(PrepareRequest(
                memoID: memoID,
                contentSHA256: item.descriptor.contentSHA256,
                sizeBytes: item.descriptor.sizeBytes,
                mimeType: item.descriptor.mimeType,
                fileExtension: fileExtension
            ))
            let request = authenticatedJSONRequest(
                url: prepareEndpoint,
                accessToken: accessToken,
                body: body
            )
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AttachmentSyncError.network
            }
            if !(200...299).contains(http.statusCode),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? String,
               message.lowercased().contains("quota") {
                throw AttachmentSyncError.quotaExceeded
            }
            switch http.statusCode {
            case 200...299: break
            case 401: throw MemoSyncError.unauthorized
            case 403: throw MemoSyncError.forbidden
            default: throw AttachmentSyncError.transferFailed(status: http.statusCode)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = Self.syncDateDecodingStrategy
            guard let prepared = try? decoder.decode(PreparedUpload.self, from: data),
                  prepared.objectKey == item.descriptor.objectKey else {
                throw AttachmentSyncError.network
            }
            _ = prepared.reservationID
            _ = prepared.expiresAt
            guard !prepared.alreadyExists else {
                try await verifyRemoteObject(item, accessToken: accessToken)
                try AttachmentTransferStore.update(recordID: item.recordID, status: .transferred)
                return
            }

            try AttachmentTransferStore.update(recordID: item.recordID, status: .transferring)
            if item.descriptor.sizeBytes <= standardUploadMaximum {
                try await uploadStandard(item, accessToken: accessToken)
            } else {
                try await uploadResumable(item, accessToken: accessToken)
            }
            try AttachmentTransferStore.update(recordID: item.recordID, status: .transferred)
        } catch {
            let status: AttachmentTransferStatus
            if case AttachmentSyncError.quotaExceeded = error {
                status = .quotaFailed
            } else {
                status = .failed
            }
            try? AttachmentTransferStore.update(
                recordID: item.recordID,
                status: status,
                error: transferErrorCode(error)
            )
            switch error {
            case MemoSyncError.unauthorized,
                 MemoSyncError.forbidden,
                 MemoSyncError.notConfigured,
                 MemoSyncError.insecureScheme:
                throw error
            case let attachmentError as AttachmentSyncError:
                throw attachmentError
            default:
                throw AttachmentSyncError.network
            }
        }
    }

    private func transferErrorCode(_ error: Error) -> String {
        switch error {
        case AttachmentSyncError.quotaExceeded: return "quota_exceeded"
        case AttachmentSyncError.unsupportedType: return "unsupported_type"
        case AttachmentSyncError.mimeMismatch: return "mime_mismatch"
        case AttachmentSyncError.integrityMismatch: return "integrity_mismatch"
        case AttachmentSyncError.transferFailed: return "http_transfer"
        case AttachmentSyncError.network: return "network"
        case MemoSyncError.unauthorized: return "unauthorized"
        case MemoSyncError.forbidden: return "forbidden"
        default: return "transfer_failed"
        }
    }

    private func uploadStandard(
        _ item: AttachmentUploadItem,
        accessToken: String
    ) async throws {
        let url = supabaseURL
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("object", isDirectory: true)
            .appendingPathComponent("memo-attachments", isDirectory: true)
            .appendingPathComponent(item.descriptor.objectKey)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(item.descriptor.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.allowsCellularAccess = AttachmentNetworkPolicy.allowsCellularTransfers
        let (data, response) = try await fileTransport.uploadFile(
            for: request,
            from: item.localURL
        )
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        if (200...299).contains(http.statusCode) { return }
        if [400, 409].contains(http.statusCode),
           let message = String(data: data, encoding: .utf8)?.lowercased(),
           message.contains("exist") {
            try await verifyRemoteObject(item, accessToken: accessToken)
            return
        }
        throw AttachmentSyncError.transferFailed(status: http.statusCode)
    }

    private func uploadResumable(
        _ item: AttachmentUploadItem,
        accessToken: String
    ) async throws {
        let state = AttachmentTransferStore.resumableState(recordID: item.recordID)
        var uploadURL = state.url
        var offset = state.offset
        if let existingURL = uploadURL {
            var head = URLRequest(url: existingURL)
            head.httpMethod = "HEAD"
            head.allowsCellularAccess = AttachmentNetworkPolicy.allowsCellularTransfers
            head.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            head.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await transport.data(for: head)
            if let http = response as? HTTPURLResponse,
               (200...299).contains(http.statusCode),
               let remoteOffset = Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? "") {
                offset = remoteOffset
            } else {
                try AttachmentTransferStore.clearResumableState(recordID: item.recordID)
                uploadURL = nil
                offset = 0
            }
        }

        if uploadURL == nil {
            var create = URLRequest(url: supabaseURL
                .appendingPathComponent("storage", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("upload", isDirectory: true)
                .appendingPathComponent("resumable"))
            create.httpMethod = "POST"
            create.timeoutInterval = 30
            create.setValue(anonKey, forHTTPHeaderField: "apikey")
            create.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            create.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            create.setValue(String(item.descriptor.sizeBytes), forHTTPHeaderField: "Upload-Length")
            create.setValue(tusMetadata(item.descriptor), forHTTPHeaderField: "Upload-Metadata")
            create.setValue("false", forHTTPHeaderField: "x-upsert")
            create.allowsCellularAccess = AttachmentNetworkPolicy.allowsCellularTransfers
            let (data, response) = try await transport.data(for: create)
            guard let http = response as? HTTPURLResponse else {
                throw MemoSyncError.invalidResponse
            }
            if [400, 409].contains(http.statusCode),
               let message = String(data: data, encoding: .utf8)?.lowercased(),
               message.contains("exist") {
                try await verifyRemoteObject(item, accessToken: accessToken)
                return
            }
            guard (200...299).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let resolved = URL(string: location, relativeTo: supabaseURL)?.absoluteURL else {
                throw AttachmentSyncError.transferFailed(status: http.statusCode)
            }
            uploadURL = resolved
            offset = 0
            try AttachmentTransferStore.update(
                recordID: item.recordID,
                status: .transferring,
                resumableURL: resolved,
                uploadOffset: 0
            )
        }

        guard let uploadURL else { throw MemoSyncError.invalidResponse }
        let handle = try FileHandle(forReadingFrom: item.localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        while offset < item.descriptor.sizeBytes {
            let remaining = item.descriptor.sizeBytes - offset
            let count = min(Int64(tusChunkSize), remaining)
            guard let chunk = try handle.read(upToCount: Int(count)), !chunk.isEmpty else {
                throw AttachmentSyncError.localFileChanged(item.localURL.path)
            }
            var patch = URLRequest(url: uploadURL)
            patch.httpMethod = "PATCH"
            patch.timeoutInterval = 120
            patch.httpBody = chunk
            patch.setValue(anonKey, forHTTPHeaderField: "apikey")
            patch.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            patch.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            patch.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            patch.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            patch.allowsCellularAccess = AttachmentNetworkPolicy.allowsCellularTransfers
            let (_, response) = try await transport.data(for: patch)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let remoteOffset = Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? ""),
                  remoteOffset == offset + Int64(chunk.count) else {
                throw AttachmentSyncError.transferFailed(
                    status: (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            offset = remoteOffset
            try AttachmentTransferStore.update(
                recordID: item.recordID,
                status: .transferring,
                resumableURL: uploadURL,
                uploadOffset: offset
            )
        }
    }

    private func tusMetadata(_ descriptor: SyncAttachmentDescriptor) -> String {
        let values = [
            ("bucketName", "memo-attachments"),
            ("objectName", descriptor.objectKey),
            ("contentType", descriptor.mimeType),
            ("cacheControl", "3600"),
        ]
        return values.map { key, value in
            "\(key) \(Data(value.utf8).base64EncodedString())"
        }.joined(separator: ",")
    }

    private func verifyRemoteObject(
        _ item: AttachmentUploadItem,
        accessToken: String
    ) async throws {
        let url = supabaseURL
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("object", isDirectory: true)
            .appendingPathComponent("authenticated", isDirectory: true)
            .appendingPathComponent("memo-attachments", isDirectory: true)
            .appendingPathComponent(item.descriptor.objectKey)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 180
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.allowsCellularAccess = AttachmentNetworkPolicy.allowsCellularTransfers
        let (temporaryURL, response) = try await fileTransport.downloadFile(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw AttachmentSyncError.transferFailed(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0
            )
        }
        do {
            try AttachmentFileInspector.verify(url: temporaryURL, descriptor: item.descriptor)
        } catch {
            throw AttachmentSyncError.integrityMismatch(item.descriptor.contentSHA256)
        }
    }

    private func assertReceipt(
        operation: SyncOutboxOperation,
        expectedManifestHash: String?,
        data: Data,
        response: URLResponse
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        try throwForHTTPStatus(http.statusCode)
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
        guard receipt.status == "applied",
              receipt.attachmentManifestHash == expectedManifestHash else {
            throw MemoSyncError.rejected(reason: "attachment receipt mismatch")
        }
    }

    private func authenticatedJSONRequest(
        url: URL,
        accessToken: String,
        body: Data
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validateConfiguration() throws {
        #if !DEBUG
        guard endpoint.scheme?.lowercased() == "https" else {
            throw MemoSyncError.insecureScheme
        }
        #endif
        guard !anonKey.isEmpty else { throw MemoSyncError.notConfigured }
    }

    private func resolveUserID(accessToken: String) throws -> UUID {
        if let userID { return userID }
        if let bound = try SyncAccountStateStore.boundUserID() { return bound }
        let pieces = accessToken.split(separator: ".")
        guard pieces.count == 3 else { throw MemoSyncError.unauthorized }
        var base64 = String(pieces[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = object["sub"] as? String,
              let resolved = UUID(uuidString: subject) else {
            throw MemoSyncError.unauthorized
        }
        return resolved
    }

    private func throwForHTTPStatus(_ status: Int) throws {
        switch status {
        case 200...299:
            return
        case 401:
            throw MemoSyncError.unauthorized
        case 403:
            throw MemoSyncError.forbidden
        case 429:
            throw MemoSyncError.rateLimited(retryAfter: 60)
        default:
            throw MemoSyncError.serverError(status: status)
        }
    }

    private static var syncDateDecodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
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
    }
}
