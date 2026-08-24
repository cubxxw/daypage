import Foundation
import XCTest

final class SupabaseLiveTestConfigurationTests: XCTestCase {
    func testDerivesUserIDFromJWTSubject() throws {
        let expected = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": expected.uuidString.lowercased(),
            "aud": "authenticated",
        ])
        let encodedPayload = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(encodedPayload).test-signature"

        XCTAssertEqual(
            SupabaseLiveTestConfiguration.userID(fromAccessToken: token),
            expected
        )
    }

    func testRejectsMalformedAccessToken() {
        XCTAssertNil(
            SupabaseLiveTestConfiguration.userID(fromAccessToken: "not-a-jwt")
        )
    }
}
