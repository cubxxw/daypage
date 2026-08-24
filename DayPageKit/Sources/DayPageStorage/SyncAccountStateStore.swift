import Foundation

/// Account and pull-cursor metadata for one local Vault.
///
/// A Vault is deliberately bound to the first authenticated Supabase user that
/// syncs it. A later login for another user fails closed instead of uploading
/// the previous account's pending notes under the new session.
public enum SyncAccountStateError: LocalizedError, Equatable {
    case accountMismatch(expected: UUID, actual: UUID)
    case invalidState

    public var errorDescription: String? {
        switch self {
        case .accountMismatch:
            return "此本地 Vault 已绑定到另一个 DayPage 账户"
        case .invalidState:
            return "本地同步账户状态已损坏"
        }
    }
}

public enum SyncAccountStateStore {
    private struct State: Codable {
        var schemaVersion: Int = 1
        var userID: UUID
        var pullCursor: Int64 = 0

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case userID = "user_id"
            case pullCursor = "pull_cursor"
        }
    }

    private static let queue = DispatchQueue(label: "com.daypage.sync-account-state")

    public static var stateURL: URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("account-v1.json")
    }

    /// Claims an unbound Vault for `userID`, or validates an existing binding.
    @discardableResult
    public static func bind(to userID: UUID) throws -> Int64 {
        try queue.sync {
            if let state = try loadIfPresent() {
                guard state.userID == userID else {
                    throw SyncAccountStateError.accountMismatch(
                        expected: state.userID,
                        actual: userID
                    )
                }
                return state.pullCursor
            }
            let state = State(userID: userID)
            try save(state)
            return state.pullCursor
        }
    }

    public static func boundUserID() throws -> UUID? {
        try queue.sync { try loadIfPresent()?.userID }
    }

    public static func pullCursor(for userID: UUID) throws -> Int64 {
        try queue.sync {
            guard let state = try loadIfPresent() else {
                throw SyncAccountStateError.invalidState
            }
            guard state.userID == userID else {
                throw SyncAccountStateError.accountMismatch(expected: state.userID, actual: userID)
            }
            return state.pullCursor
        }
    }

    /// Cursor updates are monotonic so a delayed page can never move a device
    /// backwards and replay already-applied changes indefinitely.
    public static func advancePullCursor(to cursor: Int64, for userID: UUID) throws {
        try queue.sync {
            guard var state = try loadIfPresent() else {
                throw SyncAccountStateError.invalidState
            }
            guard state.userID == userID else {
                throw SyncAccountStateError.accountMismatch(expected: state.userID, actual: userID)
            }
            guard cursor >= state.pullCursor else { return }
            state.pullCursor = cursor
            try save(state)
        }
    }

    private static func loadIfPresent() throws -> State? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        guard state.schemaVersion == 1, state.pullCursor >= 0 else {
            throw SyncAccountStateError.invalidState
        }
        return state
    }

    private static func save(_ state: State) throws {
        let url = stateURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: [.atomic])
    }
}
