import Foundation
import DayPageStorage

/// The account screen must distinguish an empty upload queue from a completed
/// push-and-pull pass. Kept independent of SwiftUI so all states are testable.
public enum AccountSyncStatus: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        case setup
        case pull
        case other
    }

    case localOnly
    case offline(pendingCount: Int)
    case syncing
    case failed(Failure)
    case pending(count: Int)
    case unverified
    case synced

    public static func resolve(
        isSignedIn: Bool,
        isOffline: Bool,
        isFlushing: Bool,
        pendingCount: Int,
        health: SyncHealthSnapshot
    ) -> Self {
        guard isSignedIn else { return .localOnly }
        if isOffline { return .offline(pendingCount: max(0, pendingCount)) }
        if isFlushing { return .syncing }

        // Success clears this counter, while the latest failure fields remain
        // available for diagnostics. Do not resurrect a resolved old failure.
        if health.consecutiveFailureCount > 0 {
            switch health.lastFailureStage {
            case "preflight": return .failed(.setup)
            case "pull": return .failed(.pull)
            default: return .failed(.other)
            }
        }
        if pendingCount > 0 { return .pending(count: pendingCount) }
        guard let lastSuccess = health.lastSuccessAt else { return .unverified }

        // A newer attempt with no recorded result may have been interrupted by
        // process termination. Its queue being empty does not prove pull worked.
        if let lastAttempt = health.lastAttemptAt, lastAttempt > lastSuccess {
            return .unverified
        }
        return .synced
    }

    public var canRetry: Bool {
        switch self {
        case .failed(.pull), .failed(.other), .pending, .unverified: return true
        case .localOnly, .offline, .syncing, .failed(.setup), .synced: return false
        }
    }
}
