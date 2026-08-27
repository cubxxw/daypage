import CoreLocation
import Foundation
import XCTest
@testable import DayPageServices

final class PassiveLocationServiceTests: XCTestCase {
    private let arrival = Date(timeIntervalSince1970: 1_787_654_321)

    private func observation(
        sourceArrivalDate: Date?,
        observedAt: Date? = nil,
        departureDate: Date? = nil,
        latitude: Double = 31.2304,
        longitude: Double = 121.4737
    ) -> PassiveVisitObservation {
        PassiveVisitObservation(
            observedAt: observedAt ?? arrival.addingTimeInterval(300),
            sourceArrivalDate: sourceArrivalDate,
            departureDate: departureDate,
            latitude: latitude,
            longitude: longitude
        )
    }

    func testVisitAutomationRequiresAndPersistsExplicitOptIn() throws {
        let suite = "passive-visit-opt-in-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = PassiveVisitAutomationPreference(defaults: defaults)

        XCTAssertFalse(preference.isEnabled)
        preference.setEnabled(true)
        XCTAssertTrue(preference.isEnabled)
        XCTAssertTrue(PassiveVisitAutomationPreference(defaults: defaults).isEnabled)
        preference.setEnabled(false)
        XCTAssertFalse(preference.isEnabled)
    }

    func testVisitCallbackGateFailsClosedAfterDisableOrAuthorizationLoss() {
        XCTAssertTrue(PassiveVisitAutomationGate.shouldAccept(
            automationEnabled: true,
            authorizationStatus: .authorizedAlways,
            isMonitoring: true
        ))
        XCTAssertFalse(PassiveVisitAutomationGate.shouldAccept(
            automationEnabled: false,
            authorizationStatus: .authorizedAlways,
            isMonitoring: true
        ))
        XCTAssertFalse(PassiveVisitAutomationGate.shouldAccept(
            automationEnabled: true,
            authorizationStatus: .denied,
            isMonitoring: true
        ))
        XCTAssertFalse(PassiveVisitAutomationGate.shouldAccept(
            automationEnabled: true,
            authorizationStatus: .authorizedAlways,
            isMonitoring: false
        ))
    }

