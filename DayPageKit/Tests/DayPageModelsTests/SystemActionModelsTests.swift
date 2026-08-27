import XCTest
@testable import DayPageModels

final class SystemActionModelsTests: XCTestCase {
    private let deviceID = "device-under-test"
    private let now = Date(timeIntervalSince1970: 1_787_500_800)

    func testCanonicalHashIsStableAndBindsEveryExecutableField() throws {
        let payload = SystemActionPayload.calendarEvent(.init(
            title: "Design review",
            notes: "Bring the prototype",
            startAt: now,
            endAt: now.addingTimeInterval(1_800),
            timeZoneIdentifier: "Asia/Shanghai",
            location: .init(label: "Studio")
        ))
        let first = try makeProposal(payload: payload)
        let second = try makeProposal(id: first.id, payload: payload)
        XCTAssertEqual(first.payloadHash, second.payloadHash)
        XCTAssertEqual(first.payloadHash.count, 64)

        let edited = try first.revised(
            payload: .calendarEvent(.init(
                title: "Design review",
                notes: "Bring the prototype",
                startAt: now,
                endAt: now.addingTimeInterval(3_600),
                timeZoneIdentifier: "Asia/Shanghai",
                location: .init(label: "Studio")
            )),
            title: first.title,
            rationale: first.rationale,
            now: now.addingTimeInterval(5)
        )
        XCTAssertEqual(edited.revision, 2)
        XCTAssertNotEqual(edited.payloadHash, first.payloadHash)
        XCTAssertEqual(edited.createdAt, first.createdAt)
    }

    func testDisplayLifecycleDoesNotChangeExecutablePayloadHash() throws {
        let proposal = try makeProposal(payload: .focusSession(.init(
            title: "Write",
            durationSeconds: 1_500
        )))
        let executing = try proposal.withLifecycleState(.executing)
        XCTAssertEqual(executing.payloadHash, proposal.payloadHash)
        XCTAssertEqual(executing.revision, proposal.revision)
    }

