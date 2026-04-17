import SwiftUI

// MARK: - CompileFooterButton

/// Sticky compile entry mounted above `InputBarView`.
/// Visibility is owned by the parent (`TodayView`) via `isVisible`; this view only
/// animates in/out and morphs between `.idle` and `.compiling` states.
///
/// Design: capsule, 1pt outline, semi-transparent surface, sparkle icon + label.
/// US-005 replaces the inline `CompilePromptCard` entry in the timeline.
struct CompileFooterButton: View {

    /// Number of raw memos captured today.
    let memoCount: Int
    /// Whether a compile pass is currently running.
    let isCompiling: Bool
    /// Whether the button should be rendered. When `false`, the view collapses
    /// to zero size with a spring fade-out.
    let isVisible: Bool
    /// Tapped when the user wants to compile now. Ignored while compiling.
    let onTap: () -> Void

    var body: some View {
        Group {
            if isVisible {
                buttonBody
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isCompiling)
    }

    // MARK: Content

    private var buttonBody: some View {
        Button(action: {
            guard !isCompiling else { return }
            onTap()
        }) {
            HStack(spacing: 8) {
                if isCompiling {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(DSColor.onSurface)
                    Text("正在编译 \(memoCount) 条 memo")
                        .font(.custom("Inter-Medium", size: 13))
                        .foregroundColor(DSColor.onSurface)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DSColor.onSurface)
                    Text("编译今日 · \(memoCount) 条")
                        .font(.custom("Inter-Medium", size: 13))
                        .foregroundColor(DSColor.onSurface)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColor.surface.opacity(0.85))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DSColor.outlineVariant, lineWidth: 1)
            )
            .surfaceElevatedShadow()
        }
        .buttonStyle(.plain)
        .disabled(isCompiling)
        .padding(.bottom, 6)
    }
}

// MARK: - ScrollOffsetPreferenceKey

/// Carries the minY of the bottom anchor in the ScrollView's local coordinate space.
/// Parent compares against the ScrollView's visible height + slack to decide whether
/// the compile footer should be shown.
///
/// The anchor is placed at the end of the ScrollView's content; when the user scrolls
/// near the bottom, `minY` approaches the ScrollView's visible height.
struct CompileFooterAnchorPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// MARK: - Helper view for placing the anchor

/// Zero-height anchor to be inserted at the bottom of ScrollView content.
/// Emits `CompileFooterAnchorPreferenceKey` with its minY in the ScrollView's
/// coordinate space (`named: "todayScroll"`).
struct CompileFooterAnchor: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CompileFooterAnchorPreferenceKey.self,
                value: geo.frame(in: .named("todayScroll")).minY
            )
        }
        .frame(height: 1)
    }
}
