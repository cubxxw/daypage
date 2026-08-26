import Foundation
import DayPageStorage

/// Lightweight metadata snapshot for the raw Markdown truth source.
///
/// A directory's own modification date changes when children are added or
/// removed, but not reliably when an existing child is edited. Comparing the
/// per-file size and modification date therefore catches iCloud/Obsidian edits
/// without reopening or parsing every Markdown document.
struct RawVaultFileSnapshot: Equatable, Sendable {

    struct Signature: Equatable, Sendable {
        let byteCount: Int
        let modifiedAt: Date
    }

    private(set) var files: [String: Signature]

    static func capture(root: URL = VaultInitializer.vaultURL) -> Self {
        let rawDirectory = root.appendingPathComponent("raw", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rawDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return Self(files: [:])
        }

        var signatures: [String: Signature] = [:]
        signatures.reserveCapacity(urls.count)
        for url in urls where url.pathExtension.lowercased() == "md" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let signature = signature(for: url, keys: keys) else { continue }
            signatures[stem] = signature
        }
        return Self(files: signatures)
    }

    static func signature(
        forDateString dateString: String,
        root: URL = VaultInitializer.vaultURL
    ) -> Signature? {
        let url = root
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("\(dateString).md")
        return signature(
            for: url,
            keys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        )
    }

    mutating func update(dateString: String, signature: Signature?) {
        if let signature {
            files[dateString] = signature
        } else {
            files.removeValue(forKey: dateString)
        }
    }

    private static func signature(
        for url: URL,
        keys: Set<URLResourceKey>
    ) -> Signature? {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let byteCount = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            return nil
        }
        return Signature(byteCount: byteCount, modifiedAt: modifiedAt)
    }
}
