import Foundation
import DayPageModels

public enum MemoRecordStoreError: LocalizedError, Equatable, Sendable {
    case notFound(UUID)
    case emptyBody

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "The memo is no longer available."
        case .emptyBody:
            return "A memo body cannot be empty."
        }
    }
}

/// Stable ID-based read and mutation boundary for memo detail surfaces.
///
/// Navigation carries only `(memoID, day)`.  The destination resolves the
/// current record here rather than depending on whichever mutable list happened
/// to build the route.  Mutations use `RawStorage.mutate`, keeping the read,
/// transform, write, outbox update, and cache notification in one serialized
/// critical section.
public actor MemoRecordStore {
    public static let shared = MemoRecordStore()

    public init() {}

    public func memo(id: UUID, day: Date) throws -> Memo {
        guard let memo = try RawStorage.read(for: day).first(where: { $0.id == id }) else {
            throw MemoRecordStoreError.notFound(id)
        }
        return memo
    }

    @discardableResult
    public func updateBody(id: UUID, day: Date, body: String) throws -> Memo {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoRecordStoreError.emptyBody }

        var result: Memo?
        try RawStorage.mutate(for: day) { memos in
            guard let index = memos.firstIndex(where: { $0.id == id }) else { return nil }
            var updated = memos
            updated[index].body = body
            result = updated[index]
            return updated
        }
        guard let result else { throw MemoRecordStoreError.notFound(id) }
        return result
    }

    public func delete(id: UUID, day: Date) throws {
        var found = false
        try RawStorage.mutate(for: day) { memos in
            guard memos.contains(where: { $0.id == id }) else { return nil }
            found = true
            return memos.filter { $0.id != id }
        }
        guard found else { throw MemoRecordStoreError.notFound(id) }
    }

    /// Restores a previously deleted record without duplicating an ID that may
    /// already have been recreated by sync. The raw file keeps chronological
    /// order so every existing read surface receives the same stable sequence.
    public func restore(_ memo: Memo, day: Date) throws {
        try RawStorage.mutate(for: day) { memos in
            guard !memos.contains(where: { $0.id == memo.id }) else { return nil }
            return (memos + [memo]).sorted { $0.created < $1.created }
        }
    }
}
