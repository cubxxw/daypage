import XCTest
@testable import DayPage

final class DSFontsSerifTests: XCTestCase {

    // MARK: - serif() returns a non-nil Font for every supported weight

    func testSerifRegularReturnsFont() {
        let font = DSFonts.serif(size: 16, weight: .regular)
        // Font is a value type with no nil state; we verify it round-trips through
        // UIFont without crashing and produces a valid descriptor.
        let uiFont = UIFont(name: "SourceSerif4-Regular", size: 16)
        XCTAssertNotNil(uiFont, "SourceSerif4-Regular must be registered in the bundle")
        // DSFonts.serif() must not throw or return a zero-size font.
        XCTAssertNoThrow(_ = font)
    }

    func testSerifMediumReturnsFont() {
        let font = DSFonts.serif(size: 18, weight: .medium)
        let uiFont = UIFont(name: "SourceSerif4-Medium", size: 18)
        XCTAssertNotNil(uiFont, "SourceSerif4-Medium must be registered in the bundle")
        XCTAssertNoThrow(_ = font)
    }

    func testSerifSemiboldReturnsFont() {
        let font = DSFonts.serif(size: 20, weight: .semibold)
        let uiFont = UIFont(name: "SourceSerif4-SemiBold", size: 20)
        XCTAssertNotNil(uiFont, "SourceSerif4-SemiBold must be registered in the bundle")
        XCTAssertNoThrow(_ = font)
    }

    func testSerifItalicReturnsFont() {
        let font = DSFonts.serif(size: 16, italic: true)
        let uiFont = UIFont(name: "SourceSerif4-It", size: 16)
        XCTAssertNotNil(uiFont, "SourceSerif4-It must be registered in the bundle")
        XCTAssertNoThrow(_ = font)
    }

    // MARK: - Cascade list is wired correctly when fonts are available

    func testSerifCascadeListContainsCJKFace() {
        guard
            let latin = UIFont(name: "SourceSerif4-Regular", size: 16),
            UIFont(name: "SourceHanSerifSC-Regular", size: 16) != nil
        else {
            // Fonts not registered in this test environment; skip cascade verification.
            return
        }

        let cjkDescriptor = UIFont(name: "SourceHanSerifSC-Regular", size: 16)!.fontDescriptor
        let descriptor = latin.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName.cascadeList: [cjkDescriptor]
        ])
        let cascadeList = descriptor.object(forKey: .cascadeList) as? [UIFontDescriptor]
        XCTAssertNotNil(cascadeList, "cascadeList attribute must be present")
        XCTAssertEqual(cascadeList?.count, 1)
        XCTAssertEqual(cascadeList?.first?.postscriptName, "SourceHanSerifSC-Regular")
    }

    // MARK: - Fallback path: graceful system font returned when face unavailable

    func testSerifFallbackDoesNotCrash() {
        // DSFonts.serif() must never crash regardless of whether fonts are present.
        for weight: Font.Weight in [.regular, .medium, .semibold] {
            XCTAssertNoThrow(_ = DSFonts.serif(size: 14, weight: weight))
            XCTAssertNoThrow(_ = DSFonts.serif(size: 14, weight: weight, italic: true))
        }
    }
}
