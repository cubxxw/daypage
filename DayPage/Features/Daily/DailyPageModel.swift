import SwiftUI
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - DailyPageTab

enum DailyPageTab: String, CaseIterable {
    case digest = "DIGEST"
    case timeline = "TIMELINE"

    static func initial(arguments: [String]) -> DailyPageTab {
        #if DEBUG
        guard let flagIndex = arguments.firstIndex(of: "-qaDailyTab"),
              arguments.indices.contains(flagIndex + 1),
              arguments[flagIndex + 1].lowercased() == "timeline" else {
            return .digest
        }
        return .timeline
        #else
        return .digest
        #endif
    }
}

// MARK: - DailyPageModel

/// Daily Page Markdown 文件的解析模型。
struct DailyPageModel {
    let dateString: String
    let weekday: String
    let summary: String
    let locationPrimary: String
    let entriesCount: Int
    let rawContent: String        // Full file content
    let sections: [PageSection]
    let locations: [LocationEntry]
    let followUpQuestions: [String]
    let memoCount: Int
    /// Vault 相对路径，指向封面主图（例如 "raw/assets/photo_...jpg"）。
    /// 当日无照片时返回 nil。
    let coverAssetPath: String?
    /// Color-coded narrative threads. Falls back to stub when compile output lacks them.
    let threads: [ThreadEntry]
    /// Entity mention chips. Falls back to stub when compile output lacks them.
    let mentions: [String]

    struct PageSection {
        let title: String
        let body: String
        /// Issue #4 · 证据链:
        /// UUIDs of the raw memos whose content contributed to `body`, as
        /// parsed from `[^m:<uuid>]` footnote markers emitted by
        /// CompilationService. The view renders these as "引用 N 条" chips
        /// that tap through to MemoDetailView. Empty for older daily.md
        /// files compiled before Issue #4 rolled out (graceful degradation).
        let evidenceMemoIDs: [UUID]

        init(title: String, body: String, evidenceMemoIDs: [UUID] = []) {
            self.title = title
            self.body = body
            self.evidenceMemoIDs = evidenceMemoIDs
        }
    }

    struct LocationEntry {
        let time: String
        let name: String
        let note: String
    }

    /// A narrative thread with an optional color label.
    struct ThreadEntry {
        let label: String
        let color: Color
    }
}

// MARK: - FlowLayout

/// SwiftUI Layout that wraps subviews to new lines when the line width is exceeded.
struct FlowLayout: Layout {

    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += lineHeight + spacing
                totalHeight = y
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.maxX
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > bounds.minX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
