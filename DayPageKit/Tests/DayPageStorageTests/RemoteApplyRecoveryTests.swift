import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

final class RemoteApplyRecoveryTests: XCTestCase {
    private enum Interruption: Error { case simulatedTermination }
    private enum ChangeKind: CaseIterable { case edit, delete, move, media }

    func testEveryDurableBoundaryPreservesLocalVersionAndReplaysOnce() throws {
        try exerciseInterruptions(reconcileBeforeReplay: false)
    }

    func testStartupReconciliationDoesNotDuplicatePreservedConflicts() throws {
        try exerciseInterruptions(reconcileBeforeReplay: true)
    }

    func testEquivalentVaultURLRepresentationsDoNotDeleteCanonicalDestination() throws {
        try withVault { vault in
            let alias = vault.appendingPathComponent("vault-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: vault)
            let roots = [URL(fileURLWithPath: ".", isDirectory: true, relativeTo: vault), alias]
            for root in roots {
                VaultInitializer.testOverrideURL = root
                let local = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "equivalent file URL")
                let remote = change(for: local, kind: .edit)
                _ = try RawStorage.applyRemoteChanges([remote])
                XCTAssertEqual(try RawStorage.read(for: local.created, vaultRoot: vault)
                    .first(where: { $0.id == local.id })?.body, remote.body)
            }
            XCTAssertTrue(try SyncOutboxStore.pendingOperations().isEmpty)
        }
    }

