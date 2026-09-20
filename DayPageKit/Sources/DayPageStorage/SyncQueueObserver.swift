// SyncQueueObserver.swift — Round 6 (R6-HIGH: flush 占位 service)
//
// Listens for `.syncQueueFlushRequested` (local write, network recovery,
// foreground activation, periodic poll, or manual retry). It uploads the
// durable outbox first, acknowledges only exact RPC receipts, then pulls and
// applies the authenticated account's monotonic remote change pages.
//
// Why this lives in its own file:
//   - SyncQueueService deliberately doesn't import any networking layer,
//     so the flush trigger is a NotificationCenter post. Some component
//     has to observe that post and perform the work — that's us.
//   - `NoopRemoteUploader` is deliberately fail-closed. Before auth/session
//     configuration it can never drain the outbox or imply cloud durability.

import Foundation

/// Pluggable contract for uploading one durable outbox operation. The exact
/// operation ID must be echoed by the server before the observer removes it.
public protocol RemoteUploader: Sendable {
    func upload(operation: SyncOutboxOperation) async throws -> Int
}

/// Fail-closed fallback used before an authenticated Supabase session exists.
/// It must never remove an outbox operation or imply that data reached cloud.
public struct NoopRemoteUploader: RemoteUploader {
    public init() {}

    public func upload(operation: SyncOutboxOperation) async throws -> Int {
        throw MemoSyncError.notConfigured
    }
}

@MainActor
public final class SyncQueueObserver {
    public static let shared = SyncQueueObserver()

    private var observer: NSObjectProtocol?
    private var isFlushing = false
    private var puller: RemotePuller?
    private var accountID: UUID?
    private var periodicTask: Task<Void, Never>?
    private var rejectedConfiguration = false
    private var sessionGeneration: UInt = 0
    private let syncQueue: SyncQueueService
    private let legacyIsConfigured: () -> Bool

    /// Injected by the app after it has a Supabase session. The unconfigured
    /// uploader always fails closed and therefore can never falsely drain data.
    private var uploader: RemoteUploader = NoopRemoteUploader()

