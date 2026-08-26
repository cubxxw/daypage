import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices

struct MemoEcho: Identifiable, Equatable, Sendable {
    let id: UUID
    let dateString: String
    let snippet: String
}

struct MemoDetailDerivedData: Equatable, Sendable {
    var entityDisplayNames: [String: String] = [:]
    var photoMetadataByFile: [String: PhotoMetadata] = [:]
    var echoes: [MemoEcho] = []

    static let empty = MemoDetailDerivedData()
}

/// Builds every non-authoritative detail decoration once per memo revision.
/// Echoes reuse SearchIndex's disposable read model instead of reopening every
/// raw Markdown file on each navigation.  Photo headers are parsed once and
/// shared by the image overlay and metadata footer.
enum MemoDetailDerivedDataLoader {

    static func load(for memo: Memo) async -> MemoDetailDerivedData {
        async let names = resolveDisplayNames(for: memo.entityMentions)
        async let metadata = loadPhotoMetadata(for: memo.attachments)
        async let echoes = findEchoes(for: memo)
        return await MemoDetailDerivedData(
            entityDisplayNames: names,
            photoMetadataByFile: metadata,
            echoes: echoes
        )
    }

    static func entityType(for slug: String) -> String {
        let safeSlug = EntityPageService.sanitizeSlug(slug)
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")
        for type in ["places", "people", "themes"] {
            let url = wikiBase.appendingPathComponent(type).appendingPathComponent("\(safeSlug).md")
            if FileManager.default.fileExists(atPath: url.path) { return type }
        }
        return "themes"
    }

    private static func resolveDisplayNames(for slugs: [String]) async -> [String: String] {
        guard !Task.isCancelled else { return [:] }
        var result: [String: String] = [:]
        let wikiBase = VaultInitializer.vaultURL.appendingPathComponent("wiki")

        for slug in Set(slugs).filter({ !$0.isEmpty }) {
            guard !Task.isCancelled else { return result }
            let safeSlug = EntityPageService.sanitizeSlug(slug)
            for type in ["places", "people", "themes"] {
                let url = wikiBase.appendingPathComponent(type).appendingPathComponent("\(safeSlug).md")
                guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if let name = frontmatterName(in: content) {
                    result[slug] = name
                    break
                }
            }
        }
        return result
    }

    private static func loadPhotoMetadata(
        for attachments: [Memo.Attachment]
    ) async -> [String: PhotoMetadata] {
        var result: [String: PhotoMetadata] = [:]
        for attachment in attachments where attachment.kind == "photo" {
            guard !Task.isCancelled,
                  let relativePath = attachment.presentationFile else { continue }
            let url = VaultInitializer.vaultURL.appendingPathComponent(relativePath)
            if let metadata = await PhotoMetadataService.metadata(at: url) {
                result[attachment.file] = metadata
            }
        }
        return result
    }

    private static func findEchoes(for memo: Memo) async -> [MemoEcho] {
        let slugs = Set(memo.entityMentions.filter { !$0.isEmpty })
        guard !slugs.isEmpty, !Task.isCancelled else { return [] }

        let ownDate = DateFormatters.isoDate.string(from: memo.created)
        let documents = await SearchIndex.shared.documents()
        guard !Task.isCancelled else { return [] }

        struct Candidate {
            let memoID: UUID
            let dateString: String
            let snippet: String
            let sharedCount: Int
        }

        var bestByDay: [String: Candidate] = [:]
        for day in documents where day.dateString != ownDate {
            for document in day.memos where document.id != memo.id {
                let sharedCount = slugs.intersection(document.entityMentions).count
                guard sharedCount > 0 else { continue }
                let snippet = document.body
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                guard !snippet.isEmpty else { continue }
                let candidate = Candidate(
                    memoID: document.id,
                    dateString: day.dateString,
                    snippet: String(snippet.prefix(72)),
                    sharedCount: sharedCount
                )
                if (bestByDay[day.dateString]?.sharedCount ?? -1) < sharedCount {
                    bestByDay[day.dateString] = candidate
                }
            }
        }

        return bestByDay.values
            .sorted { ($0.sharedCount, $0.dateString) > ($1.sharedCount, $1.dateString) }
            .prefix(3)
            .map { MemoEcho(id: $0.memoID, dateString: $0.dateString, snippet: $0.snippet) }
    }

    private static func frontmatterName(in content: String) -> String? {
        for line in content.components(separatedBy: "\n").prefix(12) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name:") else { continue }
            let value = trimmed.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
