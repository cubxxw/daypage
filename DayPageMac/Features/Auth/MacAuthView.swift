import AuthenticationServices
import SwiftUI
import DayPageStorage

/// macOS account center. The interaction model intentionally differs from
/// iOS: it is a focused desktop sheet opened from the toolbar, while its
/// account, local-first and device-local sign-out semantics stay identical.
struct MacAuthView: View {
    private enum EmailStage: Equatable {
        case entry
        case linkSent(address: String)
    }

    @EnvironmentObject private var auth: MacCloudAuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject private var syncQueue = SyncQueueService.shared

    @State private var email = ""
    @State private var emailStage: EmailStage = .entry
    @State private var resendSeconds = 0
    @State private var localError: String?
    @State private var isSigningOut = false
    @State private var showSignOutConfirmation = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.07),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .center
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    identityCard

                    if let message = localError ?? auth.errorMessage {
                        errorBanner(message)
                    }

                    if auth.session == nil {
                        signedOutContent
                    } else {
                        signedInContent
                    }
                }
                .padding(28)
            }
        }
        .frame(width: 520)
        .frame(minHeight: 560, idealHeight: 650, maxHeight: 720)
        .confirmationDialog(
            "退出此设备？",
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                Task { await signOutThisDevice() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mac 会回到仅本地模式；其他设备保持登录，本地 Vault 不会被删除。")
        }
        .onChange(of: auth.session != nil) { signedIn in
            if signedIn {
                localError = nil
                emailStage = .entry
                resendSeconds = 0
            }
        }
        .task(id: emailStage) {
            guard case .linkSent = emailStage else { return }
            while resendSeconds > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                resendSeconds -= 1
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DAYPAGE · ACCOUNT")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(.secondary)

                Text(auth.session == nil ? "让记录跟着你" : "账户与同步")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭账户中心")
            .accessibilityLabel("关闭账户中心")
        }
    }

    private var identityCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange.opacity(0.45), Color.brown],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)

                if let initial = auth.accountLabel?.first {
                    Text(String(initial).uppercased())
                        .font(.system(size: 23, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(auth.accountLabel ?? "仅本机账户")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .textSelection(.enabled)

                Label(syncTitle, systemImage: syncSymbol)
                    .font(.callout)
                    .foregroundStyle(syncTint)

                Text(syncDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("登录后自动开启")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 11) {
                benefitRow("arrow.triangle.2.circlepath", "同一账户在 iPhone、Mac 与 Web 间同步")
                benefitRow("externaldrive.badge.icloud", "仍然先写入本机，离线时也不会丢失")
                benefitRow("point.3.connected.trianglepath.dotted", "通过授权的 MCP 安全访问记录")
            }

            SignInWithAppleButton(.signIn) { request in
                auth.prepareAppleSignInRequest(request)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task { await signInWithApple(authorization) }
                case .failure(let error):
                    auth.cancelAppleSignIn()
                    if (error as? ASAuthorizationError)?.code == .canceled {
                        localError = nil
                    } else {
                        localError = "Apple 登录失败，请稍后重试。"
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 44)
            .disabled(auth.isLoading)

            HStack {
                Divider()
                Text("或使用邮箱登录链接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Divider()
            }

            emailSignInSection

            if auth.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安全登录…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }

            Text("登录不是使用 DayPage 的前置条件。未登录时，记录只保存在这台 Mac 的 Vault 中。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emailSignInSection: some View {
        switch emailStage {
        case .entry:
            VStack(alignment: .leading, spacing: 12) {
                TextField("you@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(auth.isLoading)
                    .onSubmit { Task { await sendMagicLink() } }
                    .accessibilityLabel("邮箱地址")

                HStack {
                    Spacer()
                    Button("发送登录链接") {
                        Task { await sendMagicLink() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        auth.isLoading
                            || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        case .linkSent(let address):
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("登录链接已发送")
                            .font(.callout.weight(.semibold))
                        Text(address)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text("请在发送请求的这台 Mac 上打开邮件并点击链接，DayPage 会自动完成登录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .combine)

                HStack {
                    Button("修改邮箱") {
                        emailStage = .entry
                        localError = nil
                    }

                    Spacer()

                    Button(resendSeconds > 0 ? "\(resendSeconds) 秒后可重发" : "重新发送") {
                        Task { await sendMagicLink(to: address) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(auth.isLoading || resendSeconds > 0)
                }
            }
        }
    }

    private var signedInContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("当前身份")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.secondary)

            detailRow(
                symbol: "lock.shield",
                title: auth.accountLabel ?? "已验证账户",
                detail: "会话凭证由系统安全存储保护"
            )

            HStack(spacing: 12) {
                if syncQueue.pendingCount > 0 {
                    Button("立即同步") { auth.retrySync() }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncQueue.isFlushingNow)
                }

                Spacer()

                Button("退出此设备", role: .destructive) {
                    showSignOutConfirmation = true
                }
                .disabled(isSigningOut)
            }

            Text("退出不会删除本地 Vault，也不会让你的其他设备退出。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func benefitRow(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
    }

    private func detailRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .textSelection(.enabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    private var syncTitle: String {
        guard auth.session != nil else { return "只保存在这台 Mac" }
        if syncQueue.isFlushingNow { return "正在同步" }
        if syncQueue.pendingCount > 0 { return "\(syncQueue.pendingCount) 条等待同步" }
        return "已同步"
    }

    private var syncDetail: String {
        guard auth.session != nil else { return "登录后会自动上传现有待同步记录" }
        if syncQueue.isFlushingNow { return "正在上传并获取其他设备的更新" }
        if syncQueue.pendingCount > 0 { return "内容已保存在本机，可安全关闭此页面" }
        return "这个账户的设备会自动接收新记录"
    }

    private var syncSymbol: String {
        guard auth.session != nil else { return "externaldrive" }
        if syncQueue.isFlushingNow { return "arrow.triangle.2.circlepath" }
        if syncQueue.pendingCount > 0 { return "icloud.and.arrow.up" }
        return "checkmark.icloud"
    }

    private var syncTint: Color {
        guard auth.session != nil else { return .secondary }
        if syncQueue.pendingCount > 0 { return .orange }
        return .green
    }

    private func sendMagicLink(to address: String? = nil) async {
        localError = nil
        let requestedEmail = address ?? email
        do {
            try await auth.sendMagicLink(email: requestedEmail)
            let normalized = requestedEmail
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            email = normalized
            resendSeconds = 60
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                emailStage = .linkSent(address: normalized)
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func signInWithApple(_ authorization: ASAuthorization) async {
        localError = nil
        do {
            try await auth.signInWithApple(authorization: authorization)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func signOutThisDevice() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        localError = nil
        await auth.signOut()
        isSigningOut = false

        if auth.session == nil {
            dismiss()
        } else {
            localError = auth.errorMessage ?? "退出失败，请稍后再试。"
        }
    }
}
