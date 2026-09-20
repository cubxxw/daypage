import XCTest
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// Tests for InflightDraftStore — issue #23.
///
/// The store exists to protect against silent body-text loss when a submit
/// Task gets cancelled or the app is killed during the await chain that
/// precedes RawStorage.append (location, weather). Tests cover:
///
///   1. enqueue → file appears under vault/raw/.inflight/
///   2. dequeue → file disappears (and is idempotent if already gone)
///   3. pending() → returns newest-first, skips corrupt entries
///   4. clearAll() → drains every file
final class InflightDraftStoreTests: XCTestCase {

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("InflightDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = nil
        try? fm.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - enqueue / dequeue

    func testEnqueue_createsFileUnderInflightDirectory() throws {
        let url = InflightDraftStore.enqueue(body: "hello world", attachmentPaths: [])
        XCTAssertNotNil(url)
        XCTAssertTrue(fm.fileExists(atPath: url!.path))
        XCTAssertTrue(url!.path.contains("/raw/.inflight/"))
        XCTAssertEqual(url!.pathExtension, "json")
    }

    func testEnqueue_persistsBodyAndAttachments() throws {
        let body = "今天去山顶看日出，遇到一只松鼠"
        let atts = ["raw/assets/voice_A.m4a", "raw/assets/IMG_B.jpg"]
        guard let url = InflightDraftStore.enqueue(body: body, attachmentPaths: atts) else {
            XCTFail("enqueue returned nil"); return
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(InflightDraft.self, from: data)
        XCTAssertEqual(decoded.body, body)
        XCTAssertEqual(decoded.attachmentPaths, atts)
    }

    func testDequeue_removesFile() throws {
        let url = InflightDraftStore.enqueue(body: "body", attachmentPaths: [])!
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        InflightDraftStore.dequeue(url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testDequeue_isIdempotent() {
        let url = InflightDraftStore.enqueue(body: "body", attachmentPaths: [])!
        InflightDraftStore.dequeue(url)
        // Second call must not throw or assert.
        InflightDraftStore.dequeue(url)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testDequeue_acceptsNilURL() {
        InflightDraftStore.dequeue(nil) // must not crash
    }

    // MARK: - pending

    func testPending_returnsEmptyWhenDirectoryMissing() {
        XCTAssertEqual(InflightDraftStore.pending(), [])
    }

    func testPending_returnsAllEnqueuedDrafts() throws {
        _ = InflightDraftStore.enqueue(body: "a", attachmentPaths: [])
        _ = InflightDraftStore.enqueue(body: "b", attachmentPaths: [])
        _ = InflightDraftStore.enqueue(body: "c", attachmentPaths: [])
        let pending = InflightDraftStore.pending()
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(Set(pending.map { $0.body }), Set(["a", "b", "c"]))
    }

    func testPending_sortsNewestFirst() throws {
        // Enqueue three drafts with explicit timestamps via JSON injection
        // so we don't depend on Date() resolution.
        try fm.createDirectory(at: InflightDraftStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let now = Date()
        for (label, offset) in [("old", -3600.0), ("mid", -60.0), ("new", -1.0)] {
            let id = UUID()
            let draft = InflightDraft(
                id: id,
                body: label,
                enqueuedAt: now.addingTimeInterval(offset),
                attachmentPaths: []
            )
            let url = InflightDraftStore.directory.appendingPathComponent("\(id.uuidString).json")
            try encoder.encode(draft).write(to: url)
        }

        let pending = InflightDraftStore.pending()
        XCTAssertEqual(pending.map { $0.body }, ["new", "mid", "old"])
    }

    func testPending_skipsCorruptEntries() throws {
        let healthy = InflightDraftStore.enqueue(body: "healthy", attachmentPaths: [])!
        let corruptURL = InflightDraftStore.directory
            .appendingPathComponent("garbage.json")
        try "{ not valid json".write(to: corruptURL, atomically: true, encoding: .utf8)

        let pending = InflightDraftStore.pending()
        XCTAssertEqual(pending.count, 1, "Corrupt entry must be skipped, not crash recovery")
        XCTAssertEqual(pending.first?.body, "healthy")
        _ = healthy
    }

    // MARK: - clearAll

    func testClearAll_removesEveryDraft() throws {
        _ = InflightDraftStore.enqueue(body: "a", attachmentPaths: [])
        _ = InflightDraftStore.enqueue(body: "b", attachmentPaths: [])
        InflightDraftStore.clearAll()
        XCTAssertEqual(InflightDraftStore.pending(), [])
    }

    func testClearAll_noopWhenDirectoryMissing() {
        InflightDraftStore.clearAll() // must not throw
    }

    /// Audit regression: offering recovery must retain every durable draft.
    @MainActor
    func testDeepAuditRecoveryRetainsBodiesUntilAccepted() throws {
        try fm.createDirectory(at: InflightDraftStore.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (body, offset) in [("audit-older-unsaved", -60.0), ("audit-newer-unsaved", -1.0)] {
            let draft = InflightDraft(
                id: UUID(), body: body, enqueuedAt: Date().addingTimeInterval(offset),
                attachmentPaths: []
            )
            try encoder.encode(draft).write(
                to: InflightDraftStore.directory.appendingPathComponent("\(draft.id.uuidString).json")
            )
        }
        let model = TodayViewModel(date: Date(), observeChanges: false)
        model.recoverInflightDrafts()
        let recoverable = Set(InflightDraftStore.pending().map(\.body) + [model.lastFailedBody].compactMap { $0 })
        XCTAssertTrue(recoverable.contains("audit-older-unsaved"), "Recovery lost the older unsaved body")
        XCTAssertTrue(recoverable.contains("audit-newer-unsaved"))
        XCTAssertEqual(InflightDraftStore.pending().count, 2, "No composer has acknowledged either draft yet")
    }

    @MainActor
    func testOccupiedComposerDoesNotConsumePendingRecovery() throws {
        let entry = try makeEntry(body: "recover later")
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()

        XCTAssertNil(model.restoreNextInflightDraft(composerBody: "new work in progress"))
        XCTAssertNil(model.activeRecoveryDraft)
        XCTAssertNil(model.lastFailedBody, "Recovery must not trigger the old destructive composer hook")
        XCTAssertEqual(InflightDraftStore.pending().map(\.id), [entry.draft.id])
        XCTAssertTrue(fm.fileExists(atPath: entry.url.path))
    }

    @MainActor
    func testStagedRecoverySurvivesRestartAndKeepsEditedComposerAssociation() throws {
        let entry = try makeEntry(body: "original recovery", paths: ["raw/assets/voice_saved.m4a"])
        let first = TodayViewModel(observeChanges: false)
        first.recoverInflightDrafts()
        XCTAssertEqual(first.restoreNextInflightDraft(composerBody: ""), "original recovery")
        XCTAssertTrue(fm.fileExists(atPath: entry.url.path))

        let restarted = TodayViewModel(observeChanges: false)
        restarted.recoverInflightDrafts()
        XCTAssertEqual(restarted.resumeInflightDraft(at: entry.url, composerBody: "edited after restoring"), "edited after restoring")
        XCTAssertEqual(restarted.activeRecoveryDraft?.draft.id, entry.draft.id)
        XCTAssertEqual(restarted.pendingAttachments.map { $0.attachment.file }, entry.draft.attachmentPaths)
        XCTAssertEqual(InflightDraftStore.pending().count, 1)
    }

    @MainActor
    func testAttachmentOnlyRecoveryStagesPhotoAudioAndFileWithoutAcknowledging() throws {
        let paths = ["raw/assets/photo.jpg", "raw/assets/voice.m4a", "raw/assets/reference.pdf"]
        let entry = try makeEntry(body: "", paths: paths)
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()

        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), "")
        XCTAssertEqual(model.pendingAttachments.map { $0.attachment.file }, paths)
        XCTAssertEqual(model.pendingAttachments.map { $0.attachment.kind }, ["photo", "audio", "file"])
        XCTAssertEqual(model.activeRecoveryDraft?.draft.id, entry.draft.id)
        XCTAssertTrue(fm.fileExists(atPath: entry.url.path))
    }

    @MainActor
    func testInvalidNewestDraftDoesNotStarveHealthyOlderDraft() throws {
        let older = try makeEntry(body: "healthy older", date: Date().addingTimeInterval(-60))
        let invalid = try makeEntry(body: "retain invalid", paths: ["../outside.jpg"])
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()

        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), older.draft.body)
        XCTAssertEqual(model.activeRecoveryDraft?.draft.id, older.draft.id)
        XCTAssertTrue(fm.fileExists(atPath: invalid.url.path))
        XCTAssertEqual(InflightDraftStore.pending().count, 2)
    }

    @MainActor
    func testSuccessfulRecoveryAcknowledgesOnlyItsExactRecord() async throws {
        let older = try makeEntry(body: "keep this pending", date: Date().addingTimeInterval(-60))
        let target = try makeEntry(body: "save this recovery")
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()
        let body = try XCTUnwrap(model.restoreNextInflightDraft(composerBody: ""))

        XCTAssertTrue(model.submitCombinedMemo(body: body))
        await model.waitForSubmissionPersistence()
        XCTAssertFalse(fm.fileExists(atPath: target.url.path))
        XCTAssertEqual(InflightDraftStore.pending().map(\.id), [older.draft.id])
        let saved = try RawStorage.read(for: target.draft.enqueuedAt, vaultRoot: tempDir)
        XCTAssertEqual(saved.filter { $0.id == target.draft.id }.map(\.body), [target.draft.body])
    }

    @MainActor
    func testAttachmentOnlySaveFailureRetainsPathsAndRetryReusesID() async throws {
        let entry = try makeEntry(body: "", paths: ["raw/assets/voice_recover.m4a"])
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()
        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), "")
        let dayURL = RawStorage.fileURL(for: entry.draft.enqueuedAt, vaultRoot: tempDir)
        // A directory at the memo file path deterministically rejects the
        // write, without relying on host permissions or filling the disk.
        try fm.createDirectory(at: dayURL, withIntermediateDirectories: true)

        XCTAssertTrue(model.submitCombinedMemo(body: ""))
        await model.waitForSubmissionPersistence()
        XCTAssertNotNil(model.submitError)
        XCTAssertEqual(InflightDraftStore.pending().map(\.id), [entry.draft.id])
        XCTAssertEqual(InflightDraftStore.pending().first?.attachmentPaths, entry.draft.attachmentPaths)

        try fm.removeItem(at: dayURL)
        model.recoverInflightDrafts()
        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), "")
        XCTAssertTrue(model.submitCombinedMemo(body: ""))
        await model.waitForSubmissionPersistence()
        let saved = try RawStorage.read(for: entry.draft.enqueuedAt, vaultRoot: tempDir)
        XCTAssertEqual(saved.map(\.id), [entry.draft.id])
        XCTAssertEqual(saved.first?.attachments.map(\.file), entry.draft.attachmentPaths)
        XCTAssertEqual(saved.first?.attachments.first?.kind, "audio")
        XCTAssertNil(saved.first?.attachments.first?.transcriptionStatus, "Recovery must not invent a queued ASR job")
        XCTAssertTrue(InflightDraftStore.pending().isEmpty)
    }

    @MainActor
    func testJournalFailureRejectsSubmissionWithoutClearingStagedAttachments() throws {
        let model = TodayViewModel(observeChanges: false)
        model.pendingAttachments = [.file(FilePickerResult(filePath: "raw/assets/keep.pdf", fileName: "keep.pdf"))]
        try fm.createDirectory(at: tempDir.appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data("blocks journal directory".utf8).write(to: InflightDraftStore.directory)

        XCTAssertFalse(model.submitCombinedMemo(body: "keep in composer"))
        XCTAssertEqual(model.pendingAttachments.count, 1)
        XCTAssertTrue(model.memos.isEmpty)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertNotNil(model.submitError)
    }

    @MainActor
    func testAppendThenCrashBeforeAcknowledgementDoesNotOfferDuplicateRecovery() throws {
        let entry = try makeEntry(body: "already durable", paths: ["raw/assets/proof.jpg"])
        let memo = Memo(id: entry.draft.id, created: entry.draft.enqueuedAt,
                        attachments: [.init(file: "raw/assets/proof.jpg", kind: "photo")], body: entry.draft.body)
        try RawStorage.append(memo, vaultRoot: tempDir)
        let restarted = TodayViewModel(observeChanges: false)
        restarted.recoverInflightDrafts()

        XCTAssertTrue(restarted.recoverableDrafts.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: entry.url.path))
        XCTAssertEqual(try RawStorage.read(for: memo.created, vaultRoot: tempDir).map(\.id), [memo.id])
    }

    @MainActor
    func testDivergentCanonicalMemoRetainsDraftAndDoesNotStarveOthers() throws {
        let healthy = try makeEntry(body: "healthy", date: Date().addingTimeInterval(-60))
        let conflict = try makeEntry(body: "local unsaved variant")
        let canonical = Memo(id: conflict.draft.id, created: conflict.draft.enqueuedAt, body: "different saved variant")
        try RawStorage.append(canonical, vaultRoot: tempDir)
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()

        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), healthy.draft.body)
        XCTAssertTrue(fm.fileExists(atPath: conflict.url.path))
        XCTAssertEqual(try RawStorage.read(for: canonical.created, vaultRoot: tempDir).first?.body, canonical.body)
    }

    @MainActor
    func testConfirmedDiscardOnlyRemovesTheActiveRecovery() throws {
        let older = try makeEntry(body: "older kept", date: Date().addingTimeInterval(-60))
        let active = try makeEntry(body: "discard this")
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()
        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), active.draft.body)

        model.discardActiveInflightDraft()
        XCTAssertNil(model.activeRecoveryDraft)
        XCTAssertEqual(InflightDraftStore.pending().map(\.id), [older.draft.id])
    }

    func testRetryReusesRecordAndOldAcknowledgementCannotClearNewPayload() throws {
        let first = try makeEntry(body: "first attempt")
        var updated = first.draft
        updated.body = "edited retry"
        let latest = try InflightDraftStore.persist(updated, vaultRoot: tempDir)

        XCTAssertEqual(first.url, latest.url)
        XCTAssertEqual(InflightDraftStore.pending().count, 1)
        InflightDraftStore.acknowledge(first)
        XCTAssertEqual(InflightDraftStore.pending().first?.body, updated.body)
        InflightDraftStore.acknowledge(latest)
        XCTAssertTrue(InflightDraftStore.pending().isEmpty)
    }

    func testAcknowledgementKeepsCapturedVaultAfterLocatorSwitch() throws {
        let original = try makeEntry(body: "original vault")
        let otherRoot = tempDir.appendingPathComponent("other-vault", isDirectory: true)
        let other = try InflightDraftStore.persist(original.draft, vaultRoot: otherRoot)
        VaultInitializer.testOverrideURL = otherRoot

        InflightDraftStore.acknowledge(original)
        XCTAssertFalse(fm.fileExists(atPath: original.url.path))
        XCTAssertTrue(fm.fileExists(atPath: other.url.path))
        XCTAssertEqual(InflightDraftStore.pending(vaultRoot: otherRoot).count, 1)
    }

    @MainActor
    func testRecoveryRejectsVaultSwitchAndMixedAttachmentAfterSwitchingBack() throws {
        let original = try makeEntry(body: "original recovery")
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()
        XCTAssertEqual(model.restoreNextInflightDraft(composerBody: ""), original.draft.body)
        let otherRoot = tempDir.appendingPathComponent("other-vault", isDirectory: true)
        let newAssetPath = "raw/assets/new-in-other-vault.pdf"
        let newAssetURL = otherRoot.appendingPathComponent(newAssetPath)
        try fm.createDirectory(at: newAssetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new attachment".utf8).write(to: newAssetURL)
        VaultInitializer.testOverrideURL = otherRoot
        model.pendingAttachments.append(.file(FilePickerResult(filePath: newAssetPath, fileName: "new.pdf")))

        XCTAssertFalse(model.submitCombinedMemo(body: "edited recovery with new attachment"))
        VaultInitializer.testOverrideURL = tempDir
        XCTAssertFalse(model.submitCombinedMemo(body: "edited recovery after switching back"),
                       "An attachment staged in another vault must still reject submission after returning")
        XCTAssertEqual(model.activeRecoveryDraft, original)
        XCTAssertEqual(model.pendingAttachments.map { $0.attachment.file }, [newAssetPath])
        XCTAssertTrue(model.memos.isEmpty)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertNotNil(model.submitError)
        XCTAssertEqual(InflightDraftStore.pending(vaultRoot: tempDir), [original.draft])
        XCTAssertTrue(InflightDraftStore.pending(vaultRoot: otherRoot).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: RawStorage.fileURL(for: original.draft.enqueuedAt, vaultRoot: tempDir).path))
        XCTAssertFalse(fm.fileExists(atPath: RawStorage.fileURL(for: original.draft.enqueuedAt, vaultRoot: otherRoot).path))
        XCTAssertEqual(try Data(contentsOf: newAssetURL), Data("new attachment".utf8))
    }

    @MainActor
    func testRecoveryRejectsPhotoAndVoiceWithAnotherVaultOrigin() throws {
        let original = try makeEntry(body: "recovery with mixed origins")
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()
        XCTAssertNotNil(model.restoreNextInflightDraft(composerBody: ""))
        let otherRoot = tempDir.appendingPathComponent("other-vault", isDirectory: true)
        let photoPath = "raw/assets/other.jpg"
        let voicePath = "raw/assets/other.m4a"
        let attachments: [PendingAttachment] = [
            .photo(PhotoPickerResult(filePath: photoPath, fileURL: otherRoot.appendingPathComponent(photoPath), exif: nil, thumbnail: nil)),
            .voice(VoiceRecordingResult(filePath: voicePath, fileURL: otherRoot.appendingPathComponent(voicePath), duration: 1, transcript: nil))
        ]
        for attachment in attachments {
            model.pendingAttachments = [attachment]
            XCTAssertFalse(model.submitCombinedMemo(body: original.draft.body))
            XCTAssertEqual(model.pendingAttachments.first?.fileURL, attachment.fileURL)
            XCTAssertEqual(model.activeRecoveryDraft, original)
        }
        XCTAssertEqual(InflightDraftStore.pending(vaultRoot: tempDir), [original.draft])
        XCTAssertFalse(fm.fileExists(atPath: RawStorage.fileURL(for: original.draft.enqueuedAt, vaultRoot: tempDir).path))
    }

    @MainActor
    func testNewComposerRejectsAttachmentStagedBeforeVaultSwitch() throws {
        let originalRoot = try XCTUnwrap(tempDir)
        let assetPath = "raw/assets/original.pdf"
        let assetURL = originalRoot.appendingPathComponent(assetPath)
        try fm.createDirectory(at: assetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep original asset".utf8).write(to: assetURL)
        let model = TodayViewModel(observeChanges: false)
        model.pendingAttachments = [.file(FilePickerResult(filePath: assetPath, fileName: "original.pdf"))]
        let otherRoot = originalRoot.appendingPathComponent("other-vault", isDirectory: true)
        VaultInitializer.testOverrideURL = otherRoot

        XCTAssertFalse(model.submitCombinedMemo(body: "new draft with existing attachment"))
        XCTAssertEqual(model.pendingAttachments.first?.fileURL, assetURL)
        XCTAssertNil(model.activeRecoveryDraft)
        XCTAssertTrue(model.memos.isEmpty)
        XCTAssertFalse(model.isSubmitting)
        XCTAssertNotNil(model.submitError)
        XCTAssertTrue(InflightDraftStore.pending(vaultRoot: originalRoot).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: otherRoot.path), "Rejected submit must not create another vault or journal")
        XCTAssertEqual(try Data(contentsOf: assetURL), Data("keep original asset".utf8))
    }

    @MainActor
    func testRecoveryAcceptsSymlinkAliasForItsOriginalVault() async throws {
        let original = try makeEntry(body: "same vault through alias")
        let model = TodayViewModel(observeChanges: false)
        model.recoverInflightDrafts()
        let body = try XCTUnwrap(model.restoreNextInflightDraft(composerBody: ""))
        let alias = tempDir.appendingPathComponent("vault-alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: tempDir)
        VaultInitializer.testOverrideURL = alias

        XCTAssertTrue(model.submitCombinedMemo(body: body))
        await model.waitForSubmissionPersistence()
        XCTAssertFalse(fm.fileExists(atPath: original.url.path))
        XCTAssertEqual(try RawStorage.read(for: original.draft.enqueuedAt, vaultRoot: tempDir).map(\.id), [original.draft.id])
    }

    func testLegacyFourFieldJSONRemainsReadable() throws {
        let id = UUID()
        let legacy = """
        {"id":"\(id.uuidString)","body":"legacy body","enqueuedAt":"2026-09-20T09:00:00Z","attachmentPaths":["raw/assets/legacy.m4a"]}
        """
        try fm.createDirectory(at: InflightDraftStore.directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: InflightDraftStore.fileURL(for: id, vaultRoot: tempDir))
        let decoded = try XCTUnwrap(InflightDraftStore.pending().first)
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.body, "legacy body")
        XCTAssertEqual(decoded.attachmentPaths, ["raw/assets/legacy.m4a"])
    }

    private func makeEntry(body: String, paths: [String] = [], date: Date = Date()) throws -> InflightDraftEntry {
        // The existing ISO-8601 journal stores whole seconds. Match that durable
        // precision so full-payload assertions compare the same persisted value.
        let persistedDate = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
        return try InflightDraftStore.persist(
            InflightDraft(id: UUID(), body: body, enqueuedAt: persistedDate, attachmentPaths: paths),
            vaultRoot: tempDir
        )
    }
}
