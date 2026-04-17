import SwiftUI

// MARK: - Banner Kind

enum BannerKind {
    case progress
    case success
    case error
    case info
}

// MARK: - AppBannerModel

struct AppBannerModel: Identifiable {
    let id = UUID()
    var kind: BannerKind
    var title: String
    var subtitle: String?
    var primaryAction: BannerAction?
    var secondaryAction: BannerAction?
    var autoDismiss: Bool

    init(
        kind: BannerKind,
        title: String,
        subtitle: String? = nil,
        primaryAction: BannerAction? = nil,
        secondaryAction: BannerAction? = nil,
        autoDismiss: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.autoDismiss = autoDismiss
    }
}

struct BannerAction {
    let label: String
    let handler: () -> Void
}

// MARK: - BannerCenter

@MainActor
final class BannerCenter: ObservableObject {
    static let shared = BannerCenter()
    @Published var currentBanner: AppBannerModel?

    private var autoDismissTask: Task<Void, Never>?

    private init() {}

    func show(_ model: AppBannerModel) {
        autoDismissTask?.cancel()
        currentBanner = model
        if model.autoDismiss {
            autoDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    withAnimation { currentBanner = nil }
                }
            }
        }
    }

    func dismiss() {
        autoDismissTask?.cancel()
        withAnimation { currentBanner = nil }
    }
}

// MARK: - AppBanner View

struct AppBanner: View {
    let model: AppBannerModel
    @ObservedObject private var bannerCenter = BannerCenter.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(foregroundColor)
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(foregroundColor.opacity(0.8))
                }
                if model.primaryAction != nil || model.secondaryAction != nil {
                    HStack(spacing: 16) {
                        if let action = model.primaryAction {
                            Button(action.label, action: action.handler)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(accentColor)
                        }
                        if let action = model.secondaryAction {
                            Button(action.label, action: action.handler)
                                .font(.system(size: 13))
                                .foregroundColor(foregroundColor.opacity(0.7))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            Spacer()
            Button {
                bannerCenter.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(foregroundColor.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(backgroundColor)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
        .cornerRadius(12)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch model.kind {
        case .progress:
            ProgressView()
                .tint(accentColor)
                .frame(width: 20, height: 20)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(accentColor)
        }
    }

    private var backgroundColor: Color {
        switch model.kind {
        case .progress: return Color(hex: "F8ECD6")
        case .success: return Color(hex: "EBF3E5")
        case .error:   return Color(hex: "F5E1DC")
        case .info:    return Color(hex: "F3F0EB")
        }
    }

    private var foregroundColor: Color {
        switch model.kind {
        case .progress: return Color(hex: "2B2822")
        case .success:  return Color(hex: "2B2822")
        case .error:    return Color(hex: "2B2822")
        case .info:     return Color(hex: "2B2822")
        }
    }

    private var accentColor: Color {
        switch model.kind {
        case .progress: return Color(hex: "A66A00")
        case .success:  return Color(hex: "4C7A3F")
        case .error:    return Color(hex: "A23A2E")
        case .info:     return Color(hex: "6B6560")
        }
    }

    private var borderColor: Color {
        switch model.kind {
        case .progress: return Color(hex: "E8DCCA")
        case .success:  return Color(hex: "C8E0BF")
        case .error:    return Color(hex: "E8C4BC")
        case .info:     return Color(hex: "D6CEC0")
        }
    }
}

// MARK: - BannerOverlay

struct BannerOverlayModifier: ViewModifier {
    @ObservedObject private var bannerCenter = BannerCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let banner = bannerCenter.currentBanner {
                AppBanner(model: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: bannerCenter.currentBanner?.id)
    }
}

extension View {
    func bannerOverlay() -> some View {
        modifier(BannerOverlayModifier())
    }
}
