import SwiftUI
import UIKit

// MARK: - PressableCardModifier

/// 对任何卡片视图应用按压缩放 + 暗色叠加及触觉反馈。
///
/// Fix (issue #150): replaced `DragGesture(minimumDistance: 0)` with
/// `LongPressGesture(minimumDuration: 0.05)`. The old DragGesture with
/// minimumDistance 0 fired on every touch before any swipe recognizer could
/// determine gesture intent, causing UIKit's gesture engine to negotiate between
/// two competing DragGestures on every frame (hit-testing thrash → dropped
/// frames in SwipeableMemoCard). LongPressGesture does not intercept horizontal
/// swipes, so SwipeableMemoCard's highPriorityGesture gets clean 1:1 tracking.
struct PressableCardModifier: ViewModifier {
    @State private var isPressed: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .overlay(
                Color.black.opacity(isPressed ? 0.04 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: DSSpacing.radiusCard, style: .continuous))
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPressed)
            .simultaneousGesture(
                // LongPressGesture with a short minimum duration delivers the same
                // press visual/haptic feedback without conflicting with horizontal
                // DragGestures on parent or sibling views.
                LongPressGesture(minimumDuration: 0.05)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                    }
            )
    }
}

extension View {
    func pressableCard() -> some View {
        modifier(PressableCardModifier())
    }
}
