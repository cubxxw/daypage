import XCTest
@testable import DayPageModels

final class MemoPresentationSafetyTests: XCTestCase {

    func testRoundedIntRejectsEveryNonRepresentableValue() {
        XCTAssertNil(MemoPresentationSafety.roundedInt(.nan))
        XCTAssertNil(MemoPresentationSafety.roundedInt(.infinity))
        XCTAssertNil(MemoPresentationSafety.roundedInt(-.infinity))
        XCTAssertNil(MemoPresentationSafety.roundedInt(Double.greatestFiniteMagnitude))
        XCTAssertNil(MemoPresentationSafety.roundedInt(-Double.greatestFiniteMagnitude))
        XCTAssertEqual(MemoPresentationSafety.roundedInt(125.4), 125)
        XCTAssertEqual(MemoPresentationSafety.roundedInt(125.6), 126)
    }

    func testDurationRejectsNonFiniteAndNegativeValues() {
        XCTAssertNil(MemoPresentationSafety.duration(nil))
        XCTAssertNil(MemoPresentationSafety.duration(.nan))
        XCTAssertNil(MemoPresentationSafety.duration(.infinity))
        XCTAssertNil(MemoPresentationSafety.duration(-0.01))
        XCTAssertEqual(MemoPresentationSafety.duration(0), 0)
        XCTAssertEqual(MemoPresentationSafety.duration(61.25), 61.25)
    }

    func testCoordinateRequiresFiniteGeographicBounds() {
        XCTAssertEqual(
            MemoPresentationSafety.coordinate(latitude: 31.2304, longitude: 121.4737),
            MemoCoordinate(latitude: 31.2304, longitude: 121.4737)
        )
        XCTAssertNil(MemoPresentationSafety.coordinate(latitude: 91, longitude: 0))
        XCTAssertNil(MemoPresentationSafety.coordinate(latitude: 0, longitude: -181))
        XCTAssertNil(MemoPresentationSafety.coordinate(latitude: .nan, longitude: 1))
        XCTAssertNil(MemoPresentationSafety.coordinate(latitude: 1, longitude: .infinity))
    }

    func testAttachmentPathCannotEscapeVault() {
        XCTAssertEqual(
            MemoPresentationSafety.relativeAttachmentPath("raw/assets/photo.jpg"),
            "raw/assets/photo.jpg"
        )
        XCTAssertNil(MemoPresentationSafety.relativeAttachmentPath("/tmp/photo.jpg"))
        XCTAssertNil(MemoPresentationSafety.relativeAttachmentPath("raw/../secret"))
        XCTAssertNil(MemoPresentationSafety.relativeAttachmentPath("raw//photo.jpg"))
        XCTAssertNil(MemoPresentationSafety.relativeAttachmentPath(""))
    }
}
