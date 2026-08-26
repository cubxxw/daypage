import CryptoKit
import Foundation
import Security

/// Shared security and callback rules for the native passwordless auth flows.
///
/// The callback schemes intentionally differ by platform so a Mac with both
/// DayPage apps installed never has to guess which app should redeem a PKCE
/// code. Both URLs must be present in Supabase's redirect allow list.
public enum NativeAuthFlow {
    public enum Platform: Sendable {
        case iOS
        case macOS

        fileprivate var callbackScheme: String {
            switch self {
            case .iOS: return "daypage"
            case .macOS: return "daypagemac"
            }
        }
    }

    public enum Error: LocalizedError, Equatable {
        case invalidByteCount
        case randomGenerationFailed(status: Int32)
        case invalidCallbackConfiguration

        public var errorDescription: String? {
            switch self {
            case .invalidByteCount:
                return "Nonce byte count must be greater than zero."
            case .randomGenerationFailed:
                return "The system could not create a secure login nonce."
            case .invalidCallbackConfiguration:
                return "The native auth callback URL is invalid."
            }
        }
    }

    /// The exact callback URL passed to Supabase when requesting a magic link.
    public static func callbackURL(for platform: Platform) throws -> URL {
        var components = URLComponents()
        components.scheme = platform.callbackScheme
        components.host = "auth-callback"
        guard let url = components.url else {
            throw Error.invalidCallbackConfiguration
        }
        return url
    }

    /// Accepts only the callback authority owned by the expected native app.
    /// Query items and fragments are intentionally allowed because Supabase
    /// adds the PKCE code or auth error there.
    public static func isCallback(_ url: URL, for platform: Platform) -> Bool {
        guard url.scheme?.lowercased() == platform.callbackScheme,
              url.host?.lowercased() == "auth-callback",
              url.user == nil,
              url.password == nil,
              url.port == nil
        else {
            return false
        }

        return url.path.isEmpty || url.path == "/"
    }

    /// Creates 256 bits of entropy and returns a URL-safe, unpadded Base64
    /// representation suitable for an OpenID Connect nonce.
    public static func randomNonce(byteCount: Int = 32) throws -> String {
        guard byteCount > 0 else { throw Error.invalidByteCount }

        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Error.randomGenerationFailed(status: status)
        }

        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Apple receives this digest while Supabase receives the original nonce.
    public static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
