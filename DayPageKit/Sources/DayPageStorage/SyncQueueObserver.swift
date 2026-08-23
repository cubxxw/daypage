// SyncQueueObserver.swift — Round 6 (R6-HIGH: flush 占位 service)
//
// Listens for `.syncQueueFlushRequested` (posted by SyncQueueService when
// the network comes back or a manual retry is triggered) and walks the
// pending memo set, handing each ID off to a `RemoteUploader`. On success
// the memo is removed from the queue via `markSynced`; on failure we
// breadcrumb and abort the current pass so the next trigger gets a fresh
// chance instead of hammering a server that's already saying no.
//
// Why this lives in its own file:
//   - SyncQueueService deliberately doesn't import any networking layer,
//     so the flush trigger is a NotificationCenter post. Some component
//     has to observe that post and perform the work — that's us.
//   - The real Supabase uploader will land in a later round. Until then
//     `NoopRemoteUploader` simulates a successful round-trip so the UI
//     (pendingCount banner) at least drains when we're online, instead
//     of pretending forever that nothing was synced.

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

    /// Injected by the app after it has a Supabase session. The unconfigured
    /// uploader always fails closed and therefore can never falsely drain data.
    private var uploader: RemoteUploader = NoopRemoteUploader()

    private init() {
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

    /// Swap in the production uploader. Tests call this with a stub that
    /// asserts ordering / failure behaviour. The real sync service
    /// will call it at app launch, post-AuthService.
    public func setUploader(_ uploader: RemoteUploader) {
        self.uploader = uploader
    }

    /// #785: pick the right uploader based on the user's sync configuration.
    /// Legacy API-key bridge retained for existing dogfood installs. New app
    /// sessions install `SupabaseSyncUploader` directly from RootView.
    public func installConfiguredUploader() {
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

        guard let operations = try? SyncOutboxStore.pendingOperations(),
              !operations.isEmpty,
              SyncQueueService.shared.beginFlush() else { return }
        defer { SyncQueueService.shared.endFlush() }

        for operation in operations {
            do {
                _ = try await uploader.upload(operation: operation)
                try SyncOutboxStore.acknowledge(operationID: operation.operationID)
                SyncQueueService.shared.reloadFromOutbox()
            } catch {
                // Network/server problem — stop this pass so we don't
                // burn through retries pointlessly. The next online
                // transition or manual trigger will resume.
                SentryReporter.breadcrumb(
                    category: "syncqueue",
                    level: .warning,
                    message: "upload failed for \(operation.memoID): \(error)"
                )
                break
            }
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
