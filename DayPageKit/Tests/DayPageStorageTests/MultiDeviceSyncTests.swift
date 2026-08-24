import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

final class MultiDeviceSyncTests: XCTestCase {
    private var temporaryVault: URL!
    private let userA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let userB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    override func setUpWithError() throws {
        let baseDirectory = ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        temporaryVault = baseDirectory
            .appendingPathComponent("daypage-multidevice-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testVaultBindingRejectsAnotherAccountAndCursorIsMonotonic() throws {
        XCTAssertEqual(try SyncAccountStateStore.bind(to: userA), 0)
        try SyncAccountStateStore.advancePullCursor(to: 42, for: userA)
        try SyncAccountStateStore.advancePullCursor(to: 12, for: userA)
        XCTAssertEqual(try SyncAccountStateStore.pullCursor(for: userA), 42)

        XCTAssertThrowsError(try SyncAccountStateStore.bind(to: userB)) { error in
            guard case SyncAccountStateError.accountMismatch(let expected, let actual) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expected, self.userA)
            XCTAssertEqual(actual, self.userB)
        }
    }

    func testRemoteChangeBecomesLocalWithoutOutboundEcho() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        let change = makeChange(
            id: memoID,
            body: "from the other Mac",
            createdAt: created,
            revision: 1,
            sequence: 10
        )

        let result = try RawStorage.applyRemoteChanges([change])

        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertTrue(result.conflictCopies.isEmpty)
        XCTAssertEqual(try RawStorage.read(for: created).first?.id, memoID)
        XCTAssertEqual(try RawStorage.read(for: created).first?.body, "from the other Mac")
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)

        var edited = try XCTUnwrap(try RawStorage.read(for: created).first)
        edited.body = "edited on this Mac"
        try RawStorage.rewrite([edited], for: created)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().first?.revision, 2)
    }

    func testConcurrentEditPreservesLocalCopyAndInstallsRemoteCanonical() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "base",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])

        var local = try XCTUnwrap(try RawStorage.read(for: created).first)
        local.body = "local concurrent edit"
        try RawStorage.rewrite([local], for: created)

        let result = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "remote concurrent edit",
            createdAt: created,
            revision: 2,
            sequence: 2,
            contentHash: "remote-hash"
        )])

        let memos = try RawStorage.read(for: created)
        XCTAssertEqual(memos.first(where: { $0.id == memoID })?.body, "remote concurrent edit")
        let conflictID = try XCTUnwrap(result.conflictCopies.first)
        XCTAssertEqual(memos.first(where: { $0.id == conflictID })?.body, "local concurrent edit")
        let pending = try SyncOutboxStore.pendingOperations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.memoID, conflictID)
        XCTAssertEqual(pending.first?.revision, 1)
    }

    func testRemoteTombstoneDeletesCanonicalWithoutEcho() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "delete on device A",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])
        let deletion = makeChange(
            id: memoID,
            body: "",
            createdAt: created,
            revision: 2,
            sequence: 2,
            deletedAt: Date(timeIntervalSince1970: 1_787_500_900)
        )

        let result = try RawStorage.applyRemoteChanges([deletion])

        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertTrue(try RawStorage.read(for: created).isEmpty)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }

    func testRemoteTombstonePreservesPendingLocalUpsertEvenWhenHashMatches() throws {
        let created = Date(timeIntervalSince1970: 1_787_500_800)
        let memoID = UUID()
        _ = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "base",
            createdAt: created,
            revision: 1,
            sequence: 1
        )])
        var local = try XCTUnwrap(try RawStorage.read(for: created).first)
        local.body = "keep this local text"
        try RawStorage.rewrite([local], for: created)
        let localHash = try XCTUnwrap(
            SyncOutboxStore.pendingOperations().first?.contentHash
        )

        let result = try RawStorage.applyRemoteChanges([makeChange(
            id: memoID,
            body: "",
            createdAt: created,
            revision: 2,
            sequence: 2,
            contentHash: localHash,
            deletedAt: Date(timeIntervalSince1970: 1_787_500_900)
        )])

        XCTAssertNil(try RawStorage.read(for: created).first(where: { $0.id == memoID }))
        let conflictID = try XCTUnwrap(result.conflictCopies.first)
        XCTAssertEqual(
            try RawStorage.read(for: created).first(where: { $0.id == conflictID })?.body,
            "keep this local text"
        )
    }

    private func makeChange(
        id: UUID,
        body: String,
        createdAt: Date,
        revision: Int64,
        sequence: Int64,
        contentHash: String? = nil,
        deletedAt: Date? = nil
    ) -> SyncRemoteChange {
        SyncRemoteChange(
            id: id,
            type: "text",
            body: body,
            createdAt: createdAt,
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: "Mac A",
            source: "macos",
            vaultPath: "raw/2026-08-24.md",
            sourceModifiedAt: createdAt,
            contentHash: contentHash,
            syncRevision: revision,
            lastSyncDeviceId: UUID().uuidString.lowercased(),
            deletedAt: deletedAt,
            changeSequence: sequence
        )
    }
}

