import Foundation
import XCTest

/// Environment-only credentials for opt-in staging acceptance tests.
///
/// A caller can provide an existing access token, or a dedicated staging
/// email/password pair. Password mode exchanges the credential for a normal
/// Supabase Auth session immediately before the test, avoiding manual copying
/// of a short-lived JWT. Nothing is persisted by this helper.
struct SupabaseLiveTestConfiguration {
    let url: URL
    let publishableKey: String
    let accessToken: String
    let userID: UUID

    private static let productionProjectRef = "thnmxpgwzwprixfkqpkw"

    static func load() async throws -> SupabaseLiveTestConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard let urlValue = environment["DAYPAGE_SYNC_E2E_URL"],
              let url = URL(string: urlValue),
              let publishableKey = environment["DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY"],
              !publishableKey.isEmpty else {
            throw XCTSkip(
                "Set DAYPAGE_SYNC_E2E_URL and DAYPAGE_SYNC_E2E_PUBLISHABLE_KEY"
            )
        }

        guard url.host?.contains(productionProjectRef) != true else {
            throw SupabaseLiveTestConfigurationError.productionProjectForbidden
        }

        if let accessToken = environment["DAYPAGE_SYNC_E2E_ACCESS_TOKEN"],
           !accessToken.isEmpty {
            let explicitUserID = environment["DAYPAGE_SYNC_E2E_USER_ID"]
                .flatMap(UUID.init(uuidString:))
            guard let userID = explicitUserID ?? userID(fromAccessToken: accessToken) else {
                throw SupabaseLiveTestConfigurationError.invalidAccessToken
            }
            return SupabaseLiveTestConfiguration(
                url: url,
                publishableKey: publishableKey,
                accessToken: accessToken,
                userID: userID
            )
        }

        guard let email = environment["DAYPAGE_SYNC_E2E_EMAIL"], !email.isEmpty,
              let password = environment["DAYPAGE_SYNC_E2E_PASSWORD"], !password.isEmpty else {
            throw XCTSkip(
                "Set DAYPAGE_SYNC_E2E_ACCESS_TOKEN, or DAYPAGE_SYNC_E2E_EMAIL and DAYPAGE_SYNC_E2E_PASSWORD"
            )
        }

        return try await signIn(
            url: url,
            publishableKey: publishableKey,
            email: email,
            password: password
        )
    }

    static func userID(fromAccessToken accessToken: String) -> UUID? {
        let components = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var payload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(TokenClaims.self, from: data) else {
            return nil
        }
        return UUID(uuidString: claims.sub)
    }

    private static func signIn(
        url: URL,
        publishableKey: String,
        email: String,
        password: String
    ) async throws -> SupabaseLiveTestConfiguration {
        var components = URLComponents(
            url: url
                .appendingPathComponent("auth", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("token"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let endpoint = components?.url else {
            throw SupabaseLiveTestConfigurationError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(PasswordCredentials(
            email: email,
            password: password
        ))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseLiveTestConfigurationError.invalidResponse
        }
        guard 200...299 ~= http.statusCode else {
            throw SupabaseLiveTestConfigurationError.authenticationFailed(status: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let session = try decoder.decode(PasswordSession.self, from: data)
        guard !session.accessToken.isEmpty else {
            throw SupabaseLiveTestConfigurationError.invalidResponse
        }
        return SupabaseLiveTestConfiguration(
            url: url,
            publishableKey: publishableKey,
            accessToken: session.accessToken,
            userID: session.user.id
        )
    }

    private struct PasswordCredentials: Encodable {
        let email: String
        let password: String
    }

    private struct PasswordSession: Decodable {
        struct User: Decodable {
            let id: UUID
        }

        let accessToken: String
        let user: User
    }

    private struct TokenClaims: Decodable {
        let sub: String
    }
}

enum SupabaseLiveTestConfigurationError: LocalizedError, Equatable {
    case productionProjectForbidden
    case invalidURL
    case invalidAccessToken
    case invalidResponse
    case authenticationFailed(status: Int)

    var errorDescription: String? {
        switch self {
        case .productionProjectForbidden:
            return "Native sync acceptance tests must never target the production Supabase project"
        case .invalidURL:
            return "The staging Supabase URL is invalid"
        case .invalidAccessToken:
            return "The Supabase access token does not contain a valid user ID"
        case .invalidResponse:
            return "Supabase Auth returned an invalid response"
        case .authenticationFailed(let status):
            return "Supabase staging authentication failed with HTTP \(status)"
        }
    }
}
