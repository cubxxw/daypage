import SwiftUI

// MARK: - AppTab

enum AppTab: Equatable {
    case today
    case archive
    case feedback
    case graph
}

// MARK: - AppNavigationModel

@MainActor
final class AppNavigationModel: ObservableObject {

    @Published var selectedTab: AppTab = .today
    @Published var isSidebarOpen: Bool = false
    @Published var isFeedbackPanelOpen: Bool = false

    init() {}

    /// Binding<AppSection> bridging GlassTabBar ↔ selectedTab.
    var sectionBinding: Binding<AppSection> {
        Binding(
            get: {
                switch self.selectedTab {
                case .today:    return .today
                case .archive:  return .archive
                case .graph:    return .graph
                case .feedback: return .today
                }
            },
            set: { section in
                switch section {
                case .today:   self.navigate(to: .today)
                case .archive: self.navigate(to: .archive)
                case .graph:   self.navigate(to: .graph)
#if DEBUG
                case .search:  break
#endif
                }
            }
        )
    }

    func openSidebar() {
        withAnimation(Motion.slide) {
            isSidebarOpen = true
        }
    }

    func closeSidebar() {
        withAnimation(Motion.slide) {
            isSidebarOpen = false
        }
    }

    func navigate(to tab: AppTab) {
        selectedTab = tab
        closeSidebar()
    }

    func openFeedbackPanel() {
        closeSidebar()
        withAnimation(Motion.slide) {
            isFeedbackPanelOpen = true
        }
    }

    func closeFeedbackPanel() {
        withAnimation(Motion.slide) {
            isFeedbackPanelOpen = false
        }
    }
}
