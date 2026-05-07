import SwiftUI

// MARK: - WelcomeScreen

/// First-run welcome shown once after onboarding — a fading Day Orb, bilingual serif line, Begin pill.
/// Dismissed permanently via "hasSeenWelcome" UserDefaults key.
struct WelcomeScreen: View {

    @Binding var hasSeenWelcome: Bool

    @State private var orbOpacity: Double = 0

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Day Orb — fades in over 800ms
                DayOrbView(signalCount: 0, size: 156)
                    .opacity(orbOpacity)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.8)) {
                            orbOpacity = 1
                        }
                    }

                // Bilingual serif tagline
                VStack(spacing: 8) {
                    Text("每一天，都值得留下来")
                        .font(DSType.serifDisplay32)
                        .foregroundColor(DSColor.inkPrimary)
                        .multilineTextAlignment(.center)

                    Text("Every day deserves a record.")
                        .font(DSType.serifBody18)
                        .foregroundColor(DSColor.inkMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Spacer()

                // Begin pill button
                Button {
                    Haptics.commit()
                    UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                    withAnimation(Motion.rise) {
                        hasSeenWelcome = true
                    }
                } label: {
                    Text("开始 · Begin")
                        .font(DSFonts.inter(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 14)
                        .background(DSColor.amberDeep)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer().frame(height: 40)
            }
        }
    }
}
