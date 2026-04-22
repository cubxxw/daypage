import Foundation

// MARK: - ConflictResolutionInfo

struct ConflictResolutionInfo {
    let date: Date
    let mergedMemoCount: Int
    let sourceDevice: String
}

extension Notification.Name {
    static let vaultConflictResolved = Notification.Name("vaultConflictResolved")
}

// MARK: - ConflictMerger

/// Merges iCloud conflict copies for raw memo files, wiki log lines, and JSON entries.
/// Conflict detection is driven by NSMetadataQuery watching NSMetadataUbiquitousItemHasUnresolvedConflictsKey.
enum ConflictMerger {

    // MARK: - Memo Merge

    /// Merges two arrays of Memo objects.
    /// Algorithm: concatenate, sort by created ascending, deduplicate by UUID (keep first).
    static func mergeRawMemos(original: [Memo], conflict: [Memo]) -> [Memo] {
        let combined = (original + conflict).sorted { $0.created < $1.created }
        var seen = Set<UUID>()
        return combined.filter { memo in
            guard !seen.contains(memo.id) else { return false }
            seen.insert(memo.id)
            return true
        }
    }

    // MARK: - Log Line Merge

    /// Merges two wiki/log.md strings, deduplicating lines by their timestamp prefix (first token).
    static func mergeLogLines(original: String, conflict: String) -> String {
        let originalLines = original.components(separatedBy: "\n")
        let conflictLines = conflict.components(separatedBy: "\n")
        var seen = Set<String>()
        var merged: [String] = []

        for line in originalLines + conflictLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Use the first whitespace-separated token as the deduplication key (timestamp prefix).
            let key = trimmed.components(separatedBy: .whitespaces).first ?? trimmed
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(line)
        }

        return merged.joined(separator: "\n")
    }

    // MARK: - JSON Entry Merge

    /// Merges two JSON arrays, deduplicating entries by a given idKey field value.
    /// Returns the original data if either input cannot be parsed as a JSON array.
    static func mergeJSONEntries(original: Data, conflict: Data, idKey: String) -> Data {
        guard
            let originalArray = try? JSONSerialization.jsonObject(with: original) as? [[String: Any]],
            let conflictArray = try? JSONSerialization.jsonObject(with: conflict) as? [[String: Any]]
        else {
            return original
        }

        var seen = Set<String>()
        var merged: [[String: Any]] = []

        for entry in originalArray + conflictArray {
            guard let idValue = entry[idKey].flatMap({ "\($0)" }) else {
                merged.append(entry)
                continue
            }
            guard !seen.contains(idValue) else { continue }
            seen.insert(idValue)
            merged.append(entry)
        }

        return (try? JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)) ?? original
    }

    // MARK: - iCloud Conflict Resolution

    /// Scans a vault URL for iCloud conflict copies and resolves them.
    /// Uses NSMetadataQuery to find files with unresolved conflicts, merges content,
    /// and posts .vaultConflictResolved after each successful resolution.
    static func resolveConflictsIfNeeded(in vaultURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vaultURL.path) else { return }

        // Gather all files with unresolved conflicts under vaultURL.
        guard let enumerator = fm.enumerator(at: vaultURL,
                                             includingPropertiesForKeys: [.ubiquitousItemHasUnresolvedConflictsKey],
                                             options: [.skipsHiddenFiles]) else { return }

        var conflictedURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
            if values?.ubiquitousItemHasUnresolvedConflicts == true {
                conflictedURLs.append(fileURL)
            }
        }

        for primaryURL in conflictedURLs {
            resolveConflict(at: primaryURL)
        }
    }

    // MARK: - Private Helpers

    private static func resolveConflict(at primaryURL: URL) {
        guard let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: primaryURL),
              !conflictVersions.isEmpty else { return }

        let ext = primaryURL.pathExtension

        do {
            if ext == "md" {
                try resolveMDConflict(primaryURL: primaryURL, conflictVersions: conflictVersions)
            } else if ext == "json" {
                try resolveJSONConflict(primaryURL: primaryURL, conflictVersions: conflictVersions)
            }

            // Mark all conflict versions as resolved and remove them.
            for version in conflictVersions {
                version.isResolved = true
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: primaryURL)

            let device = conflictVersions.first?.localizedNameOfSavingComputer ?? "unknown"
            let info = ConflictResolutionInfo(date: Date(), mergedMemoCount: conflictVersions.count, sourceDevice: device)
            NotificationCenter.default.post(name: .vaultConflictResolved, object: info)
        } catch {
            // Leave conflict unresolved; system will retry.
        }
    }

    private static func resolveMDConflict(primaryURL: URL, conflictVersions: [NSFileVersion]) throws {
        // Determine whether this is a raw memo file (vault/raw/YYYY-MM-DD.md) or a log file.
        let pathComponents = primaryURL.pathComponents
        let isRaw = pathComponents.contains("raw") && !pathComponents.contains("assets")

        let originalData = try Data(contentsOf: primaryURL)

        if isRaw {
            var original = parseMemos(from: originalData)
            for version in conflictVersions {
                if let conflictData = try? Data(contentsOf: version.url) {
                    let conflictMemos = parseMemos(from: conflictData)
                    original = mergeRawMemos(original: original, conflict: conflictMemos)
                }
            }
            let merged = original.map { $0.toMarkdown() }.joined(separator: "\n\n---\n\n")
            try writeMerged(data: Data(merged.utf8), to: primaryURL)
        } else {
            // Log / wiki file: deduplicate by line timestamp prefix.
            var merged = String(data: originalData, encoding: .utf8) ?? ""
            for version in conflictVersions {
                if let conflictData = try? Data(contentsOf: version.url),
                   let conflictText = String(data: conflictData, encoding: .utf8) {
                    merged = mergeLogLines(original: merged, conflict: conflictText)
                }
            }
            try writeMerged(data: Data(merged.utf8), to: primaryURL)
        }
    }

    private static func resolveJSONConflict(primaryURL: URL, conflictVersions: [NSFileVersion]) throws {
        var original = try Data(contentsOf: primaryURL)
        for version in conflictVersions {
            if let conflictData = try? Data(contentsOf: version.url) {
                original = mergeJSONEntries(original: original, conflict: conflictData, idKey: "id")
            }
        }
        try writeMerged(data: original, to: primaryURL)
    }

    private static func writeMerged(data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let err = coordinatorError ?? writeError { throw err }
    }

    private static func parseMemos(from data: Data) -> [Memo] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: "\n\n---\n\n").compactMap { Memo.fromMarkdown($0) }
    }
}
