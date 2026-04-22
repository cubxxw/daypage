import SwiftUI

// MARK: - RecordingOverlayMode

/// Visual state of the press-to-talk overlay. Mirrors the three gesture states
/// produced by PressToTalkButton (US-008).
enum RecordingOverlayMode: Equatable {
    /// Holding in place — default waveform + timer.
    case recording
    /// Drag up crossed the cancel threshold — discard on release.
    case cancelArmed
    /// Drag left crossed the transcribe threshold — fill text on release.
    case transcribeArmed
    /// Whisper call is running after a transcribe-armed release.
    case transcribing
}

// MARK: - RecordingOverlayView
//
// Floating card shown above the input bar while the user is holding the
// press-to-talk button. Three primary visual states plus a post-release
// transcribing spinner. Visuals are driven entirely by the `mode`, `elapsed`
// and `waveform` inputs — no internal state.

struct RecordingOverlayView: View {

    let mode: RecordingOverlayMode
    let elapsedSeconds: Int
    let waveform: [Float]

    var body: some View {
        VStack(spacing: 10) {
            statusLine
            waveformBar
            timerLine
            if mode == .recording {
                gestureHintRow
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(backgroundFill)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(borderColor, lineWidth: 1)
        )
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Status Line

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(foregroundColor)
            Text(statusText)
                .font(.custom("Inter-Medium", size: 13))
                .foregroundColor(foregroundColor)
            Spacer()
        }
    }

    // MARK: - Waveform Bar

    @ViewBuilder
    private var waveformBar: some View {
        let barCount = min(40, waveform.count)
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< barCount, id: \.self) { i in
                let level = waveform[i]
                RoundedRectangle(cornerRadius: 1)
                    .fill(waveformColor)
                    .frame(width: 3, height: max(4, CGFloat(level) * 28))
                    .animation(.easeOut(duration: 0.05), value: level)
            }
        }
        .frame(height: 32)
    }

    // MARK: - Timer Line

    @ViewBuilder
    private var timerLine: some View {
        HStack(spacing: 0) {
            Text(formattedTime(elapsedSeconds))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(foregroundColor)
                .monospacedDigit()
            Spacer()
            if mode == .transcribing {
                ProgressView()
                    .tint(foregroundColor)
            }
        }
    }

    // MARK: - Style Helpers

    private var statusIcon: String {
        switch mode {
        case .recording: return "mic.fill"
        case .cancelArmed: return "trash.fill"
        case .transcribeArmed: return "text.bubble.fill"
        case .transcribing: return "waveform"
        }
    }

    private var statusText: String {
        switch mode {
        case .recording: return "松手发送 · ↑ 取消 · ← 转文字"
        case .cancelArmed: return "↑ 松手取消"
        case .transcribeArmed: return "← 松手转文字"
        case .transcribing: return "正在转写…"
        }
    }

    private var backgroundFill: Color {
        switch mode {
        case .recording: return DSColor.surface
        case .cancelArmed: return DSColor.errorContainer
        case .transcribeArmed: return Color(red: 0.85, green: 0.92, blue: 1.0)
        case .transcribing: return DSColor.surface
        }
    }

    private var borderColor: Color {
        switch mode {
        case .recording: return DSColor.outlineVariant
        case .cancelArmed: return DSColor.error
        case .transcribeArmed: return Color(red: 0.20, green: 0.45, blue: 0.85)
        case .transcribing: return DSColor.outlineVariant
        }
    }

    private var foregroundColor: Color {
        switch mode {
        case .recording: return DSColor.onSurface
        case .cancelArmed: return DSColor.error
        case .transcribeArmed: return Color(red: 0.12, green: 0.30, blue: 0.65)
        case .transcribing: return DSColor.onSurface
        }
    }

    private var waveformColor: Color {
        switch mode {
        case .recording: return DSColor.amberArchival
        case .cancelArmed: return DSColor.error
        case .transcribeArmed: return Color(red: 0.20, green: 0.45, blue: 0.85)
        case .transcribing: return DSColor.onSurfaceVariant
        }
    }

    // MARK: - Gesture Hint Row
    //
    // Shown only in .recording state so users discover the swipe affordances
    // the first time they hold the button. Two small pills indicating the
    // cancel (↑) and transcribe (←) zones help users understand what to do
    // before they commit to a direction.

    @ViewBuilder
    private var gestureHintRow: some View {
        HStack(spacing: 12) {
            Spacer()
            gestureHintPill(icon: "arrow.up", label: "上滑取消", color: DSColor.error.opacity(0.75))
            gestureHintPill(icon: "arrow.left", label: "左滑转文字", color: Color(red: 0.20, green: 0.45, blue: 0.85).opacity(0.75))
            Spacer()
        }
    }

    @ViewBuilder
    private func gestureHintPill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.custom("Inter-Regular", size: 11))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
    }

    // MARK: - Helpers

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
