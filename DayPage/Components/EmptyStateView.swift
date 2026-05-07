import SwiftUI

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var ctaLabel: String?
    var ctaAction: (() -> Void)?
    var showOrbAccent: Bool = false

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            titleSection
            if let subtitle {
                Text(subtitle)
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            if let label = ctaLabel, let action = ctaAction {
                ctaButton(label: label, action: action)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
                    .animation(Motion.rise.delay(0.12), value: appeared)
            }
        }
        .padding(.horizontal, 32)
        .onAppear { appeared = true }
    }

    // MARK: - Private

    @ViewBuilder
    private var titleSection: some View {
        ZStack {
            if showOrbAccent {
                orbAccent
            }
            Text(title)
                .font(DSType.serifDisplay28)
                .foregroundColor(DSColor.inkPrimary)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 6)
                .animation(Motion.rise, value: appeared)
        }
    }

    private var orbAccent: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(hex: "E8974D").opacity(0.55),
                        Color(hex: "A8541B").opacity(0.28),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 30
                )
            )
            .frame(width: 60, height: 60)
            .blur(radius: 10)
            .allowsHitTesting(false)
    }

    private func ctaButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(DSType.sectionLabel)
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundColor(Color.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(DSColor.amberDeep)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Factory Methods

extension EmptyStateView {
    /// Today tab — no memos yet.
    static func todayBlank(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: "empty.today.blank.title",
            subtitle: "empty.today.blank.subtitle",
            ctaLabel: NSLocalizedString("empty.today.blank.cta", comment: ""),
            ctaAction: ctaAction,
            showOrbAccent: true
        )
    }

    /// Today tab — memos exist but no signal cards generated.
    static func todayNoSignals() -> EmptyStateView {
        EmptyStateView(
            title: "empty.today.no_signals.title",
            subtitle: "empty.today.no_signals.subtitle",
            showOrbAccent: false
        )
    }

    /// Compilation locked — not enough memos.
    static func compileLocked(currentCount: Int) -> EmptyStateView {
        let subtitle = String(
            format: NSLocalizedString("empty.compile_locked.subtitle", comment: ""),
            currentCount
        )
        return EmptyStateView(
            title: "empty.compile_locked.title",
            subtitle: LocalizedStringKey(subtitle),
            showOrbAccent: false
        )
    }

    /// Archive — selected day has no compiled page.
    static func archiveDayEmpty(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: "empty.archive_day.title",
            subtitle: "empty.archive_day.subtitle",
            ctaLabel: NSLocalizedString("empty.archive_day.cta", comment: ""),
            ctaAction: ctaAction,
            showOrbAccent: false
        )
    }

    /// Mic permission denied — recording unavailable.
    static func micPermissionDenied(ctaAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            title: "empty.mic_denied.title",
            subtitle: "empty.mic_denied.subtitle",
            ctaLabel: NSLocalizedString("empty.mic_denied.cta", comment: ""),
            ctaAction: ctaAction,
            showOrbAccent: false
        )
    }
}

// MARK: - Preview

#Preview("Today Blank") {
    ZStack {
        AmbientBackground()
        EmptyStateView.todayBlank { }
    }
}

#Preview("No Signals") {
    ZStack {
        AmbientBackground()
        EmptyStateView.todayNoSignals()
    }
}

#Preview("Compile Locked") {
    ZStack {
        AmbientBackground()
        EmptyStateView.compileLocked(currentCount: 2)
    }
}

#Preview("Archive Day Empty") {
    ZStack {
        AmbientBackground()
        EmptyStateView.archiveDayEmpty { }
    }
}

#Preview("Mic Denied") {
    ZStack {
        AmbientBackground()
        EmptyStateView.micPermissionDenied { }
    }
}
