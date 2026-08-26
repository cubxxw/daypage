import Foundation
import Testing
@testable import DayPageServices

@Suite("Native auth flow")
struct NativeAuthFlowTests {
    @Test("Platform callbacks are distinct and stable")
    func platformCallbacks() throws {
        #expect(try NativeAuthFlow.callbackURL(for: .iOS).absoluteString == "daypage://auth-callback")
        #expect(try NativeAuthFlow.callbackURL(for: .macOS).absoluteString == "daypagemac://auth-callback")
    }

    @Test("Callback validation accepts only the owned authority")
    func callbackValidation() throws {
        let valid = try #require(URL(string: "daypagemac://auth-callback?code=pkce-code"))
        let validFragment = try #require(URL(string: "daypagemac://auth-callback/#access_token=token"))
        let wrongScheme = try #require(URL(string: "daypage://auth-callback?code=pkce-code"))
        let wrongHost = try #require(URL(string: "daypagemac://record?code=pkce-code"))
        let unexpectedPath = try #require(URL(string: "daypagemac://auth-callback/other?code=pkce-code"))

        #expect(NativeAuthFlow.isCallback(valid, for: .macOS))
        #expect(NativeAuthFlow.isCallback(validFragment, for: .macOS))
        #expect(!NativeAuthFlow.isCallback(wrongScheme, for: .macOS))
        #expect(!NativeAuthFlow.isCallback(wrongHost, for: .macOS))
        #expect(!NativeAuthFlow.isCallback(unexpectedPath, for: .macOS))
    }

    @Test("Nonce uses 256 bits and URL-safe Base64")
    func nonceShape() throws {
        let first = try NativeAuthFlow.randomNonce()
        let second = try NativeAuthFlow.randomNonce()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test("Nonce hashing uses SHA-256 lowercase hex")
    func nonceHash() {
        #expect(
            NativeAuthFlow.sha256("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("Nonce rejects an empty entropy request")
    func nonceRejectsEmptyEntropy() {
        #expect(throws: NativeAuthFlow.Error.invalidByteCount) {
            try NativeAuthFlow.randomNonce(byteCount: 0)
        }
    }
}
