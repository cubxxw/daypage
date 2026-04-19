import SwiftUI

// MARK: - SwipeableMemoCard

/// WeChat-style swipe-to-reveal wrapper around MemoCardView.
/// Left swipe → trailing Delete button. Right swipe → leading Pin button.
struct SwipeableMemoCard: View {

    let memo: Memo
    var onDelete: (() -> Void)? = nil
    var onPin: (() -> Void)? = nil

    // Settled offset after a gesture ends (negative = trailing open, positive = leading open)
    @State private var settledOffset: CGFloat = 0
    // Which panel is currently revealed
    @State private var revealedSide: Side? = nil

    // Live delta from DragGesture (resets to zero when finger lifts)
    @GestureState private var dragDelta: CGFloat = 0

    private enum Side { case leading, trailing }

    // Panel widths and thresholds
    private let panelW: CGFloat     = 80
    private let openThreshold: CGFloat = 44
    private let closeThreshold: CGFloat = 20

    // Combined offset while dragging
    private var currentOffset: CGFloat {
        let raw = settledOffset + dragDelta
        return max(-panelW, min(panelW, raw))
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Background action panels
            HStack(spacing: 0) {
                pinPanel
                Spacer()
                deletePanel
            }

            // Card — highPriorityGesture wins over PressableCardModifier's
            // simultaneousGesture(DragGesture(minimumDistance:0)) inside MemoCardView.
            MemoCardView(memo: memo, onDelete: onDelete)
                .offset(x: currentOffset)
                .highPriorityGesture(swipeGesture)
                .onTapGesture { if revealedSide != nil { snapClose() } }
        }
        .clipped()
    }

    // MARK: - Panels

    private var pinPanel: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            snapClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onPin?() }
        }) {
            VStack(spacing: 4) {
                Image(systemName: "pin.fill").font(.system(size: 16, weight: .semibold))
                Text("置顶").font(.custom("Inter-Medium", size: 11))
            }
            .foregroundColor(.white)
            .frame(width: panelW)
            .frame(maxHeight: .infinity)
            .background(DSColor.amberArchival)
        }
        .opacity(revealedSide == .leading ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: revealedSide)
    }

    private var deletePanel: some View {
        Button(action: {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            snapClose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onDelete?() }
        }) {
            VStack(spacing: 4) {
                Image(systemName: "trash.fill").font(.system(size: 16, weight: .semibold))
                Text("删除").font(.custom("Inter-Medium", size: 11))
            }
            .foregroundColor(.white)
            .frame(width: panelW)
            .frame(maxHeight: .infinity)
            .background(DSColor.error)
        }
        .opacity(revealedSide == .trailing ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: revealedSide)
    }

    // MARK: - Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .updating($dragDelta) { value, state, _ in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 0.6 else { return }
                state = dx
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > abs(dy) * 0.6 else {
                    snapToSettled()
                    return
                }
                let vel = value.predictedEndTranslation.width - value.translation.width
                decideSnap(dx: dx, velocity: vel)
            }
    }

    // MARK: - Snap Logic

    private func decideSnap(dx: CGFloat, velocity: CGFloat) {
        if settledOffset == 0 {
            if dx < -openThreshold || velocity < -300 {
                snapOpen(.trailing)
            } else if dx > openThreshold || velocity > 300 {
                snapOpen(.leading)
            } else {
                snapClose()
            }
        } else if settledOffset < 0 {
            // Trailing was open
            (dx > closeThreshold || velocity > 200) ? snapClose() : snapOpen(.trailing)
        } else {
            // Leading was open
            (dx < -closeThreshold || velocity < -200) ? snapClose() : snapOpen(.leading)
        }
    }

    private func snapOpen(_ side: Side) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            revealedSide = side
            settledOffset = side == .trailing ? -panelW : panelW
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func snapClose() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            revealedSide = nil
            settledOffset = 0
        }
    }

    private func snapToSettled() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
            // dragDelta auto-resets; just keep settledOffset
        }
    }
}