private struct PullStubTransport: HTTPTransport {
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

final class SupabaseSyncPullerTests: XCTestCase {
    func testDecodesMonotonicPullPageAndSendsCursor() async throws {
        let memoID = UUID()
        let data = try JSONSerialization.data(withJSONObject: [
            "changes": [[
                "id": memoID.uuidString.lowercased(),
                "type": "text",
                "body": "remote",
                "created_at": "2026-08-24T00:00:00.123Z",
                "pinned_at": NSNull(),
                "location": NSNull(),
                "weather": NSNull(),
                "device": NSNull(),
                "source": "macos",
                "vault_path": "raw/2026-08-24.md",
                "source_modified_at": "2026-08-24T00:00:00Z",
                "content_hash": "hash",
                "sync_revision": 3,
                "last_sync_device_id": NSNull(),
                "deleted_at": NSNull(),
                "change_sequence": 91,
            ]],
            "next_cursor": 91,
            "has_more": false,
        ])
        let puller = SupabaseSyncPuller(
            supabaseURL: URL(string: "https://example.supabase.co")!,
            anonKey: "anon",
            transport: PullStubTransport(data: data, status: 200),
            accessTokenProvider: { "session" }
        )

        let page = try await puller.pull(after: 90, limit: 50)

        XCTAssertEqual(page.nextCursor, 91)
        XCTAssertEqual(page.changes.first?.id, memoID)
        XCTAssertEqual(page.changes.first?.syncRevision, 3)
        XCTAssertTrue(page.isValid(after: 90))
    }

    func testRejectsCursorThatCouldSkipOrReplayChanges() throws {
        let change = SyncRemoteChange(
            id: UUID(),
            type: "text",
            body: "remote",
            createdAt: Date(),
            pinnedAt: nil,
            location: nil,
            weather: nil,
            device: nil,
            source: "macos",
            vaultPath: nil,
            sourceModifiedAt: nil,
            contentHash: nil,
            syncRevision: 1,
            lastSyncDeviceId: nil,
            deletedAt: nil,
            changeSequence: 91
        )

        XCTAssertFalse(SyncPullPage(
            changes: [change],
            nextCursor: 92,
            hasMore: false
        ).isValid(after: 90))
        XCTAssertFalse(SyncPullPage(
            changes: [],
            nextCursor: 90,
            hasMore: true
        ).isValid(after: 90))
    }

    func testDecodesLegacyStringWeatherWithoutRejectingWholePage() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "changes": [[
                "id": UUID().uuidString,
                "type": "text",
                "body": "legacy weather",
                "created_at": "2026-08-24T00:00:00Z",
                "weather": "晴",
                "source": "web",
                "sync_revision": 0,
                "change_sequence": 1,
            ]],
            "next_cursor": 1,
            "has_more": false,
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601

        let page = try decoder.decode(SyncPullPage.self, from: data)

        XCTAssertEqual(page.changes.first?.weather?.condition, "晴")
    }
}
