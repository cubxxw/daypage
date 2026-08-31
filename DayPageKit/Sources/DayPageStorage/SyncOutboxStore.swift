import CryptoKit
import Foundation
import DayPageModels

/// Durable, Vault-owned sync intent. Memo bodies remain in `raw/*.md`; this
/// sidecar records the exact revision that still needs a cloud receipt.
public struct SyncOutboxOperation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case upsert
        case delete
    }

    public let operationID: UUID
    public let memoID: UUID
    public let kind: Kind
    public let revision: Int64
    public let modifiedAt: Date
    public let contentHash: String?
    public let deviceID: String
    public let payload: SyncMemoPayload?
    public let sizeBytes: Int

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case memoID = "memo_id"
        case kind
        case revision
        case modifiedAt = "modified_at"
        case contentHash = "content_hash"
        case deviceID = "device_id"
        case payload
        case sizeBytes = "size_bytes"
    }
}

public struct SyncMemoPayload: Codable, Equatable, Sendable {
    public struct Location: Codable, Equatable, Sendable {
        public let name: String?
        public let lat: Double?
        public let lng: Double?
    }

    public struct Weather: Codable, Equatable, Sendable {
        public let condition: String
    }

    public let type: String
    public let body: String
    public let createdAt: Date
    public let pinnedAt: Date?
    public let location: Location?
    public let weather: Weather?
    public let device: String?
    public let source: String
    public let vaultPath: String

    enum CodingKeys: String, CodingKey {
        case type
        case body
        case createdAt = "created_at"
        case pinnedAt = "pinned_at"
        case location
        case weather
        case device
        case source
        case vaultPath = "vault_path"
    }
}

public enum SyncOutboxError: Error {
    case invalidState
    case acknowledgementMismatch
}

/// Serialises every sidecar mutation and atomically replaces
/// `vault/_agent/sync/outbox-v1.json`. A receipt removes only the exact
/// operation ID it acknowledges, so an older response can never clear a newer
/// edit for the same memo.
public enum SyncOutboxStore {
    private struct MemoState: Codable {
        var revision: Int64
        var contentHash: String?
        var deleted: Bool
    }

    private struct State: Codable {
        var schemaVersion: Int = 1
        var deviceID: String
        var memoStates: [String: MemoState] = [:]
        var operations: [SyncOutboxOperation] = []
    }

    private static let queue = DispatchQueue(label: "com.daypage.sync-outbox")

    public static var outboxURL: URL {
        outboxURL(for: VaultInitializer.vaultURL)
    }

    public static func outboxURL(for vaultRoot: URL) -> URL {
        vaultRoot
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("outbox-v1.json")
    }

    public static func pendingOperations() throws -> [SyncOutboxOperation] {
        try queue.sync {
            try load().operations.sorted {
                if $0.modifiedAt == $1.modifiedAt { return $0.operationID.uuidString < $1.operationID.uuidString }
                return $0.modifiedAt < $1.modifiedAt
            }
        }
    }

    public static func pendingOperation(for memoID: UUID) throws -> SyncOutboxOperation? {
        try queue.sync {
            try load().operations.first { $0.memoID == memoID }
        }
    }

    public static func deviceID() throws -> String {
        try queue.sync { try load().deviceID }
    }

    /// Records the canonical revision received from the server without
    /// generating another outbound operation. `RawStorage` calls this only
    /// after the corresponding remote mutation has committed to the Vault.
    public static func acceptRemoteChange(
        memo: Memo?,
        memoID: UUID,
        remoteRevision: Int64,
        deleted: Bool
    ) throws {
        try queue.sync {
            var state = try load()
            let memoKey = key(memoID)
            state.memoStates[memoKey] = MemoState(
                revision: max(0, remoteRevision),
                contentHash: memo.map { Self.contentHash($0) },
                deleted: deleted
            )
            state.operations.removeAll { $0.memoID == memoID }
            try save(state)
        }
    }

    public static func contentHash(for memo: Memo) -> String {
        contentHash(memo)
    }

    public static func recordUpsert(
        _ memo: Memo,
        vaultPath: String,
        modifiedAt: Date = Date()
    ) throws {
        try recordUpsert(
            memo,
            vaultPath: vaultPath,
            vaultRoot: VaultInitializer.vaultURL,
            modifiedAt: modifiedAt
        )
    }

    public static func recordUpsert(
        _ memo: Memo,
        vaultPath: String,
        vaultRoot: URL,
        modifiedAt: Date = Date()
    ) throws {
        try queue.sync {
            let url = outboxURL(for: vaultRoot)
            var state = try load(from: url)
            recordUpsert(memo, vaultPath: vaultPath, modifiedAt: modifiedAt, state: &state)
            try save(state, to: url)
        }
    }

    public static func recordChanges(
        before: [Memo],
        after: [Memo],
        vaultPath: String,
        modifiedAt: Date = Date()
    ) throws {
        try recordChanges(
            before: before,
            after: after,
            vaultPath: vaultPath,
            vaultRoot: VaultInitializer.vaultURL,
            modifiedAt: modifiedAt
        )
    }

