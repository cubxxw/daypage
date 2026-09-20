import Foundation
import Testing
import DayPageServices
@testable import DayPageStorage

@Suite("Account sync status")
struct AccountSyncStatusTests {
    private let successDate = Date(timeIntervalSince1970: 1_789_000_000)

    @Test("An empty queue without successful sync is unverified and retryable")
    func emptyQueueIsNotSuccess() {
        let status = resolve()
        #expect(status == .unverified)
        #expect(status.canRetry)
    }

    @Test("Signed out, offline, and active sync take precedence over old health")
    func immediateStatePrecedence() {
        let failure = SyncHealthSnapshot(lastFailureStage: "pull", consecutiveFailureCount: 1)
        let signedOut = AccountSyncStatus.resolve(
            isSignedIn: false, isOffline: true, isFlushing: true,
            pendingCount: 3, health: failure
        )
        #expect(signedOut == .localOnly)
        #expect(!signedOut.canRetry)
        let offline = AccountSyncStatus.resolve(
            isSignedIn: true, isOffline: true, isFlushing: true,
            pendingCount: 3, health: failure
        )
        #expect(offline == .offline(pendingCount: 3))
        #expect(!offline.canRetry)
        let syncing = resolve(isFlushing: true, health: failure)
        #expect(syncing == .syncing)
        #expect(!syncing.canRetry)
    }

    @Test("Failed pull is visible with no uploads and after an earlier success")
    func pullFailureOverridesEmptyQueueAndPriorSuccess() {
        let health = SyncHealthSnapshot(
            lastSuccessAt: successDate,
            lastFailureAt: successDate.addingTimeInterval(1),
            lastFailureStage: "pull",
            lastFailureCode: "server_error",
            lastHTTPStatus: 503,
            consecutiveFailureCount: 1
        )
        #expect(resolve(health: health) == .failed(.pull))
        #expect(resolve(health: health).canRetry)
        #expect(resolve(pendingCount: 2, health: health) == .failed(.pull))
    }

    @Test("Server upload failure remains retryable and does not disappear behind pending")
    func uploadFailure() {
        let health = SyncHealthSnapshot(
            lastFailureStage: "push", lastFailureCode: "server_error",
            lastHTTPStatus: 500, consecutiveFailureCount: 1
        )
        #expect(resolve(pendingCount: 1, health: health) == .failed(.other))
        #expect(resolve(pendingCount: 1, health: health).canRetry)
    }

    @Test("Rejected account binding does not suggest a sync retry can repair the account")
    func accountSetupFailure() {
        let health = SyncHealthSnapshot(
            lastSuccessAt: successDate,
            lastFailureStage: "preflight", lastFailureCode: "conflict",
            consecutiveFailureCount: 1
        )
        #expect(resolve(health: health) == .failed(.setup))
        #expect(!resolve(health: health).canRetry)
        let event = OperationalEvent(
            area: "sync", stage: "preflight", code: "conflict", correlationID: UUID()
        )
        #expect(event.stage == "preflight")
        #expect(event.code == "conflict")
    }

    @Test("An interrupted newer pass must be checked before claiming success")
    func interruptedAttempt() {
        let health = SyncHealthSnapshot(
            lastAttemptAt: successDate.addingTimeInterval(1), lastSuccessAt: successDate
        )
        #expect(resolve(health: health) == .unverified)
        #expect(resolve(health: health).canRetry)
    }

    @Test("Pending uploads override old success but resolved old failures do not")
    func pendingAndResolvedFailure() {
        let health = SyncHealthSnapshot(
            lastSuccessAt: successDate,
            lastFailureAt: successDate.addingTimeInterval(-1),
            lastFailureStage: "pull",
            consecutiveFailureCount: 0
        )
        #expect(resolve(pendingCount: 2, health: health) == .pending(count: 2))
        #expect(resolve(pendingCount: 2, health: health).canRetry)
        #expect(resolve(health: health) == .synced)
        #expect(!resolve(health: health).canRetry)
    }

    @MainActor
    @Test("Service health survives restart and a zero-upload retry reaches success")
    func serviceFailureRetrySuccess() throws {
        let suite = "AccountSyncStatusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SyncQueueService.makeForTesting(defaults: defaults)
        #expect(resolve(health: service.syncHealth) == .unverified)
        #expect(service.pendingCount == 0)

        service.recordSyncAttempt(correlationID: UUID(), pendingCount: 0, at: successDate)
        service.recordSyncFailure(
            stage: "pull", code: "server_error", httpStatus: 503,
            at: successDate.addingTimeInterval(1)
        )
        let restored = SyncQueueService.makeForTesting(defaults: defaults)
        #expect(resolve(health: restored.syncHealth) == .failed(.pull))
        #expect(resolve(health: restored.syncHealth).canRetry)

        #expect(restored.beginFlush())
        restored.recordSyncAttempt(
            correlationID: UUID(), pendingCount: 0, at: successDate.addingTimeInterval(2)
        )
        #expect(resolve(isFlushing: restored.isFlushingNow, health: restored.syncHealth) == .syncing)
        restored.recordSyncSuccess(at: successDate.addingTimeInterval(3))
        restored.endFlush()
        #expect(restored.pendingCount == 0)
        #expect(resolve(health: restored.syncHealth) == .synced)
        #expect(!resolve(health: restored.syncHealth).canRetry)
        let successfulRestart = SyncQueueService.makeForTesting(defaults: defaults)
        #expect(resolve(health: successfulRestart.syncHealth) == .synced)
    }

    private func resolve(
        isFlushing: Bool = false,
        pendingCount: Int = 0,
        health: SyncHealthSnapshot = .init()
    ) -> AccountSyncStatus {
        AccountSyncStatus.resolve(
            isSignedIn: true, isOffline: false, isFlushing: isFlushing,
            pendingCount: pendingCount, health: health
        )
    }
}
