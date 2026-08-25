import Foundation
import XCTest
@testable import DayPageStorage

final class SyncContractFixtureTests: XCTestCase {
    private struct PushRequest: Decodable {
        let operations: [SyncOutboxOperation]

        enum CodingKeys: String, CodingKey {
            case operations = "p_operations"
        }
    }

    func testCanonicalPushFixtureDecodesIntoAppleOutboxTypes() throws {
        let request = try JSONDecoder.syncPushContract.decode(
            PushRequest.self,
            from: fixture(named: "sync-push-v1.json")
        )

        XCTAssertEqual(request.operations.count, 2)
        XCTAssertEqual(request.operations[0].kind, .upsert)
        XCTAssertEqual(request.operations[0].payload?.source, "ios")
        XCTAssertEqual(request.operations[0].payload?.vaultPath, "raw/2026-08-25.md")
        XCTAssertEqual(request.operations[1].kind, .delete)
        XCTAssertNil(request.operations[1].payload)
        XCTAssertEqual(request.operations[1].sizeBytes, 0)
    }

    func testCanonicalPullFixtureDecodesIntoApplePullTypes() throws {
        let page = try JSONDecoder.syncPullContract.decode(
            SyncPullPage.self,
            from: fixture(named: "sync-pull-page-v1.json")
        )

        XCTAssertTrue(page.isValid(after: 40))
        XCTAssertEqual(page.nextCursor, 42)
        XCTAssertEqual(page.changes.map(\.source), ["macos", "android"])
        XCTAssertFalse(page.changes[0].isDeleted)
        XCTAssertTrue(page.changes[1].isDeleted)
    }

    private func fixture(named name: String) throws -> Data {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repositoryRoot
            .appendingPathComponent("packages/contracts/fixtures")
            .appendingPathComponent(name))
    }
}

private extension JSONDecoder {
    static var syncPushContract: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = syncDateStrategy
        return decoder
    }

    static var syncPullContract: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = syncDateStrategy
        return decoder
    }

    private static var syncDateStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp"
            )
        }
    }
}
