import XCTest
import DayPageModels
@testable import DayPageStorage

final class SyncOutboxStoreTests: XCTestCase {
    private var temporaryVault: URL!

    override func setUpWithError() throws {
        temporaryVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-outbox-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryVault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = temporaryVault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let temporaryVault {
            try? FileManager.default.removeItem(at: temporaryVault)
        }
    }

    func testUpsertSurvivesReloadAndCarriesRevisionedPayload() throws {
        let memo = Memo(body: "durable local-first note")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")

        let operations = try SyncOutboxStore.pendingOperations()
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0].memoID, memo.id)
        XCTAssertEqual(operations[0].revision, 1)
        XCTAssertEqual(operations[0].kind, .upsert)
        XCTAssertEqual(operations[0].payload?.body, memo.body)
        XCTAssertFalse(operations[0].contentHash?.isEmpty ?? true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SyncOutboxStore.outboxURL.path))
    }

    func testOldAcknowledgementCannotClearNewerEdit() throws {
        var memo = Memo(body: "first")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
        let first = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)

        memo.body = "second"
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
        let second = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)
        XCTAssertEqual(second.revision, 2)
        XCTAssertNotEqual(second.operationID, first.operationID)

        XCTAssertThrowsError(try SyncOutboxStore.acknowledge(operationID: first.operationID))
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().first?.operationID, second.operationID)
    }

    func testDeleteBecomesTombstoneInsteadOfDisappearing() throws {
        let memo = Memo(body: "delete me")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
        let upsert = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)
        try SyncOutboxStore.acknowledge(operationID: upsert.operationID)

        try SyncOutboxStore.recordChanges(
            before: [memo],
            after: [],
            vaultPath: "raw/2026-08-23.md"
        )
        let deletion = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)
        XCTAssertEqual(deletion.kind, .delete)
        XCTAssertEqual(deletion.memoID, memo.id)
        XCTAssertEqual(deletion.revision, 2)
        XCTAssertNil(deletion.payload)
    }

    func testExactReceiptRemovesOperation() throws {
        let memo = Memo(body: "ack me")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
        let operation = try XCTUnwrap(SyncOutboxStore.pendingOperations().first)
        try SyncOutboxStore.acknowledge(operationID: operation.operationID)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }
}

private struct SyncStubTransport: HTTPTransport {
    let data: Data
    let status: Int

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }
}

final class SupabaseSyncUploaderTests: XCTestCase {
    func testRequiresExactRPCOperationReceipt() async throws {
        let memoID = UUID()
        let operationID = UUID()
        let operation = SyncOutboxOperation(
            operationID: operationID,
            memoID: memoID,
            kind: .delete,
            revision: 2,
            modifiedAt: Date(timeIntervalSince1970: 1_787_500_800),
            contentHash: nil,
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: 0
        )
        let accepted = try JSONSerialization.data(withJSONObject: [
            "accepted": [["operation_id": operationID.uuidString, "status": "applied"]],
            "rejected": [],
        ])
        let uploader = SupabaseSyncUploader(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            transport: SyncStubTransport(data: accepted, status: 200),
            accessTokenProvider: { "user-access-token" }
        )
        _ = try await uploader.upload(operation: operation)

        let missing = try JSONSerialization.data(withJSONObject: ["accepted": [], "rejected": []])
        let rejectingUploader = SupabaseSyncUploader(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            transport: SyncStubTransport(data: missing, status: 200),
            accessTokenProvider: { "user-access-token" }
        )
        do {
            _ = try await rejectingUploader.upload(operation: operation)
            XCTFail("missing operation receipt must not acknowledge the outbox")
        } catch let error as MemoSyncError {
            guard case .rejected = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStaleReceiptSurfacesConflictWithoutAcknowledgement() async throws {
        let memoID = UUID()
        let operationID = UUID()
        let operation = SyncOutboxOperation(
            operationID: operationID,
            memoID: memoID,
            kind: .upsert,
            revision: 2,
            modifiedAt: Date(),
            contentHash: "local",
            deviceID: UUID().uuidString.lowercased(),
            payload: nil,
            sizeBytes: 0
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "accepted": [[
                "operation_id": operationID.uuidString,
                "status": "stale",
                "remote_revision": 2,
            ]],
            "rejected": [],
        ])
        let uploader = SupabaseSyncUploader(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            transport: SyncStubTransport(data: response, status: 200),
            accessTokenProvider: { "session" }
        )

        do {
            _ = try await uploader.upload(operation: operation)
            XCTFail("stale revision must remain pending until pull resolves it")
        } catch let error as MemoSyncError {
            guard case .conflict(let remoteRevision) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(remoteRevision, 2)
        }
    }
}
