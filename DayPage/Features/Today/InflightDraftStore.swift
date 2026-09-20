import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - InflightDraft

/// On-disk record of a memo whose submission is not yet confirmed. New
/// records share their ID with the memo; the four existing JSON fields remain
/// read-compatible with older builds. Persisted before accepting a submit and
/// retained until that memo is durable or the user explicitly discards it.
/// Protects against:
///
///   • App killed (OS memory pressure / user force-quit) during the await
///     chain (location → weather → append).
///   • The submit Task being explicitly cancelled mid-flight.
///   • Any throwing path that exits before append completes.
///
/// Without this record, the composer's `draftText = ""` (which runs
/// synchronously the moment the user taps Send) would silently lose the
/// user's body text.
struct InflightDraft: Equatable, Codable, Sendable {
    var id: UUID
    /// User-typed body text. The thing we cannot afford to lose.
    var body: String
    /// Original memo timestamp (legacy records contain the time Send was tapped).
    /// Recovery retains this date and uses it to sort pending records.
    var enqueuedAt: Date
    /// Vault-relative paths of attachments staged before this submit
    /// (e.g. "raw/assets/voice_…m4a", "raw/assets/IMG_…jpg"). Recovery
    /// uses these to flag attachments that may already be referenced by
    /// an inflight memo for orphan-scan exclusion.
    var attachmentPaths: [String]
}

/// A recovery record stays bound to the Vault in which it was written, even
/// if the active locator changes while its memo is being saved.
struct InflightDraftEntry: Equatable, Identifiable, Sendable {
    let draft: InflightDraft
    let url: URL
    let vaultRoot: URL
    var id: URL { url }
}

enum InflightDraftRecoveryError: LocalizedError {
    case conflictingMemo
    case invalidAttachment
    case vaultChanged

    var errorDescription: String? {
        switch self {
        case .conflictingMemo:
            return NSLocalizedString("today.recovery.conflict", comment: "Recovery retained because the memo already has different content")
        case .invalidAttachment:
            return NSLocalizedString("today.recovery.invalid_attachment", comment: "Recovery retained because an attachment path is invalid")
        case .vaultChanged:
            return NSLocalizedString("today.recovery.vault_changed", comment: "Recovery retained because its vault is no longer active")
        }
    }
}

// MARK: - InflightDraftStore

/// Inflight-draft persistence under `vault/raw/.inflight/{uuid}.json`.
///
/// `persist` creates or updates one stable record before the composer clears.
/// `acknowledge` removes only the matching saved payload. On launch, all
/// remaining records are offered for explicit restoration without replacing
/// an occupied composer. Journal I/O failure rejects the submit so the current
/// composer remains available. `enqueue` is a compatibility helper for callers
/// that need its older optional-URL API.
enum InflightDraftStore {
    private static let journalLock = NSLock()

    // MARK: - URL helpers

    /// `vault/raw/.inflight/` — sibling of `.broken/` so both
    /// safety-net directories live under the same vault root.
    static var directory: URL { directory(vaultRoot: VaultInitializer.vaultURL) }

    static func directory(vaultRoot: URL) -> URL {
        vaultRoot
            .appendingPathComponent("raw")
            .appendingPathComponent(".inflight", isDirectory: true)
    }

    static func fileURL(for id: UUID, vaultRoot: URL) -> URL {
        directory(vaultRoot: vaultRoot).appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Enqueue / Dequeue

    /// Persists the draft. Returns the URL the caller should pass to
    /// `dequeue` once `RawStorage.append` succeeds. Returns `nil` on I/O
    /// failure. Production submission uses throwing `persist` so it can retain
    /// the composer if a durable handoff cannot be written.
    @discardableResult
    static func enqueue(
        body: String,
        attachmentPaths: [String],
        id: UUID = UUID(),
        enqueuedAt: Date = Date(),
        vaultRoot: URL = VaultInitializer.vaultURL
    ) -> URL? {
        let draft = InflightDraft(
            id: id,
            body: body,
            enqueuedAt: enqueuedAt,
            attachmentPaths: attachmentPaths
        )
        do {
            return try persist(draft, vaultRoot: vaultRoot).url
        } catch {
            SentryReporter.breadcrumb(
                category: "inflight",
                level: .warning,
                message: "enqueue failed: \(error)"
            )
            return nil
        }
    }

    /// Reuses the same ID on retry. The caller must not clear the composer
    /// unless this durable handoff succeeds.
    static func persist(_ draft: InflightDraft, vaultRoot: URL) throws -> InflightDraftEntry {
        journalLock.lock()
        defer { journalLock.unlock() }
        let url = fileURL(for: draft.id, vaultRoot: vaultRoot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try RawStorage.atomicWrite(data: encoder.encode(draft), to: url)
        return InflightDraftEntry(draft: draft, url: url, vaultRoot: vaultRoot)
    }

    /// Removes the on-disk record after a successful append. Idempotent:
    /// a missing file is treated as success.
    static func dequeue(_ url: URL?) {
        guard let url = url else { return }
        journalLock.lock()
        defer { journalLock.unlock() }
        removeFile(at: url)
    }

    /// A receipt for an older attempt must not delete a newer retry payload
    /// that reused its stable memo ID in another scene.
    static func acknowledge(_ entry: InflightDraftEntry) {
        journalLock.lock()
        defer { journalLock.unlock() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: entry.url),
              let current = try? decoder.decode(InflightDraft.self, from: data),
              current.id == entry.draft.id,
              current.body == entry.draft.body,
              current.attachmentPaths == entry.draft.attachmentPaths else { return }
        removeFile(at: entry.url)
    }

    private static func removeFile(at url: URL) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            SentryReporter.breadcrumb(
                category: "inflight",
                message: "dequeued \(url.lastPathComponent)"
            )
        } catch {
            SentryReporter.breadcrumb(
                category: "inflight",
                level: .warning,
                message: "dequeue failed for \(url.lastPathComponent): \(error)"
            )
        }
    }