    public static func recordChanges(
        before: [Memo],
        after: [Memo],
        vaultPath: String,
        vaultRoot: URL,
        modifiedAt: Date = Date()
    ) throws {
        try queue.sync {
            let url = outboxURL(for: vaultRoot)
            var state = try load(from: url)
            let afterIDs = Set(after.map(\.id))
            for memo in after {
                recordUpsert(memo, vaultPath: vaultPath, modifiedAt: modifiedAt, state: &state)
            }
            for memo in before where !afterIDs.contains(memo.id) {
                recordDelete(memoID: memo.id, modifiedAt: modifiedAt, state: &state)
            }
            try save(state, to: url)
        }
    }

    public static func acknowledge(operationID: UUID) throws {
        try queue.sync {
            var state = try load()
            guard state.operations.contains(where: { $0.operationID == operationID }) else {
                throw SyncOutboxError.acknowledgementMismatch
            }
            state.operations.removeAll { $0.operationID == operationID }
            try save(state)
        }
    }

    /// Repairs an interrupted Vault/outbox double-write without delaying first
    /// paint. Callers run this on a background task after the Vault is ready.
    public static func reconcileVault(modifiedAt: Date = Date()) throws {
        try queue.sync {
            var state = try load()
            let rawDirectory = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
            let files = try FileManager.default.contentsOfDirectory(
                at: rawDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            var currentIDs = Set<String>()
            for file in files where file.pathExtension == "md" {
                let content = try String(contentsOf: file, encoding: .utf8)
                for memo in RawStorage.parse(fileContent: content, sourceFile: file) {
                    currentIDs.insert(key(memo.id))
                    recordUpsert(
                        memo,
                        vaultPath: "raw/\(file.lastPathComponent)",
                        modifiedAt: modifiedAt,
                        state: &state
                    )
                }
            }
            let deletedIDs = state.memoStates.compactMap { id, value in
                value.deleted || currentIDs.contains(id) ? nil : UUID(uuidString: id)
            }
            for memoID in deletedIDs {
                recordDelete(memoID: memoID, modifiedAt: modifiedAt, state: &state)
            }
            try save(state)
        }
    }

    private static func recordUpsert(
        _ memo: Memo,
        vaultPath: String,
        modifiedAt: Date,
        state: inout State
    ) {
        let memoKey = key(memo.id)
        let markdown = memo.toMarkdown()
        let hash = contentHash(memo)
        let previous = state.memoStates[memoKey]
        if previous?.contentHash == hash, previous?.deleted == false { return }

        let revision = (previous?.revision ?? 0) + 1
        let payload = SyncMemoPayload(
            type: MemoSyncMapper.webType(for: memo.type),
            body: MemoSyncMapper.nonEmptyBody(for: memo),
            createdAt: memo.created,
            pinnedAt: memo.pinnedAt,
            location: memo.location.map { .init(name: $0.name, lat: $0.lat, lng: $0.lng) },
            weather: memo.weather.flatMap { $0.isEmpty ? nil : .init(condition: $0) },
            device: memo.device.flatMap { $0.isEmpty ? nil : $0 },
            source: {
                #if os(macOS)
                return "macos"
                #else
                return "ios"
                #endif
            }(),
            vaultPath: vaultPath
        )
        let operation = SyncOutboxOperation(
            operationID: UUID(),
            memoID: memo.id,
            kind: .upsert,
            revision: revision,
            modifiedAt: modifiedAt,
            contentHash: hash,
            deviceID: state.deviceID,
            payload: payload,
            sizeBytes: markdown.utf8.count
        )
        state.memoStates[memoKey] = MemoState(revision: revision, contentHash: hash, deleted: false)
        state.operations.removeAll { $0.memoID == memo.id }
        state.operations.append(operation)
    }

    private static func recordDelete(memoID: UUID, modifiedAt: Date, state: inout State) {
        let memoKey = key(memoID)
        let previous = state.memoStates[memoKey]
        if previous?.deleted == true { return }
        let revision = (previous?.revision ?? 0) + 1
        state.memoStates[memoKey] = MemoState(revision: revision, contentHash: nil, deleted: true)
        state.operations.removeAll { $0.memoID == memoID }
        state.operations.append(SyncOutboxOperation(
            operationID: UUID(),
            memoID: memoID,
            kind: .delete,
            revision: revision,
            modifiedAt: modifiedAt,
            contentHash: nil,
            deviceID: state.deviceID,
            payload: nil,
            sizeBytes: 0
        ))
    }

    private static func load(from url: URL? = nil) throws -> State {
        let url = url ?? outboxURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return State(deviceID: UUID().uuidString.lowercased())
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(State.self, from: data)
        guard state.schemaVersion == 1, UUID(uuidString: state.deviceID) != nil else {
            throw SyncOutboxError.invalidState
        }
        return state
    }

    private static func save(_ state: State, to url: URL? = nil) throws {
        let url = url ?? outboxURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: [.atomic])
    }

    private static func key(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func contentHash(_ memo: Memo) -> String {
        SHA256.hash(data: Data(memo.toMarkdown().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
