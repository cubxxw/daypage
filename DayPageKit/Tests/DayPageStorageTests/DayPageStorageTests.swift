import XCTest
@testable import DayPageStorage

// Placeholder — real test suites migrate in Step 7 of ADR-0005 §6.
final class DayPageStoragePlaceholderTests: XCTestCase {
    func test_smoke() { XCTAssertTrue(true) }

    func testOperationalEventRejectsArbitraryTextAtTelemetryBoundary() {
        let correlationID = UUID()
        let event = OperationalEvent(
            area: "auth user@example.com",
            stage: "raw provider response",
            code: "token=secret",
            correlationID: correlationID,
            provider: "someone@example.com",
            httpStatus: 999,
            pendingCount: -42,
            consecutiveFailureCount: 99_999
        )

        XCTAssertEqual(event.area, "unknown")
        XCTAssertEqual(event.stage, "unknown")
        XCTAssertEqual(event.code, "unknown")
        XCTAssertEqual(event.provider, "unknown")
        XCTAssertEqual(event.httpStatus, 599)
        XCTAssertEqual(event.pendingCount, 0)
        XCTAssertEqual(event.consecutiveFailureCount, 10_000)
        XCTAssertEqual(event.correlationID, correlationID.uuidString.lowercased())
        XCTAssertEqual(event.message, "daypage.unknown.failure.unknown")
    }
}
