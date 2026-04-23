import XCTest
@testable import DayPage

/// Unit tests for ConflictMerger raw memo merge logic.
final class ConflictMergerTests: XCTestCase {

    // MARK: - Helpers

    private func makeMemo(id: UUID = UUID(), created: Date = Date(), body: String = "") -> Memo {
        Memo(id: id, type: .text, created: created, body: body)
    }

    // MARK: - UUID Deduplication

    func testMerge_keepsUniqueMemos() {
        let a = makeMemo(body: "A")
        let b = makeMemo(body: "B")
        let merged = ConflictMerger.mergeRawMemos(original: [a], conflict: [b])
        XCTAssertEqual(merged.count, 2)
    }

    func testMerge_duplicateUUIDKeepsOnlyOne() {
        let sharedID = UUID()
        let original = makeMemo(id: sharedID, body: "original")
        let conflict = makeMemo(id: sharedID, body: "conflict")
        let merged = ConflictMerger.mergeRawMemos(original: [original], conflict: [conflict])
        XCTAssertEqual(merged.count, 1)
        // First occurrence (from original, which sorts first when created == created) wins.
        XCTAssertEqual(merged.first?.body, "original")
    }

    func testMerge_resultIsSortedByCreated() {
        let early = makeMemo(created: Date(timeIntervalSince1970: 1000), body: "early")
        let late  = makeMemo(created: Date(timeIntervalSince1970: 2000), body: "late")
        // Pass in reversed order to verify sorting.
        let merged = ConflictMerger.mergeRawMemos(original: [late], conflict: [early])
        XCTAssertEqual(merged.map(\.body), ["early", "late"])
    }

    func testMerge_emptyArrays() {
        let merged = ConflictMerger.mergeRawMemos(original: [], conflict: [])
        XCTAssertTrue(merged.isEmpty)
    }

    func testMerge_emptyOriginal() {
        let b = makeMemo(body: "B")
        let merged = ConflictMerger.mergeRawMemos(original: [], conflict: [b])
        XCTAssertEqual(merged.count, 1)
    }

    func testMerge_emptyConflict() {
        let a = makeMemo(body: "A")
        let merged = ConflictMerger.mergeRawMemos(original: [a], conflict: [])
        XCTAssertEqual(merged.count, 1)
    }

    func testMerge_nonOverlappingSetsProduceUnion() {
        let a = makeMemo(created: Date(timeIntervalSince1970: 100), body: "A")
        let b = makeMemo(created: Date(timeIntervalSince1970: 200), body: "B")
        let c = makeMemo(created: Date(timeIntervalSince1970: 300), body: "C")
        let d = makeMemo(created: Date(timeIntervalSince1970: 400), body: "D")
        let merged = ConflictMerger.mergeRawMemos(original: [a, c], conflict: [b, d])
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map(\.body), ["A", "B", "C", "D"])
    }

    // MARK: - Log Line Merge

    func testMergeLogLines_deduplicatesByTimestampPrefix() {
        let original = "2025-01-01T00:00:00Z entry A\n2025-01-02T00:00:00Z entry B"
        let conflict = "2025-01-01T00:00:00Z entry A (dup)\n2025-01-03T00:00:00Z entry C"
        let merged = ConflictMerger.mergeLogLines(original: original, conflict: conflict)
        let lines = merged.components(separatedBy: "\n").filter { !$0.isEmpty }
        // "2025-01-01..." key appears twice in input; only one should survive.
        let jan1Lines = lines.filter { $0.hasPrefix("2025-01-01") }
        XCTAssertEqual(jan1Lines.count, 1)
        XCTAssertEqual(lines.count, 3)
    }

    // MARK: - JSON Entry Merge

    func testMergeJSONEntries_deduplicatesById() throws {
        let original = try JSONSerialization.data(withJSONObject: [
            ["id": "1", "value": "original"],
            ["id": "2", "value": "B"]
        ])
        let conflict = try JSONSerialization.data(withJSONObject: [
            ["id": "1", "value": "conflict-dup"],
            ["id": "3", "value": "C"]
        ])
        let merged = ConflictMerger.mergeJSONEntries(original: original, conflict: conflict, idKey: "id")
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [[String: Any]])
        XCTAssertEqual(array.count, 3)
        let ids = array.compactMap { $0["id"] as? String }.sorted()
        XCTAssertEqual(ids, ["1", "2", "3"])
        // id "1" should come from original (first occurrence).
        let entry1 = array.first { ($0["id"] as? String) == "1" }
        XCTAssertEqual(entry1?["value"] as? String, "original")
    }
}