    // MARK: - Recovery

    /// Returns every persisted inflight draft, sorted newest first.
    /// Corrupted entries are skipped (and breadcrumbed) rather than
    /// blocking recovery for the healthy ones.
    static func pending(vaultRoot: URL = VaultInitializer.vaultURL) -> [InflightDraft] {
        pendingEntries(vaultRoot: vaultRoot).map(\.draft)
    }

    static func pendingEntries(vaultRoot: URL = VaultInitializer.vaultURL) -> [InflightDraftEntry] {
        journalLock.lock()
        defer { journalLock.unlock() }
        let fm = FileManager.default
        let directory = directory(vaultRoot: vaultRoot)
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        var entriesToRecover: [InflightDraftEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in entries where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let draft = try decoder.decode(InflightDraft.self, from: data)
                guard url.lastPathComponent.lowercased() == "\(draft.id.uuidString.lowercased()).json" else { continue }
                entriesToRecover.append(InflightDraftEntry(draft: draft, url: url, vaultRoot: vaultRoot))
            } catch {
                SentryReporter.breadcrumb(
                    category: "inflight",
                    level: .warning,
                    message: "skip corrupt inflight \(url.lastPathComponent): \(error)"
                )
            }
        }
        return entriesToRecover.sorted { lhs, rhs in
            if lhs.draft.enqueuedAt != rhs.draft.enqueuedAt {
                return lhs.draft.enqueuedAt > rhs.draft.enqueuedAt
            }
            return lhs.draft.id.uuidString < rhs.draft.id.uuidString
        }
    }

    /// New records use the memo ID as their existing `id` field. Exact
    /// content matching makes append-then-crash recovery idempotent without
    /// guessing whether a legacy record's unrelated UUID was already saved.
    static func isCommitted(_ entry: InflightDraftEntry) throws -> Bool {
        guard let memo = try existingMemo(id: entry.draft.id, vaultRoot: entry.vaultRoot) else { return false }
        return matches(memo, body: entry.draft.body, attachmentPaths: entry.draft.attachmentPaths)
    }

    static func validateForRestoration(_ entry: InflightDraftEntry) throws {
        if let existing = try existingMemo(id: entry.draft.id, vaultRoot: entry.vaultRoot),
           !matches(existing, body: entry.draft.body, attachmentPaths: entry.draft.attachmentPaths) {
            throw InflightDraftRecoveryError.conflictingMemo
        }
    }

    static func persistMemo(_ memo: Memo, vaultRoot: URL, isRecovery: Bool) throws {
        guard isRecovery else {
            try RawStorage.append(memo, vaultRoot: vaultRoot)
            return
        }
        if let existing = try existingMemo(id: memo.id, vaultRoot: vaultRoot) {
            guard matches(existing, body: memo.body, attachmentPaths: memo.attachments.map(\.file)) else {
                throw InflightDraftRecoveryError.conflictingMemo
            }
            return
        }
        var conflict = false
        try RawStorage.mutate(for: memo.created, vaultRoot: vaultRoot) { current in
            if let existing = current.first(where: { $0.id == memo.id }) {
                conflict = !matches(existing, body: memo.body, attachmentPaths: memo.attachments.map(\.file))
                return nil
            }
            return current + [memo]
        }
        if conflict { throw InflightDraftRecoveryError.conflictingMemo }
    }

    private static func matches(_ memo: Memo, body: String, attachmentPaths: [String]) -> Bool {
        memo.body == body && memo.attachments.map(\.file) == attachmentPaths
    }

    private static func existingMemo(id: UUID, vaultRoot: URL) throws -> Memo? {
        let raw = vaultRoot.appendingPathComponent("raw", isDirectory: true)
        guard FileManager.default.fileExists(atPath: raw.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: raw, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "md" {
            let content = try String(contentsOf: file, encoding: .utf8)
            guard content.localizedCaseInsensitiveContains(id.uuidString) else { continue }
            if let memo = RawStorage.parse(fileContent: content).first(where: { $0.id == id }) { return memo }
        }
        return nil
    }

    /// Legacy helper retained for isolated store tests. Runtime recovery must
    /// use an exact acknowledgement or the confirmed-discard path instead.
    static func clearAll() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }
}
