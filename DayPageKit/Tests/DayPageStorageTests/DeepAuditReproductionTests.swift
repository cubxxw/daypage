import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

/// Regression for the stale-list overwrite discovered during the iOS audit.
/// Uses the same ID-based storage boundary as Today, with a deliberate
/// background append between list load and pin. Native tests cover scheduling.
final class DeepAuditReproductionTests: XCTestCase {
    private var temporaryVault: URL?
    private var previousVaultOverride: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousVaultOverride = VaultInitializer.testOverrideURL
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-deep-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
        temporaryVault = vault
        VaultInitializer.testOverrideURL = vault
    }

    override func tearDownWithError() throws {
        VaultInitializer.testOverrideURL = previousVaultOverride
        if let temporaryVault {
            try FileManager.default.removeItem(at: temporaryVault)
        }
        try super.tearDownWithError()
    }

    func testStalePinSnapshotMustPreserveBackgroundAppendAndNotEmitDelete() async throws {
        let vault = try XCTUnwrap(temporaryVault)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_789_862_400))
            .addingTimeInterval(12 * 60 * 60)
        let original = Memo(id: UUID(), created: day, body: "audit-original-memo")
        let backgroundMemo = Memo(
            id: UUID(),
            created: day.addingTimeInterval(60),
            body: "audit-background-append-must-survive"
        )

        try RawStorage.append(original, vaultRoot: vault)
        // Today holds this in-memory snapshot before a background writer lands.
        var staleSnapshot = try RawStorage.read(for: day, vaultRoot: vault)
        XCTAssertEqual(staleSnapshot.map(\.id), [original.id])

        try RawStorage.append(backgroundMemo, vaultRoot: vault)
        XCTAssertEqual(try RawStorage.read(for: day, vaultRoot: vault).count, 2)

        // The UI still owns an old snapshot, but persists only the intended
        // field on its target ID instead of replacing the whole day.
        staleSnapshot[0].pinnedAt = day.addingTimeInterval(120)
        _ = try await MemoRecordStore.shared.setPinnedAt(
            id: original.id, day: day, pinnedAt: staleSnapshot[0].pinnedAt, vaultRoot: vault
        )

        let persisted = try RawStorage.read(for: day, vaultRoot: vault)
        let backgroundOperation = try SyncOutboxStore.pendingOperation(for: backgroundMemo.id)
        XCTAssertEqual(persisted.first(where: { $0.id == original.id })?.pinnedAt,
                       staleSnapshot[0].pinnedAt)
        XCTAssertTrue(
            persisted.contains(where: { $0.id == backgroundMemo.id }),
            "Pinning A from a stale Today snapshot must not delete concurrently appended B; actual IDs: \(persisted.map(\.id))"
        )
        XCTAssertNotEqual(
            backgroundOperation?.kind,
            .delete,
            "A pin must not create B's cloud deletion; actual operation: \(String(describing: backgroundOperation?.kind))"
        )
    }
}
