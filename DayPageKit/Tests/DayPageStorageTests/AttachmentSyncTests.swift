import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

private actor FlakyAttachmentDownloadTransport: AttachmentFileTransport {
    private let sourceURL: URL
    private var downloadAttempts = 0

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func uploadFile(
        for request: URLRequest,
        from fileURL: URL
    ) async throws -> (Data, URLResponse) {
        throw AttachmentSyncError.network
    }

    func downloadFile(for request: URLRequest) async throws -> (URL, URLResponse) {
        downloadAttempts += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: downloadAttempts == 1 ? 503 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (sourceURL, response)
    }

    func attempts() -> Int { downloadAttempts }
}

final class AttachmentSyncTests: XCTestCase {
    private var vault: URL!

    override func setUpWithError() throws {
        vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw/assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vault { try? FileManager.default.removeItem(at: vault) }
    }

    func testStreamingInspectionAndStableRetrySidecar() throws {
        let relativePath = "raw/assets/capture.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])
        try bytes.write(to: vault.appendingPathComponent(relativePath))
        let memo = Memo(
            type: .photo,
            attachments: [Memo.Attachment(file: relativePath, kind: "photo")],
            body: "photo"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memo.id,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: memo.toMarkdown().utf8.count
        )
        let userID = UUID()

        let first = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            userID: userID
        )
        let retry = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            userID: userID
        )
        try FileManager.default.removeItem(at: AttachmentTransferStore.stateURL)
        let rebuilt = try AttachmentTransferStore.prepareUploads(
            operation: operation,
            memo: memo,
            userID: userID
        )

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first, rebuilt)
        XCTAssertEqual(first.first?.descriptor.sizeBytes, Int64(bytes.count))
        XCTAssertEqual(first.first?.descriptor.mimeType, "image/png")
        XCTAssertTrue(first.first?.descriptor.objectKey.hasPrefix(
            "\(userID.uuidString.lowercased())/\(memo.id.uuidString.lowercased())/"
        ) == true)
        let sameDevicePull = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memo.id,
            descriptors: rebuilt.map(\.descriptor)
        )
        XCTAssertEqual(sameDevicePull.first?.relativePath, relativePath)
        let state = try String(contentsOf: AttachmentTransferStore.stateURL)
        XCTAssertFalse(state.contains("Bearer"))
        XCTAssertFalse(state.contains("access_token"))
        XCTAssertFalse(state.contains(bytes.base64EncodedString()))
    }

    func testUnsupportedAttachmentPersistsHonestVisibleState() throws {
        let relativePath = "raw/assets/archive.zip"
        try Data([0x50, 0x4b, 0x03, 0x04]).write(
            to: vault.appendingPathComponent(relativePath)
        )
        let memo = Memo(
            type: .text,
            attachments: [Memo.Attachment(file: relativePath, kind: "file")],
            body: "unsupported"
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memo.id,
            kind: .upsert,
            revision: 1,
            modifiedAt: Date(),
            contentHash: SyncOutboxStore.contentHash(for: memo),
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: memo.toMarkdown().utf8.count
        )

        XCTAssertThrowsError(
            try AttachmentTransferStore.prepareUploads(
                operation: operation,
                memo: memo,
                userID: UUID()
            )
        ) { error in
            guard case AttachmentSyncError.unsupportedType("zip") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let summary = AttachmentTransferStore.summary(
            memoIDs: [memo.id.uuidString]
        )
        XCTAssertTrue(summary.hasMedia)
        XCTAssertEqual(summary.unsupported, 1)
        let state = try String(contentsOf: AttachmentTransferStore.stateURL)
        XCTAssertTrue(state.contains("unsupported_type"))
        XCTAssertFalse(state.contains(Data([0x50, 0x4b, 0x03, 0x04]).base64EncodedString()))

        try AttachmentTransferStore.discardTransfers(memoIDs: [memo.id])
        XCTAssertFalse(AttachmentTransferStore.actionableSummary().hasMedia)
    }

    func testRejectsTraversalSymlinkEscapeAndMimeMismatch() throws {
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/../secret.png", kind: "photo")
        )

        let outside = vault.deletingLastPathComponent().appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = vault.appendingPathComponent("raw/assets/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/link.png", kind: "photo")
        )

        try Data("not a png".utf8).write(
            to: vault.appendingPathComponent("raw/assets/wrong.png")
        )
        XCTAssertThrowsError(
            try AttachmentFileInspector.inspect(relativePath: "raw/assets/wrong.png", kind: "photo")
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let wrongURL = vault.appendingPathComponent("raw/assets/wrong.png")
        let digest = try AttachmentFileInspector.sha256AndSize(of: wrongURL)
        let memoID = UUID()
        let userID = UUID()
        let remoteDescriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest.hash,
            sizeBytes: digest.size,
            mimeType: "image/png",
            objectKey: "\(userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(digest.hash).png",
            originalFilename: "wrong.png"
        )
        XCTAssertTrue(AttachmentManifest.isStructurallyValid([remoteDescriptor]))
        XCTAssertThrowsError(
            try AttachmentFileInspector.verify(url: wrongURL, descriptor: remoteDescriptor)
        ) { error in
            guard case AttachmentSyncError.mimeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        let wrongKey = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: digest.hash,
            sizeBytes: digest.size,
            mimeType: "image/png",
            objectKey: "\(userID.uuidString.lowercased())/\(memoID.uuidString.lowercased())/other.png",
            originalFilename: "wrong.png"
        )
        XCTAssertFalse(AttachmentManifest.isStructurallyValid([wrongKey]))
    }

    func testRemoteManifestUsesDurableDeterministicLocalPath() throws {
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "audio",
            contentSHA256: String(repeating: "a", count: 64),
            sizeBytes: 8,
            mimeType: "audio/m4a",
            objectKey: "\(UUID().uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(String(repeating: "a", count: 64)).m4a",
            originalFilename: "voice.m4a",
            durationMilliseconds: 1_250,
            transcript: "hello",
            transcriptionStatus: "done"
        )
        let items = try AttachmentTransferStore.recordPendingDownloads(
            memoID: memoID,
            descriptors: [descriptor]
        )
        let change = SyncRemoteChange(
            id: memoID,
            type: "voice",
            body: "voice",
            createdAt: Date(),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "ios",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 1,
            attachmentManifestHash: AttachmentManifest.hash([descriptor]),
            attachments: [descriptor]
        )

        let attachment = try XCTUnwrap(change.makeMemo().attachments.first)
        XCTAssertEqual(attachment.file, items[0].relativePath)
        XCTAssertEqual(attachment.duration, 1.25)
        XCTAssertEqual(attachment.transcriptionStatus, .done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AttachmentTransferStore.stateURL.path))
    }

    func testFailedDownloadRetriesOnLaterEmptyPullAndTombstoneDiscardsState() async throws {
        let relativePath = "raw/assets/remote-source.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4])
        let sourceURL = vault.appendingPathComponent(relativePath)
        try bytes.write(to: sourceURL)
        let inspected = try AttachmentFileInspector.inspect(
            relativePath: relativePath,
            kind: "photo"
        )
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(UUID().uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "remote.png"
        )
        let manifestHash = AttachmentManifest.hash([descriptor])
        let remote = SyncRemoteChange(
            id: memoID,
            type: "photo",
            body: "remote photo",
            createdAt: Date(),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "ios",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 1,
            attachmentManifestHash: manifestHash,
            attachments: [descriptor]
        )
        let transport = FlakyAttachmentDownloadTransport(sourceURL: sourceURL)
        let downloader = SupabaseAttachmentDownloader(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            fileTransport: transport
        )

        try await downloader.persistAndAttempt(changes: [remote], accessToken: "session")
        XCTAssertEqual(
            AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).failed,
            1
        )
        XCTAssertEqual(AttachmentTransferStore.actionableSummary().failed, 1)

        try await downloader.persistAndAttempt(changes: [], accessToken: "session")
        let attemptCount = await transport.attempts()
        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(
            AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).transferred,
            1
        )
        XCTAssertFalse(AttachmentTransferStore.actionableSummary().hasMedia)
        let installed = vault.appendingPathComponent(
            "raw/assets/sync/\(inspected.sha256)-remote.png"
        )
        XCTAssertEqual(try Data(contentsOf: installed), bytes)

        let tombstone = SyncRemoteChange(
            id: memoID,
            type: "photo",
            body: "",
            createdAt: remote.createdAt,
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "ios",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 2,
            lastSyncDeviceId: nil,
            deletedAt: Date(),
            changeSequence: 2,
            attachmentManifestHash: nil,
            attachments: nil
        )
        try await downloader.persistAndAttempt(changes: [tombstone], accessToken: "session")
        XCTAssertFalse(
            AttachmentTransferStore.summary(memoIDs: [memoID.uuidString]).hasMedia
        )
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
    }

    func testVerifiedDownloadStagingReplaysWithoutNetwork() async throws {
        let relativePath = "raw/assets/staging-source.png"
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9, 8, 7, 6])
        let sourceURL = vault.appendingPathComponent(relativePath)
        try bytes.write(to: sourceURL)
        let inspected = try AttachmentFileInspector.inspect(
            relativePath: relativePath,
            kind: "photo"
        )
        let memoID = UUID()
        let descriptor = SyncAttachmentDescriptor(
            position: 0,
            kind: "photo",
            contentSHA256: inspected.sha256,
            sizeBytes: inspected.sizeBytes,
            mimeType: inspected.mimeType,
            objectKey: "\(UUID().uuidString.lowercased())/\(memoID.uuidString.lowercased())/\(inspected.sha256).png",
            originalFilename: "staged.png"
        )
        let item = try XCTUnwrap(
            AttachmentTransferStore.recordPendingDownloads(
                memoID: memoID,
                descriptors: [descriptor]
            ).first
        )
        let stagingURL = SupabaseAttachmentDownloader.stagingURL(recordID: item.recordID)
        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: stagingURL)
        let transport = FlakyAttachmentDownloadTransport(sourceURL: sourceURL)
        let downloader = SupabaseAttachmentDownloader(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            fileTransport: transport
        )

        try await downloader.persistAndAttempt(changes: [], accessToken: "session")

        let attemptCount = await transport.attempts()
        XCTAssertEqual(attemptCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
        XCTAssertEqual(
            try Data(contentsOf: vault.appendingPathComponent(item.relativePath)),
            bytes
        )
        XCTAssertFalse(AttachmentTransferStore.actionableSummary().hasMedia)
    }
}
