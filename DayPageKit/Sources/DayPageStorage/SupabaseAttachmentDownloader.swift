import Foundation

/// Persists every remote media obligation before attempting network transfer.
/// A failed or cellular-deferred download therefore cannot be forgotten when
/// the memo cursor advances.
public struct SupabaseAttachmentDownloader: Sendable {
    public let supabaseURL: URL
    public let anonKey: String
    public let fileTransport: AttachmentFileTransport

    public init(
        supabaseURL: URL,
        anonKey: String,
        fileTransport: AttachmentFileTransport = URLSession.shared
    ) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.fileTransport = fileTransport
    }

    public func persistAndAttempt(
        changes: [SyncRemoteChange],
        accessToken: String
    ) async throws {
        try AttachmentTransferStore.discardTransfers(
            memoIDs: Set(changes.filter(\.isDeleted).map(\.id))
        )
        var pending: [AttachmentDownloadItem] = []
        for change in changes where !change.isDeleted {
            let descriptors = change.attachments ?? []
            pending.append(contentsOf: try AttachmentTransferStore.recordPendingDownloads(
                memoID: change.id,
                descriptors: descriptors
            ))
        }
        pending.append(contentsOf: AttachmentTransferStore.pendingDownloads())
        var seenRecordIDs = Set<String>()
        pending = pending.filter { seenRecordIDs.insert($0.recordID).inserted }

        // A transfer failure is durable state, not a reason to discard the
        // already-persisted memo page. Continue independent attachments.
        for item in pending {
            do {
                try await install(item, accessToken: accessToken)
            } catch {
                try? AttachmentTransferStore.update(
                    recordID: item.recordID,
                    status: .failed,
                    error: downloadErrorCode(error)
                )
            }
        }
    }

    private func downloadErrorCode(_ error: Error) -> String {
        switch error {
        case AttachmentSyncError.integrityMismatch,
             AttachmentSyncError.localFileChanged:
            return "integrity_mismatch"
        case AttachmentSyncError.transferFailed:
            return "http_transfer"
        default:
            return "download_failed"
        }
    }

    private func install(
        _ item: AttachmentDownloadItem,
        accessToken: String
    ) async throws {
        let vaultCandidate = VaultInitializer.vaultURL
            .appendingPathComponent(item.relativePath).standardizedFileURL
        if FileManager.default.fileExists(atPath: vaultCandidate.path) {
            do {
                let existing = try AttachmentFileInspector.safeLocalURL(
                    relativePath: item.relativePath
                )
                try AttachmentFileInspector.verify(
                    url: existing,
                    descriptor: item.descriptor
                )
                try AttachmentTransferStore.markDownloadInstalled(recordID: item.recordID)
                return
            } catch {
                // Never overwrite a different local file, even at the
                // deterministic SHA-prefixed target.
                throw AttachmentSyncError.integrityMismatch(vaultCandidate.lastPathComponent)
            }
        }
        let destination = try destinationURL(relativePath: item.relativePath)
        let stagingURL = Self.stagingURL(recordID: item.recordID)
        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            do {
                try AttachmentFileInspector.verify(
                    url: stagingURL,
                    descriptor: item.descriptor
                )
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: stagingURL, to: destination)
                try AttachmentTransferStore.markDownloadInstalled(recordID: item.recordID)
                return
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        try AttachmentTransferStore.update(recordID: item.recordID, status: .transferring)
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
        guard let http = response as? HTTPURLResponse else {
            throw MemoSyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AttachmentSyncError.transferFailed(status: http.statusCode)
        }

        try FileManager.default.copyItem(at: temporaryURL, to: stagingURL)
        do {
            try AttachmentFileInspector.verify(url: stagingURL, descriptor: item.descriptor)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: stagingURL, to: destination)
            try AttachmentTransferStore.markDownloadInstalled(recordID: item.recordID)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    private func destinationURL(relativePath: String) throws -> URL {
        guard relativePath.hasPrefix("raw/assets/sync/"),
              !relativePath.contains(".."),
              !relativePath.contains("//") else {
            throw AttachmentSyncError.invalidPath(relativePath)
        }
        let vault = VaultInitializer.vaultURL.standardizedFileURL
        let assets = vault.appendingPathComponent("raw/assets", isDirectory: true)
            .standardizedFileURL
        let destination = vault.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = assets.path.hasSuffix("/") ? assets.path : assets.path + "/"
        guard destination.path.hasPrefix(prefix) else {
            throw AttachmentSyncError.invalidPath(relativePath)
        }
        return destination
    }

    static func stagingURL(recordID: String) -> URL {
        let safeID = recordID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return VaultInitializer.vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("\(String(safeID)).partial")
    }
}
