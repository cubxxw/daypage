import AuthenticationServices
import Foundation
import Supabase
import DayPageStorage

@MainActor
final class MacCloudAuthService: NSObject, ObservableObject {
    static let shared = MacCloudAuthService()

    @Published private(set) var session: Session?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    let client: SupabaseClient

    private let configuration: MacCloudConfiguration
    private var authStateTask: Task<Void, Never>?

    private override init() {
        let configuration = MacCloudConfiguration.current()
        self.configuration = configuration
        self.client = SupabaseClient(
            supabaseURL: configuration.supabaseURL,
            supabaseKey: configuration.publishableKey
        )
        super.init()

        // Captures may enqueue before auth restoration finishes. Instantiate
        // the fail-closed observer immediately; the session event below swaps
        // in the real uploader and drains the durable backlog.
        _ = SyncQueueObserver.shared
        SyncQueueObserver.shared.setUploader(NoopRemoteUploader())
        startAuthStateListener()
        Task { await SyncQueueService.shared.reconcileVault() }
    }

    deinit {
        authStateTask?.cancel()
    }

    var accountLabel: String? {
        session?.user.email
    }

    func sendOTP(email: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.contains("@") else { throw MacCloudAuthError.invalidEmail }
        try await perform {
            try await client.auth.signInWithOTP(email: normalized, shouldCreateUser: true)
        }
    }

    func verifyOTP(email: String, code: String) async throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedCode = code.filter(\.isNumber)
        guard normalizedCode.count == 6 else { throw MacCloudAuthError.invalidCode }
        try await perform {
            _ = try await client.auth.verifyOTP(
                email: normalizedEmail,
                token: normalizedCode,
                type: .email
            )
        }
    }

    func signInWithApple(authorization: ASAuthorization) async throws {
        try await perform {
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                throw MacCloudAuthError.missingAppleCredential
            }
            _ = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: identityToken)
            )
        }
    }

    func signOut() async {
        do {
            try await client.auth.signOut()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func retrySync() {
        Task { await SyncQueueService.shared.flushIfOnline() }
    }

    private func startAuthStateListener() {
        authStateTask?.cancel()
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await (_, restoredSession) in client.auth.authStateChanges {
                if Task.isCancelled { break }
                session = restoredSession
                installUploader(for: restoredSession)
            }
        }
    }

    private func installUploader(for session: Session?) {
        guard session != nil else {
            SyncQueueObserver.shared.setUploader(NoopRemoteUploader())
            return
        }
        SyncQueueObserver.shared.setUploader(SupabaseSyncUploader(
            supabaseURL: configuration.supabaseURL,
            anonKey: configuration.publishableKey,
            accessTokenProvider: { [weak self] in
                try await MainActor.run {
                    guard let token = self?.session?.accessToken, !token.isEmpty else {
                        throw MemoSyncError.unauthorized
                    }
                    return token
                }
            }
        ))
        Task { await SyncQueueService.shared.flushIfOnline() }
    }

    private func perform(_ operation: () async throws -> Void) async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            return
        } catch {
            let message = userFacingMessage(for: error)
            errorMessage = message
            throw MacCloudAuthError.remote(message)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let local = error as? MacCloudAuthError {
            return local.localizedDescription
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut:
                return "网络暂不可用，本地记录不会丢失，请稍后重试。"
            default:
                break
            }
        }
        return "登录失败，请检查邮箱、验证码或稍后重试。"
    }
}

private enum MacCloudAuthError: LocalizedError {
    case invalidEmail
    case invalidCode
    case missingAppleCredential
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "请输入有效的邮箱地址。"
        case .invalidCode:
            return "请输入 6 位验证码。"
        case .missingAppleCredential:
            return "无法读取 Apple 登录凭证。"
        case .remote(let message):
            return message
        }
    }
}