    func testTamperedPayloadHashFailsClosedDuringDecode() throws {
        let proposal = try makeProposal(payload: .reminder(.init(title: "Call Sam", dueAt: now)))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(proposal)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["payloadHash"] = String(repeating: "0", count: 64)
        let tampered = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try decoder.decode(SystemActionProposal.self, from: tampered)) { error in
            XCTAssertEqual(error as? SystemActionValidationError, .payloadHashMismatch)
        }
    }

    func testUnknownFutureKindRoundTripsButIsNotSupported() throws {
        let payload = SystemActionPayload.unsupported(
            kind: "future_ambient_display",
            value: .object([
                "intensity": .integer(3),
                "enabled": .boolean(true),
                "nested": .array([.string("preserve-me")]),
            ])
        )
        let proposal = try makeProposal(payload: payload)
        XCTAssertEqual(proposal.kind, .unsupported("future_ambient_display"))
        XCTAssertFalse(proposal.kind.isSupported)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(
            SystemActionProposal.self,
            from: encoder.encode(proposal)
        )
        XCTAssertEqual(roundTrip, proposal)
    }

    func testKnownPayloadValidationRejectsUnsafeCoordinatesAndIntervals() throws {
        XCTAssertThrowsError(try makeProposal(payload: .route(.init(
            destination: .init(label: "Impossible", latitude: 120, longitude: 1)
        ))))
        XCTAssertThrowsError(try makeProposal(payload: .calendarEvent(.init(
            title: "Backwards",
            startAt: now,
            endAt: now.addingTimeInterval(-1)
        ))))
        XCTAssertThrowsError(try makeProposal(payload: .focusSession(.init(
            title: "Too short",
            durationSeconds: 1
        ))))
    }

    func testCapabilityPolicyRejectsContradictoryOfferAndDisclosureStates() throws {
        XCTAssertThrowsError(try SystemActionCapabilityPolicy(
            capability: .calendar,
            isOffered: false,
            isSynchronized: true,
            disclosureLevel: .fullProposal
        ))
        XCTAssertThrowsError(try SystemActionCapabilityPolicy(
            capability: .calendar,
            isOffered: true,
            isSynchronized: false,
            disclosureLevel: .fullProposal
        ))
        XCTAssertNoThrow(try SystemActionCapabilityPolicy(
            capability: .calendar,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled
        ))
    }

    func testRouteAcceptsAddressOrCoordinatesAndBindsTheSelectedDestination() throws {
        let address = try makeProposal(payload: .route(.init(
            destination: .init(address: "1 Infinite Loop, Cupertino")
        )))
        let coordinates = try makeProposal(payload: .route(.init(
            destination: .init(latitude: 37.3317, longitude: -122.0301)
        )))
        XCTAssertNotEqual(address.payloadHash, coordinates.payloadHash)

        guard case .object(let addressWire) = try address.payload.canonicalCloudValue(),
              case .object(let coordinateWire) = try coordinates.payload.canonicalCloudValue() else {
            return XCTFail("Expected canonical objects")
        }
        XCTAssertEqual(addressWire["destination_address"], .string("1 Infinite Loop, Cupertino"))
        XCTAssertNil(addressWire["destination_latitude"])
        XCTAssertEqual(coordinateWire["destination_label"], .string("Pinned location"))
        XCTAssertEqual(coordinateWire["destination_latitude"], .number(37.3317))

        XCTAssertThrowsError(try makeProposal(payload: .route(.init(
            destination: .init(
                latitude: 37.3317,
                longitude: -122.0301,
                address: "conflicting destination"
            )
        ))))
        XCTAssertThrowsError(try makeProposal(payload: .route(.init(destination: .init()))))
        XCTAssertThrowsError(try makeProposal(payload: .route(.init(
            destination: .init(latitude: 0.000_000_1, longitude: 0)
        ))))
        XCTAssertThrowsError(try makeProposal(payload: .route(.init(
            destination: .init(address: "Cupertino"),
            opensImmediately: false
        ))))
        guard case .route(let approvedRoute) = address.payload else {
            return XCTFail("Expected route")
        }
        XCTAssertTrue(approvedRoute.opensImmediately)
    }

    func testCoordinateHashUsesCrossPlatformFixedPointGoldenVector() throws {
        let proposal = try makeProposal(payload: .route(.init(
            destination: .init(label: "Tiny", latitude: 0.000_001, longitude: -0.000_001),
            mode: .walking
        )))
        XCTAssertEqual(
            proposal.payloadHash,
            "0daab34946dd400a4389a48450bc75f500670c92983d722170361bc5119338df"
        )
        XCTAssertEqual(
            String(decoding: try SystemActionCanonicalJSON.data(for: proposal.payload.canonicalCloudValue()), as: UTF8.self),
            #"{"destination_label":"Tiny","destination_latitude":0.000001,"destination_longitude":-0.000001,"kind":"route","transport":"walking"}"#
        )
    }

    func testCanonicalTimestampIsFrozenUTCWithExactlyMilliseconds() throws {
        let date = Date(timeIntervalSince1970: 1_787_500_800.1234)
        let wire = SystemActionCanonicalJSON.timestamp(date)
        XCTAssertEqual(wire, "2026-08-23T16:00:00.123Z")
        XCTAssertEqual(SystemActionCanonicalJSON.date(fromCanonicalTimestamp: wire),
                       Date(timeIntervalSince1970: 1_787_500_800.123))
        XCTAssertNil(SystemActionCanonicalJSON.date(fromCanonicalTimestamp: "2026-08-24T00:00:00.123+08:00"))
        XCTAssertNil(SystemActionCanonicalJSON.date(fromCanonicalTimestamp: "2026-08-23T16:00:00Z"))
    }

    func testFocusHashBindsEndAlertAndLiveActivityIndependently() throws {
        let both = try makeProposal(payload: .focusSession(.init(
            title: "Write", durationSeconds: 600,
            schedulesEndAlert: true, allowsLiveActivity: true
        )))
        let alertOnly = try makeProposal(payload: .focusSession(.init(
            title: "Write", durationSeconds: 600,
            schedulesEndAlert: true, allowsLiveActivity: false
        )))
        let activityOnly = try makeProposal(payload: .focusSession(.init(
            title: "Write", durationSeconds: 600,
            schedulesEndAlert: false, allowsLiveActivity: true
        )))
        XCTAssertNotEqual(both.payloadHash, alertOnly.payloadHash)
        XCTAssertNotEqual(both.payloadHash, activityOnly.payloadHash)
        guard case .object(let wire) = try activityOnly.payload.canonicalCloudValue() else {
            return XCTFail("Expected focus wire object")
        }
        XCTAssertEqual(wire["schedule_end_alert"], .boolean(false))
        XCTAssertEqual(wire["allow_live_activity"], .boolean(true))
    }

    func testWireNormalizationBindsTimeZonesAndContactLabels() throws {
        let calendar = SystemActionCalendarEventPayload(
            title: "Review",
            startAt: now.addingTimeInterval(0.0004),
            endAt: now.addingTimeInterval(600.0004)
        )
        XCTAssertNotNil(calendar.timeZoneIdentifier)
        XCTAssertEqual(
            calendar.startAt.timeIntervalSince1970 * 1_000,
            (calendar.startAt.timeIntervalSince1970 * 1_000).rounded(),
            accuracy: 0.0001
        )

        let contact = SystemActionContactDraftPayload(
            givenName: "Sam",
            familyName: "",
            phoneNumbers: [.init(label: "secret-custom-label", value: "+1 555 0100")],
            emailAddresses: [.init(label: "another-label", value: "sam@example.com")]
        )
        XCTAssertEqual(contact.phoneNumbers.first?.label, "phone")
        XCTAssertEqual(contact.emailAddresses.first?.label, "email")
        XCTAssertNoThrow(try makeProposal(payload: .contactDraft(contact)))
    }

    func testPreciseMomentCoordinatesAreNotAcceptedOutsideCloudApprovalHash() throws {
        XCTAssertThrowsError(try makeProposal(payload: .moment(.init(
            occurredAt: now,
            location: .init(label: "Here", latitude: 31.2304, longitude: 121.4737)
        ))))
        XCTAssertNoThrow(try makeProposal(payload: .moment(.init(
            occurredAt: now,
            location: .init(label: "Use one-shot location")
        ))))
        XCTAssertThrowsError(try makeProposal(payload: .moment(.init(
            occurredAt: now,
            location: .init(label: "   ")
        ))))
    }

    func testCaptureAndMomentTitlesAreBoundIntoExecutableHash() throws {
        let captureA = try makeProposal(payload: .capture(.init(
            captureKind: .document,
            suggestedTitle: "Invoice A"
        )))
        let captureB = try makeProposal(payload: .capture(.init(
            captureKind: .document,
            suggestedTitle: "Invoice B"
        )))
        XCTAssertNotEqual(captureA.payloadHash, captureB.payloadHash)

        let momentA = try makeProposal(payload: .moment(.init(
            occurredAt: now,
            title: "Arrival"
        )))
        let momentB = try makeProposal(payload: .moment(.init(
            occurredAt: now,
            title: "Departure"
        )))
        XCTAssertNotEqual(momentA.payloadHash, momentB.payloadHash)
    }

    func testDuplicateSourceReferencesAreRejected() throws {
        let duplicate = SystemActionSourceReference(kind: .memo, identifier: "memo-1")
        XCTAssertThrowsError(try SystemActionProposal(
            payload: .capture(.init(captureKind: .text)),
            title: "Capture",
            rationale: "",
            sourceReferences: [duplicate, duplicate],
            creatorSource: .user,
            creatorDeviceID: deviceID,
            createdAt: now
        )) { error in
            XCTAssertEqual(
                error as? SystemActionValidationError,
                .invalidField("source_reference_duplicate")
            )
        }
    }

    func testRequiredCapabilityMappingIsPayloadSpecific() {
        XCTAssertEqual(
            SystemActionPayload.calendarEvent(.init(
                title: "Event",
                startAt: now,
                endAt: now.addingTimeInterval(60)
            )).requiredCapabilities,
            [.calendar]
        )
        XCTAssertEqual(
            SystemActionPayload.reminder(.init(title: "Reminder")).requiredCapabilities,
            [.reminders]
        )
        XCTAssertEqual(
            SystemActionPayload.contactDraft(.init(givenName: "Sam", familyName: ""))
                .requiredCapabilities,
            [.contacts]
        )
        XCTAssertEqual(
            SystemActionPayload.notification(.init(title: "Notice", body: "", fireAt: now))
                .requiredCapabilities,
            [.notifications]
        )
        XCTAssertEqual(
            SystemActionPayload.route(.init(destination: .init(address: "Cupertino")))
                .requiredCapabilities,
            [.routes]
        )
        XCTAssertEqual(
            SystemActionPayload.capture(.init(captureKind: .document)).requiredCapabilities,
            [.capture]
        )
        XCTAssertEqual(
            SystemActionPayload.focusSession(.init(title: "Focus", durationSeconds: 60))
                .requiredCapabilities,
            [.focus]
        )
        XCTAssertEqual(
            SystemActionPayload.moment(.init(occurredAt: now)).requiredCapabilities,
            []
        )
        XCTAssertEqual(
            SystemActionPayload.moment(.init(
                occurredAt: now,
                location: .init(label: "Current place")
            )).requiredCapabilities,
            [.location]
        )

        let contextCapabilities: [(SystemActionLocalContextKind, SystemActionCapability)] = [
            (.weatherSummary, .weatherContext),
            (.healthSummary, .healthContext),
            (.placeSummary, .location),
            (.photo, .photos),
            (.contactSelection, .contacts),
        ]
        for (kind, capability) in contextCapabilities {
            XCTAssertEqual(
                SystemActionPayload.localContextAttachment(.init(
                    contextKind: kind,
                    summaryCode: UUID().uuidString,
                    observedAt: now
                )).requiredCapabilities,
                [capability]
            )
        }
    }

    func testApprovalAndReceiptRejectNonCanonicalHashes() throws {
        let nonCanonicalHashes = [
            String(repeating: "A", count: 64),
            String(repeating: "١", count: 64),
            String(repeating: "１", count: 64),
        ]
        for hash in nonCanonicalHashes {
            XCTAssertThrowsError(try SystemActionDecision(
                proposalID: UUID(),
                proposalRevision: 1,
                payloadHash: hash,
                outcome: .approved,
                deviceID: deviceID
            ))
            XCTAssertThrowsError(try SystemActionReceipt(
                operationID: UUID(),
                proposalID: UUID(),
                phase: .execute,
                proposalRevision: 1,
                payloadHash: hash,
                attempt: 1,
                outcome: .failed,
                deviceID: deviceID,
                errorCode: "failed",
                reconciliationState: .notNeeded,
                rollbackCapability: .none,
                startedAt: now,
                completedAt: now
            ))
        }
    }

    func testReceiptErrorCodeUsesFrozenCloudGrammar() throws {
        let hash = String(repeating: "a", count: 64)
        func make(errorCode: String) throws -> SystemActionReceipt {
            try SystemActionReceipt(
                operationID: UUID(), proposalID: UUID(), phase: .execute,
                proposalRevision: 1, payloadHash: hash, attempt: 1,
                outcome: .failed, deviceID: deviceID, errorCode: errorCode,
                reconciliationState: .notNeeded, rollbackCapability: .none,
                startedAt: now, completedAt: now
            )
        }
        XCTAssertNoThrow(try make(errorCode: "calendar_ekerror.17"))
        XCTAssertThrowsError(try make(errorCode: "Calendar.Error"))
        XCTAssertThrowsError(try make(errorCode: String(repeating: "a", count: 81)))
        XCTAssertThrowsError(try make(errorCode: "contains space"))
    }

    func testProposalBoundsSourcesAndFuturePayloadBytes() throws {
        let sources = (0...SystemActionProposal.maximumSourceReferences).map {
            SystemActionSourceReference(kind: .memo, identifier: "memo-\($0)")
        }
        XCTAssertThrowsError(try SystemActionProposal(
            payload: .capture(.init(captureKind: .document)),
            title: "Scan",
            rationale: "",
            sourceReferences: sources,
            creatorSource: .user,
            creatorDeviceID: deviceID,
            createdAt: now
        )) { error in
            XCTAssertEqual(error as? SystemActionValidationError, .tooManySources)
        }

        XCTAssertThrowsError(try makeProposal(payload: .unsupported(
            kind: "future",
            value: .string(String(repeating: "x", count: SystemActionCanonicalJSON.maximumPayloadBytes))
        ))) { error in
            guard case .payloadTooLarge = error as? SystemActionValidationError else {
                return XCTFail("Expected payloadTooLarge, got \(error)")
            }
        }
    }

    func testReplacementDecisionMustAdvanceSameProposal() throws {
        let original = try makeProposal(payload: .notification(.init(
            title: "Leave",
            body: "Time to go",
            fireAt: now.addingTimeInterval(600)
        )))
        let replacement = try original.revised(
            payload: .notification(.init(
                title: "Leave",
                body: "Time to go",
                fireAt: now.addingTimeInterval(1_200)
            )),
            title: original.title,
            rationale: original.rationale,
            now: now.addingTimeInterval(1)
        )
        XCTAssertNoThrow(try SystemActionDecision(
            proposalID: original.id,
            proposalRevision: original.revision,
            payloadHash: original.payloadHash,
            outcome: .replacementProposed,
            decidedAt: now,
            deviceID: deviceID,
            replacementProposal: replacement
        ))

        XCTAssertThrowsError(try SystemActionDecision(
            proposalID: original.id,
            proposalRevision: original.revision,
            payloadHash: original.payloadHash,
            outcome: .approved,
            deviceID: deviceID,
            replacementProposal: replacement
        ))
    }

    func testReceiptAllowsOnlyBoundedHashedExternalIdentity() throws {
        let operationID = UUID()
        let proposalID = UUID()
        let hash = String(repeating: "a", count: 64)
        let receipt = try SystemActionReceipt(
            operationID: operationID,
            proposalID: proposalID,
            phase: .execute,
            proposalRevision: 1,
            payloadHash: hash,
            attempt: 1,
            outcome: .succeeded,
            deviceID: deviceID,
            boundedResult: .init(
                summaryCode: "calendar_created",
                externalIdentifierHash: String(repeating: "b", count: 64),
                metadata: ["resource_kind": "calendar_event"]
            ),
            reconciliationState: .notNeeded,
            rollbackCapability: .reversible,
            startedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(receipt.boundedResult?.summaryCode, "calendar_created")

        XCTAssertThrowsError(try SystemActionReceipt(
            operationID: operationID,
            proposalID: proposalID,
            phase: .execute,
            proposalRevision: 1,
            payloadHash: hash,
            attempt: 1,
            outcome: .succeeded,
            deviceID: deviceID,
            boundedResult: .init(summaryCode: "created", externalIdentifierHash: "raw-id"),
            reconciliationState: .notNeeded,
            rollbackCapability: .reversible,
            startedAt: now,
            completedAt: now
        ))

        for hash in [String(repeating: "١", count: 64), String(repeating: "１", count: 64)] {
            XCTAssertThrowsError(try SystemActionReceipt(
                operationID: operationID,
                proposalID: proposalID,
                phase: .execute,
                proposalRevision: 1,
                payloadHash: String(repeating: "a", count: 64),
                attempt: 1,
                outcome: .succeeded,
                deviceID: deviceID,
                boundedResult: .init(summaryCode: "created", externalIdentifierHash: hash),
                reconciliationState: .notNeeded,
                rollbackCapability: .reversible,
                startedAt: now,
                completedAt: now
            ))
        }
    }

    func testAuthorizationUnknownValueIsPreserved() throws {
        let data = Data("\"future_scoped\"".utf8)
        let decoded = try JSONDecoder().decode(SystemActionAuthorizationState.self, from: data)
        XCTAssertEqual(decoded, .unsupported("future_scoped"))
        XCTAssertEqual(try JSONEncoder().encode(decoded), data)
    }

    private func makeProposal(
        id: UUID = UUID(),
        payload: SystemActionPayload
    ) throws -> SystemActionProposal {
        try SystemActionProposal(
            id: id,
            payload: payload,
            title: "Suggested action",
            rationale: "A bounded reason",
            sourceReferences: [.init(kind: .memo, identifier: UUID().uuidString)],
            creatorSource: .localAgent,
            creatorDeviceID: deviceID,
            createdAt: now
        )
    }
}