    func testKnownArrivalReplayUpdatesOneDraftAndPreservesUserState() {
        var drafts: [VisitDraft] = []
        let first = PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: arrival),
            into: &drafts
        )
        drafts[0].placeName = "People's Square"
        drafts[0].status = .confirmed

        let departure = arrival.addingTimeInterval(1_800)
        let replay = PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: arrival.addingTimeInterval(0.5),
                departureDate: departure,
                // Roughly 30 m from the first callback.
                latitude: 31.23067,
                longitude: 121.4737
            ),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(replay.draftID, first.draftID)
        XCTAssertFalse(replay.inserted)
        XCTAssertEqual(drafts[0].arrivalDate, arrival)
        XCTAssertEqual(drafts[0].departureDate, departure)
        XCTAssertEqual(drafts[0].placeName, "People's Square")
        XCTAssertEqual(drafts[0].status, .confirmed)
    }

    func testSamePlaceWithDifferentKnownArrivalCreatesNewDraft() {
        var drafts: [VisitDraft] = []
        PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: arrival),
            into: &drafts
        )
        PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: arrival.addingTimeInterval(3_600)),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 2)
    }

    func testSameArrivalAtDistinctPlaceCreatesNewDraft() {
        var drafts: [VisitDraft] = []
        PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: arrival),
            into: &drafts
        )
        PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: arrival,
                latitude: 31.2324,
                longitude: 121.4737
            ),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 2)
    }

    func testOngoingReplayAndDepartureCompleteTheOriginalDraft() {
        var drafts: [VisitDraft] = []
        let firstObservedAt = arrival.addingTimeInterval(300)
        let first = PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: nil, observedAt: firstObservedAt),
            into: &drafts
        )
        let departure = arrival.addingTimeInterval(2_000)
        let completed = PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: nil,
                observedAt: arrival.addingTimeInterval(900),
                departureDate: departure,
                latitude: 31.23067,
                longitude: 121.4737
            ),
            into: &drafts
        )
        let replay = PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: nil,
                observedAt: arrival.addingTimeInterval(1_200),
                departureDate: departure.addingTimeInterval(0.5)
            ),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(completed.draftID, first.draftID)
        XCTAssertEqual(replay.draftID, first.draftID)
        XCTAssertEqual(drafts[0].arrivalDate, firstObservedAt)
        XCTAssertEqual(drafts[0].sourceArrivalSemantics, .ongoing)
        XCTAssertEqual(drafts[0].departureDate, departure.addingTimeInterval(0.5))
    }

    func testNewOngoingVisitAfterCompletedVisitCreatesNewDraft() {
        var drafts: [VisitDraft] = []
        PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: nil,
                departureDate: arrival.addingTimeInterval(1_800)
            ),
            into: &drafts
        )
        PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: nil,
                observedAt: arrival.addingTimeInterval(86_400),
                departureDate: nil
            ),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 2)
    }

    func testStaleActiveOngoingVisitCannotAbsorbLaterVisitAtSamePlace() {
        var drafts: [VisitDraft] = []
        let firstObservedAt = arrival.addingTimeInterval(300)
        PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: nil, observedAt: firstObservedAt),
            into: &drafts
        )
        PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: nil,
                observedAt: firstObservedAt.addingTimeInterval(
                    PassiveVisitDraftUpserter.maximumOngoingAge + 1
                )
            ),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 2)
        XCTAssertNotEqual(drafts[0].id, drafts[1].id)
    }

    func testOngoingReplayAtMaximumAgeStillUpdatesOriginalDraft() {
        var drafts: [VisitDraft] = []
        let firstObservedAt = arrival.addingTimeInterval(300)
        let first = PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: nil, observedAt: firstObservedAt),
            into: &drafts
        )
        let replay = PassiveVisitDraftUpserter.upsert(
            observation(
                sourceArrivalDate: nil,
                observedAt: firstObservedAt.addingTimeInterval(
                    PassiveVisitDraftUpserter.maximumOngoingAge
                )
            ),
            into: &drafts
        )

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(replay.draftID, first.draftID)
        XCTAssertFalse(replay.inserted)
    }

    func testLegacyDraftWithoutArrivalSemanticsStillDecodesAndDeduplicates() throws {
        struct LegacyVisitDraft: Codable {
            var id: UUID
            var arrivalDate: Date
            var departureDate: Date?
            var latitude: Double
            var longitude: Double
            var placeName: String?
            var status: VisitDraft.Status
        }

        let legacy = LegacyVisitDraft(
            id: UUID(),
            arrivalDate: arrival,
            departureDate: nil,
            latitude: 31.2304,
            longitude: 121.4737,
            placeName: nil,
            status: .pending
        )
        let decoded = try JSONDecoder().decode(
            VisitDraft.self,
            from: JSONEncoder().encode(legacy)
        )
        var drafts = [decoded]
        let result = PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: arrival),
            into: &drafts
        )

        XCTAssertNil(decoded.sourceArrivalSemantics)
        XCTAssertFalse(result.inserted)
        XCTAssertEqual(drafts.count, 1)
    }

    func testBoundedPersistenceRoundTripsLegacyCompatibleDrafts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passive-visits-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("drafts/visits.json")
        var drafts: [VisitDraft] = []
        PassiveVisitDraftUpserter.upsert(
            observation(sourceArrivalDate: arrival),
            into: &drafts
        )

        try PassiveVisitDraftPersistence.save(drafts, to: url)
        let loaded = try PassiveVisitDraftPersistence.load(from: url)

        XCTAssertEqual(loaded, drafts)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        XCTAssertNotNil(size)
        XCTAssertLessThanOrEqual(size ?? .max, PassiveVisitDraftPersistence.maximumFileBytes)
    }

    func testBoundedPersistenceRejectsOversizedFileWithoutReadingItAll() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passive-visits-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("visits.json")
        try Data(count: PassiveVisitDraftPersistence.maximumFileBytes + 1).write(to: url)

        XCTAssertThrowsError(try PassiveVisitDraftPersistence.load(from: url)) { error in
            XCTAssertEqual(error as? PassiveVisitDraftPersistenceError, .fileTooLarge)
        }
    }
}
