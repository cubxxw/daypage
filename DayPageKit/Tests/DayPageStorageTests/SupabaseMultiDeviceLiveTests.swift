import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

/// Opt-in staging acceptance test. It uses one real Supabase Auth session and
/// two independent local Vault directories to exercise the same HTTP push and
/// pull implementations installed by the iOS and macOS apps.
///
/// Required environment variables:
/// - DAYPAGE_SYNC_E2E_URL
/// - DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY
/// - DAYPAGE_SYNC_E2E_ACCESS_TOKEN
/// - DAYPAGE_SYNC_E2E_USER_ID
final class SupabaseMultiDeviceLiveTests: XCTestCase {
    private struct Configuration {
        let url: URL
        let anonKey: String
        let accessToken: String
        let userID: UUID

        static func load() throws -> Configuration {
            let environment = ProcessInfo.processInfo.environment
            guard let urlValue = environment["DAYPAGE_SYNC_E2E_URL"],
                  let url = URL(string: urlValue),
                  let anonKey = environment["DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY"],
                  !anonKey.isEmpty,
                  let accessToken = environment["DAYPAGE_SYNC_E2E_ACCESS_TOKEN"],
                  !accessToken.isEmpty,
                  let userValue = environment["DAYPAGE_SYNC_E2E_USER_ID"],
                  let userID = UUID(uuidString: userValue) else {
                throw XCTSkip("staging Supabase sync credentials are not configured")
            }
            return Configuration(
                url: url,
                anonKey: anonKey,
                accessToken: accessToken,
                userID: userID
            )
        }
    }

    func testTwoVaultsRoundTripCreateEditAndDelete() async throws {
        let configuration = try Configuration.load()
        let baseDirectory = ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = baseDirectory
            .appendingPathComponent("daypage-live-multidevice-\(UUID().uuidString)", isDirectory: true)
        let vaultA = root.appendingPathComponent("device-a", isDirectory: true)
        let vaultB = root.appendingPathComponent("device-b", isDirectory: true)
        try prepare(vaultA)
        try prepare(vaultB)
        defer {
            VaultInitializer.testOverrideURL = nil
            try? FileManager.default.removeItem(at: root)
        }

        let tokenProvider: @Sendable () async throws -> String = {
            configuration.accessToken
        }
        let uploader = SupabaseSyncUploader(
            supabaseURL: configuration.url,
            anonKey: configuration.anonKey,
            accessTokenProvider: tokenProvider
        )
        let puller = SupabaseSyncPuller(
            supabaseURL: configuration.url,
            anonKey: configuration.anonKey,
            accessTokenProvider: tokenProvider
        )
        let created = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let memo = Memo(
            created: created,
            device: "staging-device-a",
            body: "DAYPAGE_MULTI_DEVICE_CREATE_\(UUID().uuidString)"
        )

        try select(vaultA, userID: configuration.userID)
        try RawStorage.append(memo)
        try await uploadOnlyOperation(for: memo.id, using: uploader)
        try await pullAll(using: puller, in: vaultA, userID: configuration.userID)

        try select(vaultB, userID: configuration.userID)
        try await pullAll(using: puller, in: vaultB, userID: configuration.userID)
        XCTAssertEqual(try memoFromSelectedVault(memo.id, on: created)?.body, memo.body)

        var deviceBMemos = try RawStorage.read(for: created)
        let editedIndex = try XCTUnwrap(deviceBMemos.firstIndex(where: { $0.id == memo.id }))
        deviceBMemos[editedIndex].body = "DAYPAGE_MULTI_DEVICE_EDIT_\(UUID().uuidString)"
        let editedBody = deviceBMemos[editedIndex].body
        try RawStorage.rewrite(deviceBMemos, for: created)
        try await uploadOnlyOperation(for: memo.id, using: uploader)
        try await pullAll(using: puller, in: vaultB, userID: configuration.userID)

        try select(vaultA, userID: configuration.userID)
        try await pullAll(using: puller, in: vaultA, userID: configuration.userID)
        XCTAssertEqual(try memoFromSelectedVault(memo.id, on: created)?.body, editedBody)

        let remaining = try RawStorage.read(for: created).filter { $0.id != memo.id }
        try RawStorage.rewrite(remaining, for: created)
        let deletion = try XCTUnwrap(
            try SyncOutboxStore.pendingOperations().first(where: { $0.memoID == memo.id })
        )
        XCTAssertEqual(deletion.kind, .delete)
        _ = try await uploader.upload(operation: deletion)
        try SyncOutboxStore.acknowledge(operationID: deletion.operationID)
        try await pullAll(using: puller, in: vaultA, userID: configuration.userID)

        try select(vaultB, userID: configuration.userID)
        try await pullAll(using: puller, in: vaultB, userID: configuration.userID)
        XCTAssertNil(try memoFromSelectedVault(memo.id, on: created))
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }

    private func prepare(_ vault: URL) throws {
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func select(_ vault: URL, userID: UUID) throws {
        VaultInitializer.testOverrideURL = vault
        _ = try SyncAccountStateStore.bind(to: userID)
    }

    private func uploadOnlyOperation(
        for memoID: UUID,
        using uploader: SupabaseSyncUploader
    ) async throws {
        let operation = try XCTUnwrap(
            try SyncOutboxStore.pendingOperations().first(where: { $0.memoID == memoID })
        )
        _ = try await uploader.upload(operation: operation)
        try SyncOutboxStore.acknowledge(operationID: operation.operationID)
    }

    private func pullAll(
        using puller: SupabaseSyncPuller,
        in vault: URL,
        userID: UUID
    ) async throws {
        try select(vault, userID: userID)
        for _ in 0..<10 {
            let cursor = try SyncAccountStateStore.pullCursor(for: userID)
            let page = try await puller.pull(after: cursor, limit: 100)
            XCTAssertGreaterThanOrEqual(page.nextCursor, cursor)
            _ = try RawStorage.applyRemoteChanges(page.changes)
            try SyncAccountStateStore.advancePullCursor(to: page.nextCursor, for: userID)
            if !page.hasMore { return }
            XCTAssertFalse(page.changes.isEmpty)
        }
        XCTFail("staging pull exceeded ten pages")
    }

    private func memoFromSelectedVault(_ id: UUID, on date: Date) throws -> Memo? {
        try RawStorage.read(for: date).first(where: { $0.id == id })
    }
}