    init(
        observeNotifications: Bool = true,
        syncQueue: SyncQueueService? = nil,
        legacyIsConfigured: @escaping () -> Bool = { SyncSettings.isConfigured }
    ) {
        self.syncQueue = syncQueue ?? .shared
        self.legacyIsConfigured = legacyIsConfigured
        guard observeNotifications else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .syncQueueFlushRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.flush()
            }
        }
    }

    /// Legacy uploader-only injection retained for tests and the diagnostic
    /// API-key bridge. Normal app sessions use `configureSession` so pull and
    /// account binding are installed atomically with the uploader.
    public func setUploader(_ uploader: RemoteUploader) {
        sessionGeneration &+= 1
        self.uploader = uploader
    }

    /// Installs the complete push + pull session after binding the local Vault
    /// to the authenticated user. A different account fails closed.
    public func configureSession(
        userID: UUID,
        uploader: RemoteUploader,
        puller: RemotePuller,
        periodicInterval: TimeInterval = 30
    ) throws {
        do {
            try SyncAccountStateStore.bind(to: userID)
        } catch {
            clearSession(rejectedConfiguration: true)
            throw error
        }
        sessionGeneration &+= 1
        rejectedConfiguration = false
        self.accountID = userID
        self.uploader = uploader
        self.puller = puller
        startPeriodicSync(interval: periodicInterval)
    }

    /// Explicit sign-out clears the rejection. A failed session setup keeps
    /// automatic/legacy sync blocked until a valid session is configured.
    public func clearSession(rejectedConfiguration: Bool = false) {
        sessionGeneration &+= 1
        self.rejectedConfiguration = rejectedConfiguration
        periodicTask?.cancel()
        periodicTask = nil
        accountID = nil
        puller = nil
        uploader = NoopRemoteUploader()
    }

    /// #785: pick the right uploader based on the user's sync configuration.
    /// Legacy API-key bridge retained for existing dogfood installs. New app
    /// sessions install `SupabaseSyncUploader` directly from RootView.
    public func installConfiguredUploader() {
        guard accountID == nil, !rejectedConfiguration else { return }
        if legacyIsConfigured() {
            setUploader(MemoSyncUploader())
        } else {
            setUploader(NoopRemoteUploader())
        }
    }

    /// Walk every pending ID once. We grab the snapshot up-front so a
    /// concurrent enqueue (e.g. user types a new memo mid-flush) doesn't
    /// mutate the set under our feet; the new memo will be picked up by
    /// the next flush trigger anyway.
    public func flush() async {
        guard !isFlushing, !rejectedConfiguration else { return }
        let generation = sessionGeneration
        let uploader = self.uploader
        let puller = self.puller
        let accountID = self.accountID
        isFlushing = true
        defer { isFlushing = false }

        guard syncQueue.beginFlush() else { return }
        defer { syncQueue.endFlush() }

        let correlationID = UUID()
        syncQueue.recordSyncAttempt(
            correlationID: correlationID,
            pendingCount: syncQueue.pendingCount
        )

        let operations: [SyncOutboxOperation]
        do {
            operations = try SyncOutboxStore.pendingOperations()
        } catch {
            recordFailure(stage: "outbox_read", error: error, correlationID: correlationID)
            return
        }

        uploadLoop: for operation in operations {
            do {
                _ = try await uploader.upload(operation: operation)
                guard isCurrentSession(generation) else { return }
                try SyncOutboxStore.acknowledge(operationID: operation.operationID)
                if operation.kind == .delete {
                    try? AttachmentTransferStore.discardTransfers(
                        memoIDs: [operation.memoID]
                    )
                }
                syncQueue.reloadFromOutbox()
            } catch is AttachmentSyncError {
                guard isCurrentSession(generation) else { return }
                // Media has its own durable sidecar. Leave this memo pending,
                // continue unrelated text operations, and still pull remote
                // changes so a large or unsupported file cannot stall sync.
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "attachment deferred for \(operation.memoID)"
                )
                continue uploadLoop
            } catch let error as MemoSyncError {
                guard isCurrentSession(generation) else { return }
                recordFailure(stage: "push", error: error, correlationID: correlationID)
                if case .conflict = error {
                    // Keep the operation until pull preserves the local variant
                    // and installs the newer remote canonical revision.
                    break uploadLoop
                }
                return
            } catch {
                guard isCurrentSession(generation) else { return }
                // Network/server problem — stop this pass so we don't
                // burn through retries pointlessly. The next online
                // transition or manual trigger will resume.
                recordFailure(stage: "push", error: error, correlationID: correlationID)
                return
            }
        }

        guard let puller, let accountID else {
            if legacyIsConfigured() {
                syncQueue.recordSyncSuccess()
            }
            return
        }
        do {
            try await pullAllChanges(using: puller, accountID: accountID, generation: generation)
            guard isCurrentSession(generation) else { return }
            syncQueue.recordSyncSuccess()
        } catch {
            guard isCurrentSession(generation) else { return }
            recordFailure(stage: "pull", error: error, correlationID: correlationID)
        }
    }

    private func isCurrentSession(_ generation: UInt) -> Bool {
        !rejectedConfiguration && sessionGeneration == generation
    }

    private func recordFailure(stage: String, error: Error, correlationID: UUID) {
        let diagnostic: (code: String, httpStatus: Int?)
        if let syncError = error as? MemoSyncError {
            diagnostic = (syncError.diagnosticCode, syncError.diagnosticHTTPStatus)
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                diagnostic = ("network_unavailable", nil)
            case .timedOut:
                diagnostic = ("network_timeout", nil)
            default:
                diagnostic = ("network_error", nil)
            }
        } else {
            diagnostic = ("unexpected", nil)
        }

        let queue = syncQueue
        let networkState: OperationalEvent.NetworkState = NetworkMonitor.shared.isOnline ? .online : .offline
        let boundedEvent = OperationalEvent(
            area: "sync",
            stage: stage,
            code: diagnostic.code,
            correlationID: correlationID,
            level: diagnostic.code == "unexpected" ? .error : .warning,
            httpStatus: diagnostic.httpStatus,
            networkState: networkState,
            pendingCount: queue.pendingCount
        )
        let shouldReport = queue.recordSyncFailure(
            stage: boundedEvent.stage,
            code: boundedEvent.code,
            httpStatus: boundedEvent.httpStatus
        )
        let safeMessage = "stage=\(boundedEvent.stage) code=\(boundedEvent.code) correlation=\(boundedEvent.correlationID)"
        DayPageLogger.shared.warn("[Sync] \(safeMessage)")
        SentryReporter.breadcrumb(
            category: "syncqueue",
            level: .warning,
            message: safeMessage
        )
        guard shouldReport else { return }
        SentryReporter.captureOperationalEvent(OperationalEvent(
            area: "sync",
            stage: boundedEvent.stage,
            code: boundedEvent.code,
            correlationID: correlationID,
            level: boundedEvent.level,
            httpStatus: boundedEvent.httpStatus,
            networkState: boundedEvent.networkState,
            pendingCount: queue.pendingCount,
            consecutiveFailureCount: queue.syncHealth.consecutiveFailureCount
        ))
    }

    private func pullAllChanges(using puller: RemotePuller, accountID: UUID, generation: UInt) async throws {
        for _ in 0..<20 {
            guard isCurrentSession(generation) else { throw CancellationError() }
            let cursor = try SyncAccountStateStore.pullCursor(for: accountID)
            let page = try await puller.pull(after: cursor, limit: 200)
            guard isCurrentSession(generation) else { throw CancellationError() }
            guard page.isValid(after: cursor) else {
                throw MemoSyncError.invalidResponse
            }
            if !page.changes.isEmpty {
                _ = try await Task.detached(priority: .utility) {
                    try RawStorage.applyRemoteChanges(page.changes)
                }.value
                guard isCurrentSession(generation) else { throw CancellationError() }
                try SyncAccountStateStore.advancePullCursor(
                    to: page.nextCursor,
                    for: accountID
                )
                syncQueue.reloadFromOutbox()
            }
            if !page.hasMore { return }
            guard !page.changes.isEmpty else { throw MemoSyncError.invalidResponse }
        }
        throw MemoSyncError.rejected(reason: "pull pagination limit exceeded")
    }

    private func startPeriodicSync(interval: TimeInterval) {
        periodicTask?.cancel()
        guard interval > 0 else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled, NetworkMonitor.shared.isOnline else { continue }
                await self?.flush()
            }
        }
    }

    deinit {
        periodicTask?.cancel()
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
