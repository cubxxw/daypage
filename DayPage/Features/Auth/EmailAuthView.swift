import SwiftUI
import DayPageServices

// MARK: - EmailSubmitButtonStyle

/// Press-scale style for the email submit button — matches AuthButtonStyle in AuthView.
private struct EmailSubmitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - EmailAuthView

/// 两阶段邮箱登录：
/// 1. 输入邮箱并请求 magic link。
/// 2. 明确提示用户在同一台设备上打开邮件链接，并提供重发与改邮箱。
///
/// 状态保存在 `@StateObject EmailAuthViewModel` 中，这样关闭表单
/// 不会静默丢失进行中的数据。VM 还提供了网络活动防抖
/// 并暴露单一错误通道。
struct EmailAuthView: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = EmailAuthViewModel()
    @FocusState private var emailFocused: Bool
    @State private var resendCountdown = 0

    var body: some View {
        ZStack {
            DSColor.bgWarm.ignoresSafeArea()
            GrainOverlay()

            Group {
                switch viewModel.stage {
                case .email:
                    emailStage
                case .linkSent:
                    linkSentStage
                }
            }
            .environmentObject(authService)
            .animation(.easeOut(duration: 0.25), value: viewModel.stage)
        }
        .task {
            // 视图激活后将 VM 绑定到共享的 AuthService。
            viewModel.bind(authService: authService)
        }
        .task(id: viewModel.linkSendCount) {
            guard viewModel.stage == .linkSent else { return }
            resendCountdown = authService.resendCooldownRemaining(email: viewModel.email)
            while resendCountdown > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                resendCountdown -= 1
            }
        }
    }

    // MARK: - Email Stage

    private var emailStage: some View {
        // ScrollView ensures the Send Code button stays reachable when the keyboard
        // is shown on small devices. The VStack's bottom Spacer keeps content
        // anchored top on large screens.
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                backButton

                Spacer().frame(height: 32)

                Text("Enter your email")
                    .font(DSFonts.serif(size: 26, weight: .semibold, relativeTo: .title))
                    .foregroundColor(DSColor.inkPrimary)

                Spacer().frame(height: 8)

                Text("We'll send you a secure sign-in link.")
                    .font(.custom("Inter-Regular", size: 14))
                    .foregroundColor(DSColor.inkSecondary)

                Spacer().frame(height: 24)

                TextField("", text: $viewModel.email, prompt: Text("you@domain.com").foregroundColor(DSColor.inkMuted))
                    .font(.custom("Inter-Regular", size: 17))
                    .foregroundColor(DSColor.inkPrimary)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($emailFocused)
                    .onSubmit {
                        Task { await viewModel.sendMagicLink() }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(DSColor.surfaceWhite)
                    .cornerRadius(12)
                    .overlay(
                        // Amber focus ring — the field is the only actionable
                        // element on this stage, so it should visibly "own"
                        // focus instead of relying on the caret alone.
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                emailFocused ? DSColor.accentOnBg : DSColor.inkFaint,
                                lineWidth: emailFocused ? 1.5 : 1
                            )
                    )
                    .animation(Motion.fade, value: emailFocused)

                Spacer().frame(height: 16)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.statusError)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage)
                }

                Button {
                    Task { await viewModel.sendMagicLink() }
                } label: {
                    ZStack {
                        Text("Send Sign-In Link")
                            .font(.custom("SpaceGrotesk-Medium", size: 16))
                            .foregroundColor(viewModel.isValidEmail ? DSColor.onAmber : DSColor.inkMuted)
                            .opacity(viewModel.isSending ? 0 : 1)

                        if viewModel.isSending {
                            // Spinner only shows while the button is enabled
                            // (amberDeep fill), so onAmber keeps it legible.
                            ProgressView()
                                .tint(DSColor.onAmber)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(viewModel.isValidEmail ? DSColor.amberDeep : DSColor.surfaceSunken)
                    .cornerRadius(DSRadius.md)
                }
                .buttonStyle(EmailSubmitButtonStyle())
                .disabled(!viewModel.isValidEmail || viewModel.isSending)
                .accessibilityLabel(viewModel.isSending ? "Sending sign-in link" : "Send sign-in link")
                .accessibilityHint("Sends a secure one-time sign-in link to your email")

                Spacer().frame(height: 32)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { emailFocused = true }
    }

    // MARK: - Link Sent Stage

    private var linkSentStage: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    viewModel.backToEmailStage()
                } label: {
                    Image(systemName: "chevron.left")
                        .foregroundColor(DSColor.inkSecondary)
                        .font(.system(size: 18, weight: .medium))
                        .padding(.vertical, 6)
                }
                .accessibilityLabel("Change email address")

                Spacer().frame(height: 32)

                Image(systemName: "envelope.badge")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(DSColor.accentOnBg)
                    .accessibilityHidden(true)

                Spacer().frame(height: 20)

                Text("Check your email")
                    .font(DSFonts.serif(size: 26, weight: .semibold, relativeTo: .title))
                    .foregroundColor(DSColor.inkPrimary)

                Spacer().frame(height: 8)

                (
                    Text("We sent a one-time sign-in link to\n")
                        .foregroundColor(DSColor.inkSecondary)
                    + Text(viewModel.normalizedEmail)
                        .foregroundColor(DSColor.inkPrimary)
                )
                .font(.custom("Inter-Regular", size: 14))
                .lineSpacing(4)
                .textSelection(.enabled)

                Spacer().frame(height: 20)

                Text("Open the link on this device. DayPage will return here and finish signing you in automatically.")
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DSColor.surfaceWhite, in: RoundedRectangle(cornerRadius: DSRadius.md))

                Spacer().frame(height: 16)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(DSType.bodySM)
                        .foregroundColor(DSColor.statusError)
                        .padding(.bottom, 8)
                }

                Button {
                    Task { await viewModel.sendMagicLink() }
                } label: {
                    ZStack {
                        Text(resendCountdown > 0 ? "Resend in \(resendCountdown)s" : "Resend Sign-In Link")
                            .font(.custom("SpaceGrotesk-Medium", size: 15))
                            .foregroundColor(DSColor.inkSecondary)
                            .opacity(viewModel.isSending ? 0 : 1)

                        if viewModel.isSending {
                            ProgressView().tint(DSColor.inkPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(DSColor.surfaceWhite)
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.md)
                            .stroke(DSColor.inkFaint, lineWidth: 1)
                    )
                    .cornerRadius(DSRadius.md)
                }
                .buttonStyle(EmailSubmitButtonStyle())
                .disabled(viewModel.isSending || resendCountdown > 0)

                Spacer().frame(height: 12)

                Button("Use a different email") {
                    viewModel.backToEmailStage()
                }
                .font(DSType.bodySM)
                .foregroundColor(DSColor.accentOnBg)
                .frame(maxWidth: .infinity)

                Spacer().frame(height: 32)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
    }

    // MARK: - Pieces

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .foregroundColor(DSColor.inkSecondary)
                .font(.system(size: 18, weight: .medium))
                .padding(.vertical, 6)
        }
        .accessibilityLabel(NSLocalizedString("a11y.dismiss", comment: "Dismiss button"))
    }
}

// MARK: - EmailAuthViewModel

@MainActor
final class EmailAuthViewModel: ObservableObject {

    enum Stage: Equatable {
        case email
        case linkSent
    }

    @Published var email: String = ""
    @Published var stage: Stage = .email
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var linkSendCount = 0

    private weak var authService: AuthService?

    var isValidEmail: Bool {
        let regex = #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#
        return email.range(of: regex, options: .regularExpression) != nil
    }

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func bind(authService: AuthService) {
        self.authService = authService
    }

    func sendMagicLink() async {
        guard isValidEmail, !isSending else { return }
        guard let authService else { return }
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            try await authService.sendMagicLink(email: normalizedEmail)
            email = normalizedEmail
            stage = .linkSent
            linkSendCount += 1
            // 清除之前尝试遗留的过时 AuthService.error。
            authService.error = nil
        } catch let err as DPAuthError {
            errorMessage = err.errorDescription
            HapticFeedback.error()
        } catch {
            errorMessage = "发送失败，请稍后再试"
            HapticFeedback.error()
        }
    }

    func backToEmailStage() {
        stage = .email
        authService?.error = nil
        errorMessage = nil
    }
}
