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

    /// Injected by the app after it has a Supabase session. The unconfigured
    /// uploader always fails closed and therefore can never falsely drain data.
    private var uploader: RemoteUploader = NoopRemoteUploader()

    init(observeNotifications: Bool = true) {
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
        try SyncAccountStateStore.bind(to: userID)
        self.accountID = userID
        self.uploader = uploader
        self.puller = puller
        startPeriodicSync(interval: periodicInterval)
    }

    public func clearSession() {
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
        guard accountID == nil else { return }
        if SyncSettings.isConfigured {
            self.uploader = MemoSyncUploader()
        } else {
            self.uploader = NoopRemoteUploader()
        }
    }

    /// Walk every pending ID once. We grab the snapshot up-front so a
    /// concurrent enqueue (e.g. user types a new memo mid-flush) doesn't
    /// mutate the set under our feet; the new memo will be picked up by
    /// the next flush trigger anyway.
    public func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        guard SyncQueueService.shared.beginFlush() else { return }
        defer { SyncQueueService.shared.endFlush() }

        let correlationID = UUID()
        SyncQueueService.shared.recordSyncAttempt(
            correlationID: correlationID,
            pendingCount: SyncQueueService.shared.pendingCount
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
                try SyncOutboxStore.acknowledge(operationID: operation.operationID)
                if operation.kind == .delete {
                    try? AttachmentTransferStore.discardTransfers(
                        memoIDs: [operation.memoID]
                    )
                }
                SyncQueueService.shared.reloadFromOutbox()
            } catch is AttachmentSyncError {
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
                recordFailure(stage: "push", error: error, correlationID: correlationID)
                if case .conflict = error {
                    // Keep the operation until pull preserves the local variant
                    // and installs the newer remote canonical revision.
                    break uploadLoop
                }
                return
            } catch {
                // Network/server problem — stop this pass so we don't
                // burn through retries pointlessly. The next online
                // transition or manual trigger will resume.
                recordFailure(stage: "push", error: error, correlationID: correlationID)
                return
            }
        }

        guard let puller, let accountID else {
            if SyncSettings.isConfigured {
                SyncQueueService.shared.recordSyncSuccess()
            }
            return
        }
        do {
            try await pullAllChanges(using: puller, accountID: accountID)
            SyncQueueService.shared.recordSyncSuccess()
        } catch {
            recordFailure(stage: "pull", error: error, correlationID: correlationID)
        }
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

        let queue = SyncQueueService.shared
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

    private func pullAllChanges(using puller: RemotePuller, accountID: UUID) async throws {
        for _ in 0..<20 {
            let cursor = try SyncAccountStateStore.pullCursor(for: accountID)
            let page = try await puller.pull(after: cursor, limit: 200)
            guard page.isValid(after: cursor) else {
                throw MemoSyncError.invalidResponse
            }
            if !page.changes.isEmpty {
                _ = try await Task.detached(priority: .utility) {
                    try RawStorage.applyRemoteChanges(page.changes)
                }.value
                try SyncAccountStateStore.advancePullCursor(
                    to: page.nextCursor,
                    for: accountID
                )
                SyncQueueService.shared.reloadFromOutbox()
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
