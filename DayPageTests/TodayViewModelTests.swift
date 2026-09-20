import Testing
import Foundation
import DayPageModels
import DayPageStorage
import DayPageServices
@testable import DayPage

/// US-020: Unit tests for TodayViewModel core paths: addMemo, deleteMemo, toggleFavorite (pin/unpin).
///
/// TodayViewModel reads/writes via RawStorage which uses VaultInitializer.testOverrideURL.
/// Tests run synchronously by directly mutating `memos` and calling the view model methods,
/// bypassing the async submission path that requires live services (Location, Weather).
///
/// Serialized + @MainActor because TodayViewModel is @MainActor-isolated and tests
/// share the global `VaultInitializer.testOverrideURL`.
@MainActor
@Suite("TodayViewModelTests", .serialized)
struct TodayViewModelTests {

    private let tempDir: URL
    private let vm: TodayViewModel

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayVMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        VaultInitializer.testOverrideURL = tempDir
        vm = TodayViewModel(date: Date(), observeChanges: false)
    }

    private func cleanup() {
        VaultInitializer.testOverrideURL = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - addMemo (via RawStorage.append + in-memory insert)

    @Test func addMemo_insertsIntoMemosArray() throws {
        defer { cleanup() }
        let memo = makeMemo(body: "test memo body")
        try RawStorage.append(memo)
        // Simulate the in-memory update that submitCombinedMemo performs
        vm.memos.insert(memo, at: 0)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == memo.id)
        #expect(vm.memos.first?.body == "test memo body")
    }

    @Test func addMemo_multipleMemosOrderedNewestFirst() throws {
        defer { cleanup() }
        let older = makeMemo(body: "older", created: Date(timeIntervalSinceNow: -120))
        let newer = makeMemo(body: "newer", created: Date(timeIntervalSinceNow: -60))
        try RawStorage.append(older)
        try RawStorage.append(newer)

        // Simulate load sort (newest first)
        vm.memos = [newer, older]

        #expect(vm.memos.first?.body == "newer")
        #expect(vm.memos.last?.body == "older")
    }

    // MARK: - deleteMemo

    @Test func deleteMemo_removesMemoFromMemosArray() async throws {
        defer { cleanup() }
        let m1 = makeMemo(body: "keep me")
        let m2 = makeMemo(body: "delete me")
        try RawStorage.append(m1)
        try RawStorage.append(m2)
        vm.memos = [m1, m2]

        vm.deleteMemo(m2)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == m1.id)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: m1.created, vaultRoot: tempDir).map(\.id) == [m1.id])
    }

    @Test func deleteMemo_setsLastDeletedMemo() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "will be deleted")
        try RawStorage.append(memo)
        vm.memos = [memo]

        vm.deleteMemo(memo)

        #expect(vm.lastDeletedMemo?.id == memo.id)
        await vm.waitForMemoPersistence()
    }

    @Test func undoDelete_restoresMemo() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "restore me")
        try RawStorage.append(memo)
        vm.memos = [memo]

        vm.deleteMemo(memo)
        #expect(vm.memos.count == 0)

        vm.undoDelete()
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.id == memo.id)
        #expect(vm.lastDeletedMemo == nil)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: memo.created, vaultRoot: tempDir).map(\.id) == [memo.id])
    }

    // MARK: - toggleFavorite (pin / unpin)

    @Test func pinMemo_setsPinnedAtAndMovesToTop() async throws {
        defer { cleanup() }
        let m1 = makeMemo(body: "first", created: Date(timeIntervalSinceNow: -60))
        let m2 = makeMemo(body: "second", created: Date())
        try RawStorage.append(m1)
        try RawStorage.append(m2)
        vm.memos = [m2, m1] // newest first

        vm.pinMemo(m1)

        #expect(vm.memos.first?.pinnedAt != nil, "Pinned memo must have pinnedAt set")
        #expect(vm.memos.first?.id == m1.id, "Pinned memo must move to top")
        await vm.waitForMemoPersistence()
    }

    @Test func unpinMemo_clearsPinnedAtAndResortsByCreated() async throws {
        defer { cleanup() }
        var pinned = makeMemo(body: "pinned", created: Date(timeIntervalSinceNow: -60))
        pinned.pinnedAt = Date()
        let normal = makeMemo(body: "normal", created: Date())
        try RawStorage.append(pinned)
        try RawStorage.append(normal)
        vm.memos = [pinned, normal]

        vm.unpinMemo(pinned)

        #expect(vm.memos.first(where: { $0.id == pinned.id })?.pinnedAt == nil,
                "Unpinned memo must have nil pinnedAt")
        // After unpin, normal (newer) should be first
        #expect(vm.memos.first?.id == normal.id)
        await vm.waitForMemoPersistence()
    }

    @Test func pinMemo_onlyOneMemoInList() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "solo")
        try RawStorage.append(memo)
        vm.memos = [memo]

        vm.pinMemo(memo)

        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.pinnedAt != nil)
        await vm.waitForMemoPersistence()
    }

    // MARK: - submitCombinedMemo (optimistic commit + durable persist)

    /// 落盘先于加载：the memo must appear in `memos` on the SAME synchronous turn
    /// the user taps send — no awaiting location/weather first — and must still
    /// land on disk afterward via the background durable-write task.
    @Test func submitCombinedMemo_insertsOptimisticallyThenPersists() async throws {
        defer { cleanup() }
        #expect(vm.memos.isEmpty)

        vm.submitCombinedMemo(body: "optimistic hello")

        // Optimistic insert + composer reset happen synchronously — the user
        // perceives the memo immediately, before any GPS/weather await.
        #expect(vm.memos.count == 1)
        #expect(vm.memos.first?.body == "optimistic hello")
        #expect(vm.isSubmitting == false)
        #expect(vm.pendingAttachments.isEmpty)

        // The durable append runs off-main; await its explicit completion so
        // the next test cannot switch the global isolated-vault override while
        // this task is still writing.
        await vm.waitForSubmissionPersistence()
        let persisted = (try? RawStorage.read(for: Date(), vaultRoot: tempDir)) ?? []
        #expect(persisted.contains { $0.body == "optimistic hello" })
    }

    /// An empty submit with no attachments is a no-op — no ghost card, no write.
    @Test func submitCombinedMemo_emptyBodyNoAttachments_isNoOp() {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "   \n  ")
        #expect(vm.memos.isEmpty)
        #expect(vm.isSubmitting == false)
    }

    @Test func undoLastSubmission_removesMemoAndRestoresDraftPayload() async throws {
        defer { cleanup() }

        vm.submitCombinedMemo(body: "bring this back")
        #expect(vm.memos.count == 1)

        let restoredBody = vm.undoLastSubmission()
        #expect(restoredBody == "bring this back")
        #expect(vm.memos.isEmpty, "Undo must remove the optimistic card, not merely copy its text")

        // The undo is ordered after the in-flight append, then removes the
        // exact memo id atomically. Await that storage pipeline before reading.
        await vm.waitForSubmissionUndo()
        let persisted = (try? RawStorage.read(for: Date(), vaultRoot: tempDir)) ?? []

        #expect(persisted.isEmpty, "Undo send must remove the committed memo from disk")
    }

    // MARK: - signalCount

    @Test func pinFromStaleListPreservesBackgroundMemoAndItsOutbox() async throws {
        defer { cleanup() }
        let original = makeMemo(body: "original")
        try RawStorage.append(original)
        vm.memos = [original]
        let background = makeMemo(body: "background")
        try RawStorage.append(background)
        vm.pinMemo(original)
        await vm.waitForMemoPersistence()
        let actual = try RawStorage.read(for: original.created, vaultRoot: tempDir)
        #expect(actual.count == 2)
        #expect(actual.first { $0.id == original.id }?.pinnedAt != nil)
        #expect(actual.contains { $0.id == background.id })
        #expect(try SyncOutboxStore.pendingOperation(for: background.id)?.kind != .delete)
    }

    @Test func immediateSubmitEditPinUnpinDeleteUndoIsOrdered() async throws {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "initial")
        let memo = try #require(vm.memos.first)
        vm.update(memo: memo, body: "edited")
        vm.pinMemo(memo)
        vm.unpinMemo(memo)
        let edited = try #require(vm.memos.first)
        vm.deleteMemo(edited)
        vm.undoDelete()
        await vm.waitForMemoPersistence()
        await vm.waitForSubmissionPersistence()
        let actual = try RawStorage.read(for: memo.created, vaultRoot: tempDir)
        #expect(actual.count == 1)
        #expect(actual.first?.body == "edited")
        #expect(actual.first?.pinnedAt == nil)
        #expect(vm.submitError == nil)
    }

    @Test func rapidSubmissionsAndMutationKeepEveryRecord() async throws {
        defer { cleanup() }
        vm.submitCombinedMemo(body: "first")
        let first = try #require(vm.memos.first)
        vm.submitCombinedMemo(body: "second")
        vm.pinMemo(first)
        vm.submitCombinedMemo(body: "third")
        await vm.waitForMemoPersistence()
        await vm.waitForSubmissionPersistence()
        let actual = try RawStorage.read(for: first.created, vaultRoot: tempDir)
        #expect(Set(actual.map(\.body)) == ["first", "second", "third"])
        #expect(actual.first { $0.id == first.id }?.pinnedAt != nil)
    }

    @Test func queuedMutationRetainsVaultEvenIfLocatorChanges() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "captured root")
        try RawStorage.append(memo, vaultRoot: tempDir)
        vm.memos = [memo]
        vm.pinMemo(memo)
        let other = tempDir.appendingPathComponent("other-vault")
        VaultInitializer.testOverrideURL = other
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: memo.created, vaultRoot: tempDir).first?.pinnedAt != nil)
        #expect(!FileManager.default.fileExists(atPath: RawStorage.fileURL(for: memo.created, vaultRoot: other).path))
    }

    @Test func completedTranscriptPreservesLatestBodyOtherAttachmentsAndBackgroundMemo() async throws {
        defer { cleanup() }
        var stale = makeMemo(body: "old body")
        stale.attachments = [.init(file: "raw/assets/voice.m4a", kind: "audio", duration: 2, transcriptionStatus: .failed)]
        try RawStorage.append(stale)
        vm.memos = [stale]
        try RawStorage.mutate(for: stale.created, vaultRoot: tempDir) { current in
            var updated = current
            updated[0].body = "concurrent body"
            updated[0].attachments[0].duration = 4
            updated[0].attachments.append(.init(file: "raw/assets/new.pdf", kind: "file"))
            return updated
        }
        let sibling = makeMemo(body: "concurrent append")
        try RawStorage.append(sibling)
        vm.updateTranscript("new transcript", memo: stale, attachmentFile: stale.attachments[0].file, vaultRoot: tempDir)
        await vm.waitForMemoPersistence()
        let actual = try RawStorage.read(for: stale.created, vaultRoot: tempDir)
        let updated = try #require(actual.first { $0.id == stale.id })
        #expect(actual.count == 2)
        #expect(updated.body == "concurrent body")
        #expect(updated.attachments.count == 2)
        #expect(updated.attachments[0].duration == 4)
        #expect(updated.attachments[0].transcript == "new transcript")
        #expect(updated.attachments[0].transcriptionStatus == .done)
    }

    @Test func failedOldMutationDoesNotRestoreStaleSnapshotOverNewSubmit() async throws {
        defer { cleanup() }
        // A deleted-elsewhere memo exists only in the stale UI snapshot.
        let missing = makeMemo(body: "deleted elsewhere")
        vm.memos = [missing]
        vm.pinMemo(missing)
        vm.submitCombinedMemo(body: "must survive failed pin")
        await vm.waitForMemoPersistence()
        await vm.waitForSubmissionPersistence()
        let actual = try RawStorage.read(for: missing.created, vaultRoot: tempDir)
        #expect(actual.map(\.body) == ["must survive failed pin"])
        #expect(vm.memos.contains { $0.body == "must survive failed pin" })
        #expect(!vm.memos.contains { $0.id == missing.id })
        #expect(vm.submitError != nil)
    }

    @Test func deleteUndoRestoresLatestPersistedRecordInsteadOfStaleCard() async throws {
        defer { cleanup() }
        let stale = makeMemo(body: "old card")
        try RawStorage.append(stale)
        vm.memos = [stale]
        try RawStorage.mutate(for: stale.created, vaultRoot: tempDir) { current in
            var updated = current
            updated[0].body = "new background edit"
            updated[0].attachments = [.init(file: "raw/assets/background.pdf", kind: "file")]
            return updated
        }
        vm.deleteMemo(stale)
        vm.undoDelete()
        await vm.waitForMemoPersistence()
        let restored = try #require(try RawStorage.read(for: stale.created, vaultRoot: tempDir).first)
        #expect(restored.body == "new background edit")
        #expect(restored.attachments.count == 1)
    }

    @Test func successfulNoOpMutationCompletesInterruptedLoad() async throws {
        defer { cleanup() }
        let missing = makeMemo(body: "already removed")
        vm.load()
        vm.updateTranscript("late transcript", memo: missing, attachmentFile: "raw/assets/removed.m4a", vaultRoot: tempDir)
        await vm.waitForMemoPersistence()
        #expect(vm.loadState == .ready)
        #expect(vm.memos.isEmpty)
    }

    @Test func deleteUndoAfterVaultSwitchDoesNotInsertOldVaultCardInCurrentList() async throws {
        defer { cleanup() }
        let memo = makeMemo(body: "old vault")
        try RawStorage.append(memo, vaultRoot: tempDir)
        vm.memos = [memo]
        vm.deleteMemo(memo)
        let other = tempDir.appendingPathComponent("new-vault")
        VaultInitializer.testOverrideURL = other
        vm.memos = []
        vm.undoDelete()
        #expect(vm.memos.isEmpty)
        await vm.waitForMemoPersistence()
        #expect(try RawStorage.read(for: memo.created, vaultRoot: tempDir).map(\.id) == [memo.id])
        #expect(vm.memos.isEmpty)
    }

    @Test func unpinKeepsRemainingPinnedMemoAheadOfNewerUnpinnedMemo() async throws {
        defer { cleanup() }
        var pinned = makeMemo(body: "still pinned", created: Date(timeIntervalSinceNow: -600))
        pinned.pinnedAt = Date(timeIntervalSinceNow: -30)
        var unpin = makeMemo(body: "unpin newest")
        unpin.pinnedAt = Date()
        try RawStorage.append(pinned)
        try RawStorage.append(unpin)
        vm.memos = [unpin, pinned]
        vm.unpinMemo(unpin)
        #expect(vm.memos.first?.id == pinned.id)
        await vm.waitForMemoPersistence()
    }

    @Test func signalCount_matchesMemoCount() {
        defer { cleanup() }
        vm.memos = [makeMemo(body: "a"), makeMemo(body: "b"), makeMemo(body: "c")]
        #expect(vm.signalCount == 3)
    }

    // MARK: - Helpers

    private func makeMemo(body: String, created: Date = Date()) -> Memo {
        Memo(
            id: UUID(),
            type: .text,
            created: created,
            body: body
        )
    }
}
