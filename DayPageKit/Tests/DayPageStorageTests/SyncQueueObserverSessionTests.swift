import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

@MainActor
final class SyncQueueObserverSessionTests: XCTestCase {
    private var vault: URL!
    private var previousVault: URL?
    private var defaults: UserDefaults!
    private var suite: String!
    private var service: SyncQueueService!
    private let boundAccount = UUID()

    override func setUpWithError() throws {
        previousVault = VaultInitializer.testOverrideURL
        vault = FileManager.default.temporaryDirectory.appendingPathComponent("observer-session-\(UUID())")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("raw"), withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = vault
        suite = "SyncQueueObserverSessionTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        service = SyncQueueService.makeForTesting(defaults: defaults)
        try SyncAccountStateStore.bind(to: boundAccount)
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousVault
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: vault)
        service = nil
    }

    func testRejectedBindingBlocksPendingAndExplicitUploaderUntilValidSession() async throws {
        try seedPendingMemo()
        let uploader = SessionTestUploader()
        let puller = SessionTestPuller()
        let observer = makeObserver(legacyConfigured: true)
        rejectBinding(observer, uploader: uploader, puller: puller)
        let failure = service.syncHealth

        observer.installConfiguredUploader()
        observer.setUploader(uploader)
        await observer.flush()

        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        let blockedUploads = await uploader.count
        XCTAssertEqual(blockedUploads, 0)

        try observer.configureSession(userID: boundAccount, uploader: uploader, puller: puller, periodicInterval: 0)
        await observer.flush()

        XCTAssertEqual(service.syncHealth.consecutiveFailureCount, 0)
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
        let uploads = await uploader.count
        let pulls = await puller.count
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(pulls, 1)
        observer.clearSession()
    }

    func testRejectedBindingCannotUseLegacyEmptyQueueSuccessButExplicitSignOutCan() async throws {
        let observer = makeObserver(legacyConfigured: true)
        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        let failure = service.syncHealth

        await observer.flush()
        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertNil(service.syncHealth.lastSuccessAt)

        // This is an explicit signed-out reset, distinct from setup rejection.
        observer.clearSession()
        observer.installConfiguredUploader()
        await observer.flush()
        XCTAssertNotNil(service.syncHealth.lastSuccessAt)
        XCTAssertEqual(service.syncHealth.consecutiveFailureCount, 0)
    }

    func testUploaderOnlyInjectionStillDrainsOrdinaryUnrejectedQueue() async throws {
        try seedPendingMemo()
        let uploader = SessionTestUploader()
        let observer = makeObserver(legacyConfigured: false)
        observer.setUploader(uploader)
        await observer.flush()
        let uploads = await uploader.count
        XCTAssertEqual(uploads, 1)
        XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
    }

    func testOldPullCompletionCannotEraseRejectedBindingFailure() async throws {
        let puller = SuspendedSessionPuller()
        let observer = makeObserver(legacyConfigured: true)
        try observer.configureSession(userID: boundAccount, uploader: SessionTestUploader(), puller: puller, periodicInterval: 0)
        let flush = Task { await observer.flush() }
        await puller.waitUntilStarted()

        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        let failure = service.syncHealth
        await puller.finish()
        await flush.value

        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertNil(service.syncHealth.lastSuccessAt)
        XCTAssertFalse(service.isFlushingNow)
    }

    func testOldUploadReceiptCannotDrainAfterRejectedBinding() async throws {
        try seedPendingMemo()
        let uploader = SuspendedSessionUploader()
        let observer = makeObserver(legacyConfigured: true)
        try observer.configureSession(userID: boundAccount, uploader: uploader, puller: SessionTestPuller(), periodicInterval: 0)
        let flush = Task { await observer.flush() }
        await uploader.waitUntilStarted()

        rejectBinding(observer, uploader: SessionTestUploader(), puller: SessionTestPuller())
        let failure = service.syncHealth
        await uploader.finish()
        await flush.value

        XCTAssertEqual(service.syncHealth, failure)
        XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, 1)
        XCTAssertFalse(service.isFlushingNow)
    }

    private func makeObserver(legacyConfigured: Bool) -> SyncQueueObserver {
        SyncQueueObserver(observeNotifications: false, syncQueue: service, legacyIsConfigured: { legacyConfigured })
    }

    private func seedPendingMemo() throws {
        let memo = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "synthetic session fixture")
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/2026-08-23.md")
    }

    private func rejectBinding(_ observer: SyncQueueObserver, uploader: RemoteUploader, puller: RemotePuller) {
        XCTAssertThrowsError(try observer.configureSession(userID: UUID(), uploader: uploader, puller: puller, periodicInterval: 0))
        // Match RootView's rejected-configuration cleanup and bounded failure.
        observer.clearSession(rejectedConfiguration: true)
        service.recordSyncFailure(stage: "preflight", code: "conflict", httpStatus: nil)
    }
}

private actor SessionTestUploader: RemoteUploader {
    private(set) var count = 0
    func upload(operation: SyncOutboxOperation) async throws -> Int {
        count += 1
        return operation.sizeBytes
    }
}

private actor SessionTestPuller: RemotePuller {
    private(set) var count = 0
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        count += 1
        return SyncPullPage(changes: [], nextCursor: cursor, hasMore: false)
    }
}

private actor SuspendedSessionPuller: RemotePuller {
    private var pending: CheckedContinuation<SyncPullPage, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func pull(after cursor: Int64, limit: Int) async throws -> SyncPullPage {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        pending?.resume(returning: SyncPullPage(changes: [], nextCursor: 0, hasMore: false))
        pending = nil
    }
}

private actor SuspendedSessionUploader: RemoteUploader {
    private var pending: CheckedContinuation<Int, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func upload(operation: SyncOutboxOperation) async throws -> Int {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        pending?.resume(returning: 0)
        pending = nil
    }
}
