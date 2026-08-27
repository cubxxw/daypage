import XCTest
import DayPageModels
@testable import DayPageStorage

final class MemoRecordStoreTests: XCTestCase {
    private var vaultURL: URL!
    private let day = Date(timeIntervalSince1970: 1_775_520_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoRecordStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultURL.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        VaultInitializer.testOverrideURL = vaultURL
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        if let vaultURL {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        try super.tearDownWithError()
    }

    func testLoadsUpdatesAndDeletesByStableID() async throws {
        let target = Memo(id: UUID(), created: day, body: "before")
        let sibling = Memo(id: UUID(), created: day.addingTimeInterval(10), body: "keep")
        try RawStorage.rewrite([target, sibling], for: day)

        let store = MemoRecordStore()
        let loaded = try await store.memo(id: target.id, day: day)
        XCTAssertEqual(loaded.body, "before")

        let updated = try await store.updateBody(id: target.id, day: day, body: "after")
        XCTAssertEqual(updated.body, "after")
        XCTAssertEqual(try RawStorage.read(for: day).first(where: { $0.id == sibling.id })?.body, "keep")

        try await store.delete(id: target.id, day: day)
        let remaining = try RawStorage.read(for: day)
        XCTAssertEqual(remaining.map(\.id), [sibling.id])
    }

    func testMissingRecordAndEmptyBodyFailWithoutWriting() async throws {
        let memo = Memo(id: UUID(), created: day, body: "original")
        try RawStorage.rewrite([memo], for: day)
        let store = MemoRecordStore()

        do {
            _ = try await store.updateBody(id: memo.id, day: day, body: "  \n")
            XCTFail("Expected emptyBody")
        } catch {
            XCTAssertEqual(error as? MemoRecordStoreError, .emptyBody)
        }

        do {
            try await store.delete(id: UUID(), day: day)
            XCTFail("Expected notFound")
        } catch {
            guard let storeError = error as? MemoRecordStoreError,
                  case .notFound = storeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try RawStorage.read(for: day), [memo])
    }

    func testCaptureAttachmentFilingIsSourceBoundAndIdempotent() throws {
        let memo = Memo(id: UUID(), created: day, body: "source")
        try RawStorage.rewrite([memo], for: day)
        let attachment = Memo.Attachment(
            file: "raw/assets/capture_fixed.pdf",
            kind: "file"
        )

        let first = try XCTUnwrap(try RawStorage.appendAttachment(
            attachment,
            toMemoID: memo.id
        ))
        let replay = try XCTUnwrap(try RawStorage.appendAttachment(
            attachment,
            toMemoID: memo.id
        ))

        XCTAssertEqual(first.attachments, [attachment])
        XCTAssertEqual(replay.attachments, [attachment])
        XCTAssertEqual(RawStorage.memo(id: memo.id)?.attachments, [attachment])
        XCTAssertNil(try RawStorage.appendAttachment(attachment, toMemoID: UUID()))
        XCTAssertNil(try RawStorage.appendAttachment(
            .init(file: "../outside", kind: "file"),
            toMemoID: memo.id
        ))
    }
}