    func testSubmillisecondRemoteDateDoesNotCreateASecondConflictOnReplay() throws {
        try withVault { vault in
            let local = Memo(created: Date(timeIntervalSince1970: 1_787_500_800.123456), body: "local precision case")
            try seed(local, in: vault)
            let pending = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: local.id))
            let remote = change(for: local, kind: .edit, body: "\nremote canonical version\n\n")
            XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: {
                if $0 == .canonicalMemo { throw Interruption.simulatedTermination }
            }))
            try SyncOutboxStore.reconcileVault()
            _ = try RawStorage.applyRemoteChanges([remote])
            try SyncOutboxStore.reconcileVault()

            XCTAssertEqual(try allMemos(vault).count, 2)
            XCTAssertEqual(try SyncOutboxStore.pendingOperations().map(\.memoID), [pending.operationID])
        }
    }

    func testConflictCopyWriteFailureLeavesCanonicalAndOutboxUntouched() throws {
        try withVault { vault in
            let local = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "local")
            try seed(local, in: vault)
            let originalOperation = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: local.id))
            let rawFile = RawStorage.fileURL(for: local.created)
            let originalBytes = try Data(contentsOf: rawFile)
            // A real filesystem failure, before any durable replacement. File
            // protection is deterministic even when the test user owns it.
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: rawFile.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: rawFile.path) }

            XCTAssertThrowsError(try RawStorage.applyRemoteChanges([change(for: local, kind: .edit)]))
            XCTAssertEqual(try Data(contentsOf: rawFile), originalBytes)
            XCTAssertEqual(try SyncOutboxStore.pendingOperation(for: local.id), originalOperation)
        }
    }

    func testRetryDoesNotOverwriteAnAlreadyPreservedCopy() throws {
        try withVault { vault in
            let local = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "local before crash")
            try seed(local, in: vault)
            let pending = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: local.id))
            let remote = change(for: local, kind: .edit)
            XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: { stage in
                if stage == .conflictCopy { throw Interruption.simulatedTermination }
            }))
            var memos = try RawStorage.read(for: local.created)
            let index = try XCTUnwrap(memos.firstIndex(where: { $0.id == pending.operationID }))
            memos[index].body = "user amended preserved copy"
            try RawStorage.atomicWrite(string: RawStorage.serialize(memos), to: RawStorage.fileURL(for: local.created))

            _ = try RawStorage.applyRemoteChanges([remote])

            let result = try RawStorage.read(for: local.created)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.first(where: { $0.id == pending.operationID })?.body, "user amended preserved copy")
            XCTAssertEqual(try SyncOutboxStore.pendingOperation(for: pending.operationID)?.payload?.body,
                           "user amended preserved copy")
        }
    }

    func testOutboxIOFailuresPreserveLocalContentBeforeAndAfterCanonicalWrite() throws {
        for failAfterCanonicalWrite in [false, true] {
            try withVault { vault in
                let local = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "local awaiting conflict sync")
                try seed(local, in: vault)
                let pending = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: local.id))
                let outbox = SyncOutboxStore.outboxURL
                let remote = change(for: local, kind: .edit)
                defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: outbox.path) }
                XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: { stage in
                    if stage == (failAfterCanonicalWrite ? .canonicalMemo : .conflictCopy) {
                        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: outbox.path)
                    }
                }))
                XCTAssertEqual(try SyncOutboxStore.pendingOperation(for: local.id), pending)
                XCTAssertEqual(try allMemos(vault).first(where: { $0.id == pending.operationID })?.body, local.body)
                XCTAssertEqual(try allMemos(vault).first(where: { $0.id == local.id })?.body,
                               failAfterCanonicalWrite ? remote.body : local.body)

                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: outbox.path)
                _ = try RawStorage.applyRemoteChanges([remote])
                XCTAssertEqual(try allMemos(vault).count, 2)
                XCTAssertEqual(try SyncOutboxStore.pendingOperations().map(\.memoID), [pending.operationID])
            }
        }
    }

    func testStaleOrMissingPendingOperationCannotHideANewerRawEdit() throws {
        for alreadyAcknowledged in [false, true] {
            try withVault { vault in
                let original = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "old acknowledged body")
                try seed(original, in: vault)
                let originalOperation = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: original.id))
                if alreadyAcknowledged { try SyncOutboxStore.acknowledge(operationID: originalOperation.operationID) }
                var current = original
                current.body = "new raw body whose outbox write failed"
                try writeRawWithFailedOutbox(current)
                let remote = change(for: original, kind: .edit, body: original.body, contentHash: originalOperation.contentHash)

                let result = try RawStorage.applyRemoteChanges([remote])

                let copyID = try XCTUnwrap(result.conflictCopies.first)
                XCTAssertEqual(try allMemos(vault).first(where: { $0.id == copyID })?.body, current.body)
                XCTAssertEqual(try allMemos(vault).first(where: { $0.id == original.id })?.body, original.body)
                XCTAssertEqual(try SyncOutboxStore.pendingOperation(for: copyID)?.payload?.body, current.body)
            }
        }
    }

    func testAnotherRawEditAfterInterruptedCopyGetsItsOwnPreservedVersion() throws {
        try withVault { vault in
            let original = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "first local version")
            try seed(original, in: vault)
            let firstOperation = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: original.id))
            let remote = change(for: original, kind: .edit)
            XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: {
                if $0 == .conflictCopy { throw Interruption.simulatedTermination }
            }))
            var current = original
            current.body = "second local version after interrupted copy"
            try writeRawWithFailedOutbox(current)

            _ = try RawStorage.applyRemoteChanges([remote])
            try SyncOutboxStore.reconcileVault()
            _ = try RawStorage.applyRemoteChanges([remote])

            let final = try allMemos(vault)
            XCTAssertEqual(final.count, 3)
            XCTAssertEqual(final.first(where: { $0.id == firstOperation.operationID })?.body, original.body)
            XCTAssertTrue(final.contains { $0.body == current.body })
            XCTAssertEqual(Set(try SyncOutboxStore.pendingOperations().compactMap { $0.payload?.body }),
                           Set([original.body, current.body]))
        }
    }

    func testFailedLocalOutboxRepairDoesNotTouchCanonicalFile() throws {
        try withVault { vault in
            let original = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "raw edit remains local")
            try seed(original, in: vault)
            let file = RawStorage.fileURL(for: original.created)
            let bytes = try Data(contentsOf: file)
            let outbox = SyncOutboxStore.outboxURL
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: outbox.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: outbox.path) }

            XCTAssertThrowsError(try RawStorage.applyRemoteChanges([change(for: original, kind: .edit)]))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testLegacyRecordsAndBrokenBlockRemainRecoverableDuringConflict() throws {
        try withVault { vault in
            let date = Date(timeIntervalSince1970: 1_787_500_800)
            let local = Memo(created: date, body: "local legacy body")
            let neighbour = Memo(created: date.addingTimeInterval(1), body: "independent legacy memo")
            let file = RawStorage.fileURL(for: date)
            let legacy = [local.toMarkdown(), neighbour.toMarkdown()].joined(separator: RawStorage.legacyMemoSeparator)
            try RawStorage.atomicWrite(string: legacy, to: file)
            XCTAssertEqual(Set(try RawStorage.read(for: date).map(\.id)), Set([local.id, neighbour.id]))
            try SyncOutboxStore.recordUpsert(local, vaultPath: "raw/\(file.lastPathComponent)")
            let conflictID = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: local.id)?.operationID)

            // A malformed modern block must be quarantined before the rewrite.
            let broken = "---\nid: invalid-uuid\n---\nSYNTHETIC_UNPARSEABLE_BYTES"
            try RawStorage.atomicWrite(
                string: RawStorage.serialize(try RawStorage.read(for: date)) + RawStorage.memoSeparator + broken,
                to: file
            )
            _ = try RawStorage.applyRemoteChanges([change(for: local, kind: .edit)])

            let onDisk = try String(contentsOf: file, encoding: .utf8)
            let result = RawStorage.parse(fileContent: onDisk)
            XCTAssertEqual(result.first(where: { $0.id == conflictID })?.body, local.body)
            XCTAssertEqual(result.first(where: { $0.id == neighbour.id })?.body, neighbour.body)
            XCTAssertTrue(onDisk.contains(RawStorage.memoSeparator))
            let quarantined = try FileManager.default.contentsOfDirectory(
                at: vault.appendingPathComponent("raw/.broken"), includingPropertiesForKeys: nil
            )
            XCTAssertEqual(quarantined.count, 1)
            XCTAssertTrue(try String(contentsOf: XCTUnwrap(quarantined.first), encoding: .utf8).contains(broken))
        }
    }

    func testInterruptedMoveWithoutLocalConflictRetainsLegacyAttachmentMetadata() throws {
        let stages: [RawStorage.RemoteApplyWriteStage] = [.canonicalMemo, .canonicalRemoval]
        for stage in stages {
            try withVault { vault in
                var local = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "previous remote version")
                local.attachments = [.init(file: "raw/assets/legacy-local.png", kind: "photo")]
                local.mood = "calm"
                let file = RawStorage.fileURL(for: local.created)
                try RawStorage.atomicWrite(string: local.toMarkdown(), to: file)
                try SyncOutboxStore.acceptRemoteChange(memo: local, memoID: local.id, remoteRevision: 1, deleted: false)
                let remote = change(for: local, kind: .move)

                XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: {
                    if $0 == stage { throw Interruption.simulatedTermination }
                }))
                try SyncOutboxStore.reconcileVault()
                _ = try RawStorage.applyRemoteChanges([remote])

                let final = try allMemos(vault)
                // An interrupted move with two raw copies cannot prove that
                // the source is unchanged; preserving one old version is the
                // deliberate conservative recovery policy.
                XCTAssertEqual(final.count, stage == .canonicalMemo ? 2 : 1)
                let canonical = try XCTUnwrap(final.first { $0.id == local.id })
                XCTAssertEqual(canonical.created, remote.createdAt)
                XCTAssertEqual(canonical.body, remote.body)
                XCTAssertEqual(canonical.attachments, local.attachments)
                XCTAssertEqual(canonical.mood, local.mood)
                XCTAssertEqual(try SyncOutboxStore.pendingOperations().count, stage == .canonicalMemo ? 1 : 0)
            }
        }
    }

    func testSourceEditedAfterInterruptedMoveIsPreservedBeforeDuplicateCleanup() throws {
        for hadPendingLocalEdit in [false, true] {
            try withVault { vault in
                let original = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "original source version")
                try seed(original, in: vault)
                if !hadPendingLocalEdit {
                    let operation = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: original.id))
                    try SyncOutboxStore.acknowledge(operationID: operation.operationID)
                }
                let remote = change(for: original, kind: .move)
                XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: {
                    if $0 == .canonicalMemo { throw Interruption.simulatedTermination }
                }))
                var editedSource = original
                editedSource.body = "source changed while interrupted destination was present"
                try writeRawWithFailedOutbox(editedSource)

                _ = try RawStorage.applyRemoteChanges([remote])
                try SyncOutboxStore.reconcileVault()
                _ = try RawStorage.applyRemoteChanges([remote])

                let final = try allMemos(vault)
                XCTAssertEqual(final.count, hadPendingLocalEdit ? 3 : 2)
                XCTAssertEqual(final.first(where: { $0.id == original.id })?.body, remote.body)
                let preserved = try XCTUnwrap(final.first { $0.body == editedSource.body })
                XCTAssertNotEqual(preserved.id, original.id)
                XCTAssertEqual(try SyncOutboxStore.pendingOperation(for: preserved.id)?.payload?.body, editedSource.body)
            }
        }
    }

    func testBothLocationsEditedAfterInterruptedMoveArePreserved() throws {
        try withVault { vault in
            let original = Memo(created: Date(timeIntervalSince1970: 1_787_500_800), body: "original source version")
            try seed(original, in: vault)
            let operation = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: original.id))
            try SyncOutboxStore.acknowledge(operationID: operation.operationID)
            let remote = change(for: original, kind: .move)
            XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: {
                if $0 == .canonicalMemo { throw Interruption.simulatedTermination }
            }))
            var source = original
            source.body = "edited old source"
            try writeRawWithFailedOutbox(source)
            var destination = remote.makeMemo()
            destination.body = "edited new destination"
            try writeRawWithFailedOutbox(destination)

            _ = try RawStorage.applyRemoteChanges([remote])
            try SyncOutboxStore.reconcileVault()
            _ = try RawStorage.applyRemoteChanges([remote])

            XCTAssertEqual(Set(try allMemos(vault).map(\.body)), Set([source.body, destination.body, remote.body]))
            XCTAssertEqual(try allMemos(vault).count, 3)
        }
    }

    private func exerciseInterruptions(reconcileBeforeReplay: Bool) throws {
        for kind in ChangeKind.allCases {
            let stages: [RawStorage.RemoteApplyWriteStage] = [.localOutbox, .conflictCopy, .conflictOutbox]
                + (kind == .delete ? [.canonicalRemoval] : kind == .move ? [.canonicalRemoval, .canonicalMemo] : [.canonicalMemo])
                + [.remoteAcknowledgement]
            for interruptedStage in stages {
                try withVault { vault in
                    let created = Date(timeIntervalSince1970: 1_787_500_800)
                    var local = Memo(created: created, body: "local version\n\n---\n\nretain all bytes")
                    local.attachments = [Memo.Attachment(file: "raw/assets/local.png", kind: "photo")]
                    try seed(local, in: vault)
                    let pending = try XCTUnwrap(SyncOutboxStore.pendingOperation(for: local.id))
                    let remote = change(for: local, kind: kind)
                    var interrupted = false

                    XCTAssertThrowsError(try RawStorage.applyRemoteChanges([remote], afterWrite: { stage in
                        if stage == interruptedStage {
                            interrupted = true
                            throw Interruption.simulatedTermination
                        }
                    }), "\(kind), \(interruptedStage)")
                    XCTAssertTrue(interrupted, "boundary must actually be reached")
                    XCTAssertTrue(try allMemos(vault).contains {
                        $0.body == local.body && $0.attachments == local.attachments
                    }, "local content must survive \(kind), \(interruptedStage)")

                    // There is no process-local recovery state: every operation
                    // below reconstructs its state from the raw/outbox files.
                    VaultInitializer.testOverrideURL = nil
                    VaultInitializer.testOverrideURL = vault
                    if reconcileBeforeReplay { try SyncOutboxStore.reconcileVault() }
                    _ = try RawStorage.applyRemoteChanges([remote])
                    _ = try RawStorage.applyRemoteChanges([remote])

                    let final = try allMemos(vault)
                    XCTAssertEqual(final.count, kind == .delete ? 1 : 2, "\(kind), \(interruptedStage)")
                    let preserved = try XCTUnwrap(final.first { $0.id == pending.operationID })
                    XCTAssertEqual(preserved.body, local.body)
                    XCTAssertEqual(preserved.attachments, local.attachments)
                    XCTAssertEqual(final.first(where: { $0.id == local.id })?.body,
                                   kind == .delete ? nil : remote.body)
                    if kind != .delete && kind != .media {
                        XCTAssertEqual(final.first(where: { $0.id == local.id })?.attachments, local.attachments)
                    }
                    let outbox = try SyncOutboxStore.pendingOperations()
                    XCTAssertEqual(outbox.map(\.memoID), [preserved.id])
                    XCTAssertEqual(outbox.first?.payload?.body, local.body)
                    XCTAssertEqual(outbox.first?.revision, 1, "replay cannot create another conflict revision")
                }
            }
        }
    }

    private func withVault(_ test: (URL) throws -> Void) throws {
        let base = ProcessInfo.processInfo.environment["DAYPAGE_TEST_VAULT_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let vault = base.appendingPathComponent("remote-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let previousOverride = VaultInitializer.testOverrideURL
        VaultInitializer.testOverrideURL = vault
        defer {
            VaultInitializer.testOverrideURL = previousOverride
            try? FileManager.default.removeItem(at: vault)
        }
        try test(vault)
    }

    private func seed(_ memo: Memo, in vault: URL) throws {
        let file = RawStorage.fileURL(for: memo.created, vaultRoot: vault)
        try RawStorage.atomicWrite(string: memo.toMarkdown(), to: file)
        try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/\(file.lastPathComponent)", vaultRoot: vault)
    }

    private func writeRawWithFailedOutbox(_ memo: Memo) throws {
        let file = RawStorage.fileURL(for: memo.created)
        var memos = try RawStorage.read(for: memo.created).filter { $0.id != memo.id }
        memos.append(memo)
        try RawStorage.atomicWrite(string: RawStorage.serialize(memos), to: file)
        let outbox = SyncOutboxStore.outboxURL
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: outbox.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: outbox.path) }
        XCTAssertThrowsError(try SyncOutboxStore.recordUpsert(memo, vaultPath: "raw/\(file.lastPathComponent)"))
    }

    private func allMemos(_ vault: URL) throws -> [Memo] {
        try FileManager.default.contentsOfDirectory(at: vault.appendingPathComponent("raw"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .flatMap { file in RawStorage.parse(fileContent: try String(contentsOf: file, encoding: .utf8), sourceFile: file) }
    }

    private func change(
        for local: Memo,
        kind: ChangeKind,
        body: String = "remote canonical version",
        contentHash: String? = "remote-hash"
    ) -> SyncRemoteChange {
        let hash = String(repeating: "a", count: 64)
        let attachment = SyncAttachmentDescriptor(
            position: 0, kind: "photo", contentSHA256: hash, sizeBytes: 8, mimeType: "image/png",
            objectKey: "11111111-1111-4111-8111-111111111111/\(local.id.uuidString.lowercased())/\(hash).png",
            originalFilename: "remote.png"
        )
        return SyncRemoteChange(
            id: local.id, type: "text", body: body,
            createdAt: kind == .move ? local.created.addingTimeInterval(86_400) : local.created,
            pinnedAt: nil, location: nil, weather: nil, device: nil, source: "ios", vaultPath: nil,
            sourceModifiedAt: local.created.addingTimeInterval(30), contentHash: contentHash, syncRevision: 2,
            lastSyncDeviceId: "remote-device", deletedAt: kind == .delete ? local.created.addingTimeInterval(30) : nil,
            changeSequence: 2, attachmentManifestHash: kind == .media ? AttachmentManifest.hash([attachment]) : nil,
            attachments: kind == .media ? [attachment] : nil
        )
    }
}
