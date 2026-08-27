import Foundation

/// One item-driven presentation rail for every in-app and system entry point.
/// Draft seeds are deliberately not executable proposals: the review surface
/// must turn them into a validated, durable proposal before approval exists.
enum SystemActionPresentation: Identifiable, Equatable {
    case center(selectedProposalID: UUID?)
    case draft(SystemActionDraftSeed)
    case focus(SystemActionFocusSeed)
    case moment
    case capture

    var id: String {
        switch self {
        case .center(let proposalID): return "center:\(proposalID?.uuidString ?? "all")"
        case .draft(let seed): return "draft:\(seed.id.uuidString)"
        case .focus(let seed): return "focus:\(seed.id.uuidString)"
        case .moment: return "moment"
        case .capture: return "capture"
        }
    }
}

struct SystemActionDraftSeed: Equatable, Identifiable {
    let id = UUID()
    let kind: String
    let title: String
    let notes: String?
}

struct SystemActionFocusSeed: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let durationSeconds: Int
}
