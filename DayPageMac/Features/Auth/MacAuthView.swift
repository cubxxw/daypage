import AuthenticationServices
import SwiftUI

struct MacAuthView: View {
    @EnvironmentObject private var auth: MacCloudAuthService
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("登录 DayPage")
                    .font(.system(size: 26, weight: .semibold))
                Text("记录仍会先保存到本机 Vault；登录后，待同步内容会自动安全上传。")
                    .foregroundStyle(.secondary)
            }

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    Task { await signInWithApple(authorization) }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        localError = "Apple 登录失败，请稍后重试。"
                    }
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 42)

            HStack {
                Divider()
                Text("或使用邮箱验证码")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
            }

            TextField("you@example.com", text: $email)
                .textFieldStyle(.roundedBorder)
                .disabled(codeSent || auth.isLoading)

            if codeSent {
                TextField("6 位验证码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await verifyCode() } }
            }

            if let message = localError ?? auth.errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                if codeSent {
                    Button("修改邮箱") {
                        codeSent = false
                        code = ""
                        localError = nil
                    }
                }
                Spacer()
                Button(codeSent ? "验证并同步" : "发送验证码") {
                    Task { codeSent ? await verifyCode() : await sendCode() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(auth.isLoading || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if auth.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        .frame(width: 420)
        .onChange(of: auth.session != nil) { signedIn in
            if signedIn { dismiss() }
        }
    }

    private func sendCode() async {
        localError = nil
        do {
            try await auth.sendOTP(email: email)
            codeSent = true
        } catch {
            localError = error.localizedDescription
        }
    }

    private func verifyCode() async {
        localError = nil
        do {
            try await auth.verifyOTP(email: email, code: code)
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
}
