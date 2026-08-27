import Foundation
import XCTest
import DayPageModels
@testable import DayPageStorage

final class SystemActionRemoteContractTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_500_800)
    private let deviceID = "raw-device-identifier-must-not-sync"

    func testOperationDTOUsesFrozenEnvelopeAndRedactsDeviceIdentifiers() throws {
        let proposal = try makeProposal()
        let local = try SystemActionOutboxOperation(
            operationID: UUID(),
            createdAt: now,
            payload: .proposal(proposal)
        )
        let remote = try SystemActionRemoteContractMapper.operation(from: local)
        let data = try JSONEncoder().encode(remote)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(
            Set(object.keys),
            Set([
                "protocol_version", "operation_id", "entity_type", "entity_id",
                "operation_kind", "revision", "record",
            ])
        )
        XCTAssertEqual(object["protocol_version"] as? Int, 1)
        XCTAssertEqual(object["entity_type"] as? String, "proposal")
        XCTAssertEqual(object["operation_kind"] as? String, "upsert")

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains(deviceID))
        XCTAssertFalse(text.contains("localMaterial"))
        XCTAssertTrue(text.contains(SystemActionRemoteContractMapper.hash(deviceID)))
    }

    func testRemoteDeviceHashPreservesOnlyCanonicalASCIISHA256() {
        let canonical = String(repeating: "a", count: 64)
        XCTAssertEqual(
            SystemActionRemoteContractMapper.deviceHash("remote:\(canonical)"),
            canonical
        )

        for suffix in [
            String(repeating: "A", count: 64),
            String(repeating: "١", count: 64),
            String(repeating: "１", count: 64),
        ] {
            let value = "remote:\(suffix)"
            XCTAssertEqual(
                SystemActionRemoteContractMapper.deviceHash(value),
                SystemActionRemoteContractMapper.hash(value)
            )
            XCTAssertNotEqual(SystemActionRemoteContractMapper.deviceHash(value), suffix)
        }
    }

    func testReceiptEnvelopeRevisionAlwaysUsesProposalRevisionNotAttempt() throws {
        let proposal = try makeProposal()
        for (proposalRevision, attempt) in [(Int64(2), 1), (Int64(1), 2)] {
            let receipt = try SystemActionReceipt(
                operationID: UUID(),
                proposalID: proposal.id,
                phase: .execute,
                proposalRevision: proposalRevision,
                payloadHash: proposal.payloadHash,
                attempt: attempt,
                outcome: .failed,
                deviceID: deviceID,
                errorCode: "synthetic_failure",
                reconciliationState: .notNeeded,
                rollbackCapability: .none,
                startedAt: now,
                completedAt: now
            )
            let operation = try SystemActionOutboxOperation(payload: .receipt(receipt))
            let remote = try SystemActionRemoteContractMapper.operation(from: operation)
            XCTAssertEqual(remote.revision, proposalRevision)
            guard case .object(let record) = remote.record else {
                return XCTFail("Expected receipt record")
            }
            XCTAssertEqual(record["attempt"], .integer(Int64(attempt)))
            XCTAssertEqual(record["proposal_revision"], .integer(proposalRevision))
        }
    }

    func testProposalCloudRoundTripUsesExplicitLifecycleVocabulary() throws {
        let proposal = try makeProposal(lifecycle: .pendingReview)
        let record = try SystemActionRemoteContractMapper.proposalRecord(proposal)
        let payload = try SystemActionRemoteContractMapper.localPayload(
            entityType: "proposal",
            record: record
        )
        guard case .proposal(let restored) = payload else {
            return XCTFail("Expected a proposal payload")
        }
        XCTAssertEqual(restored.id, proposal.id)
        XCTAssertEqual(restored.payload, proposal.payload)
        XCTAssertEqual(restored.payloadHash, proposal.payloadHash)
        XCTAssertEqual(restored.lifecycleState, .pendingReview)
        XCTAssertNotEqual(restored.creatorDeviceID, proposal.creatorDeviceID)

        let mappings: [(SystemActionLifecycleState, String)] = [
            (.pendingReview, "pending"), (.approved, "approved"), (.rejected, "rejected"),
            (.executing, "executing"), (.succeeded, "completed"), (.failed, "failed"),
            (.cancelled, "cancelled"), (.needsReview, "needs_review"),
        ]
        for (local, backend) in mappings {
            XCTAssertEqual(SystemActionRemoteContractMapper.backendState(for: local), backend)
            XCTAssertEqual(try SystemActionRemoteContractMapper.localState(for: backend), local)
        }
    }

    func testLocalContextSubtypeRoundTripsWithoutCapabilityCollapse() throws {
        let kinds: [SystemActionLocalContextKind] = [
            .weatherSummary, .healthSummary, .placeSummary, .photo, .contactSelection,
        ]
        for kind in kinds {
            let proposal = try SystemActionProposal(
                payload: .localContextAttachment(.init(
                    contextKind: kind,
                    summaryCode: UUID().uuidString,
                    observedAt: now
                )),
                title: "Attach context",
                rationale: "User requested it.",
                creatorSource: .localAgent,
                creatorDeviceID: deviceID,
                createdAt: now
            )
            let record = try SystemActionRemoteContractMapper.proposalRecord(proposal)
            let payload = try SystemActionRemoteContractMapper.localPayload(
                entityType: "proposal",
                record: record
            )
            guard case .proposal(let restored) = payload,
                  case .localContextAttachment(let context) = restored.payload else {
                return XCTFail("Expected local context proposal")
            }
            XCTAssertEqual(context.contextKind, kind)
            XCTAssertEqual(context.observedAt, now)
            XCTAssertEqual(restored.payloadHash, proposal.payloadHash)
        }
    }

    func testPullRejectsEquivalentButNonCanonicalTimestampSpellingBeforeHashAcceptance() throws {
        let proposal = try SystemActionProposal(
            payload: .calendarEvent(.init(
                title: "Review",
                startAt: now,
                endAt: now.addingTimeInterval(600),
                timeZoneIdentifier: "Asia/Shanghai"
            )),
            title: "Review",
            rationale: "Scheduled",
            creatorSource: .cloudMCP,
            creatorDeviceID: deviceID,
            createdAt: now
        )
        guard case .object(var record) = try SystemActionRemoteContractMapper.proposalRecord(proposal),
              case .object(var payload) = record["payload"] else {
            return XCTFail("Expected proposal record")
        }
        payload["start_at"] = .string("2026-08-24T00:00:00.000+08:00")
        record["payload"] = .object(payload)
        record["payload_hash"] = .string(try SystemActionCanonicalJSON.sha256(
            of: SystemActionJSONValue.object(payload)
        ))

        XCTAssertThrowsError(try SystemActionRemoteContractMapper.localPayload(
            entityType: "proposal",
            record: .object(record)
        )) { error in
            XCTAssertEqual(error as? SystemActionRemoteContractError, .invalidRecord("start_at"))
        }
    }

    func testEveryFrozenCaptureModeRoundTripsWithoutHashCollapse() throws {
        let kinds: [SystemActionCaptureKind] = [
            .text, .photo, .camera, .file, .document, .textScan, .ink, .voice,
        ]
        for kind in kinds {
            let proposal = try SystemActionProposal(
                payload: .capture(.init(captureKind: kind, suggestedTitle: "Bound title")),
                title: "Capture",
                rationale: "User requested it.",
                creatorSource: .localAgent,
                creatorDeviceID: deviceID,
                createdAt: now
            )
            let record = try SystemActionRemoteContractMapper.proposalRecord(proposal)
            let payload = try SystemActionRemoteContractMapper.localPayload(
                entityType: "proposal",
                record: record
            )
            guard case .proposal(let restored) = payload,
                  case .capture(let capture) = restored.payload else {
                return XCTFail("Expected capture proposal")
            }
            XCTAssertEqual(capture.captureKind, kind)
            XCTAssertEqual(capture.suggestedTitle, "Bound title")
            XCTAssertEqual(restored.payloadHash, proposal.payloadHash)
        }
    }

    func testMomentTitleRoundTripsWithoutHashCollapse() throws {
        let proposal = try SystemActionProposal(
            payload: .moment(.init(
                occurredAt: now,
                title: "Bound moment title",
                location: .init(label: "Current place")
            )),
            title: "Capture moment",
            rationale: "User requested it.",
            creatorSource: .localAgent,
            creatorDeviceID: deviceID,
            createdAt: now
        )
        let record = try SystemActionRemoteContractMapper.proposalRecord(proposal)
        let local = try SystemActionRemoteContractMapper.localPayload(
            entityType: "proposal",
            record: record
        )
        guard case .proposal(let restored) = local,
              case .moment(let moment) = restored.payload else {
            return XCTFail("Expected moment proposal")
        }
        XCTAssertEqual(moment.title, "Bound moment title")
        XCTAssertEqual(restored.payloadHash, proposal.payloadHash)
    }

    func testSupabaseClientSendsFrozenApplyBodyAndRequiresEveryAcknowledgement() async throws {
        let proposal = try makeProposal()
        let operation = try SystemActionOutboxOperation(payload: .proposal(proposal))
        let remoteOperation = try SystemActionRemoteContractMapper.operation(from: operation)
        let response = SystemActionRemotePushResult(
            accepted: [
                .init(
                    operationID: operation.operationID,
                    entityType: remoteOperation.entityType,
                    entityID: remoteOperation.entityID,
                    revision: remoteOperation.revision,
                    status: "applied",
                    changeSequence: 1,
                    record: remoteOperation.record
                ),
            ],
            rejected: []
        )
        let transport = SystemActionQueueTransport(responses: [try JSONEncoder().encode(response)])
        let client = makeClient(transport: transport)

        let result = try await client.push(operations: [operation])
        XCTAssertEqual(result.accepted.first?.operationID, operation.operationID)
        let recordedRequests = await transport.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["p_operations"]))
        let operations = try XCTUnwrap(body["p_operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0]["operation_id"] as? String, operation.operationID.uuidString)

        let missingTransport = SystemActionQueueTransport(
            responses: [try JSONEncoder().encode(SystemActionRemotePushResult(accepted: [], rejected: []))]
        )
        let missingClient = makeClient(transport: missingTransport)
        await XCTAssertThrowsSystemActionRemoteError(.exactReceiptMissing) {
            _ = try await missingClient.push(operations: [operation])
        }
    }

    func testSupabaseClientPullsTypedRecordAndClaimsWithHashedDevice() async throws {
        let proposal = try makeProposal()
        let record = try SystemActionRemoteContractMapper.proposalRecord(proposal)
        let pullFixture = SystemActionPullFixture(
            changes: [.init(changeSequence: 9, entityType: "proposal", entityID: proposal.id, record: record)],
            nextCursor: 9,
            hasMore: false
        )
        let pullTransport = SystemActionQueueTransport(responses: [try JSONEncoder().encode(pullFixture)])
        let pullClient = makeClient(transport: pullTransport)
        let page = try await pullClient.pull(after: 0, limit: 50)
        XCTAssertEqual(page.nextCursor, 9)
        guard case .proposal(let pulledProposal) = page.changes.first?.payload else {
            return XCTFail("Expected typed proposal change")
        }
        XCTAssertEqual(pulledProposal.payloadHash, proposal.payloadHash)

        let operationID = UUID()
        let leaseID = UUID()
        let claimData = try JSONSerialization.data(withJSONObject: [
            "operation_id": operationID.uuidString.lowercased(),
            "proposal_id": proposal.id.uuidString.lowercased(),
            "phase": "execute",
            "proposal_revision": proposal.revision,
            "payload_hash": proposal.payloadHash,
            "device_id_hash": SystemActionRemoteContractMapper.hash(deviceID),
            "status": "claimed",
            "lease_id": leaseID.uuidString.lowercased(),
            "issued_at": "2026-08-26T11:58:00.000Z",
            "expires_at": "2026-08-26T12:00:00.000Z",
            "receipt_id": NSNull(),
        ])
        let claimTransport = SystemActionQueueTransport(responses: [claimData])
        let claimClient = makeClient(transport: claimTransport)
        let claim = try await claimClient.claimExecution(.init(
            operationID: operationID,
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID
        ))
        guard case .leased(let lease) = claim else { return XCTFail("Expected lease") }
        XCTAssertEqual(lease.id, leaseID)
        XCTAssertEqual(lease.deviceID, deviceID)
        XCTAssertEqual(SystemActionCanonicalJSON.timestamp(lease.issuedAt), "2026-08-26T11:58:00.000Z")

        let recordedRequests = await claimTransport.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)
        let bodyData = try XCTUnwrap(request.httpBody)
        let text = try XCTUnwrap(String(data: bodyData, encoding: .utf8))
        XCTAssertFalse(text.contains(deviceID))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(body["p_device_id_hash"] as? String, SystemActionRemoteContractMapper.hash(deviceID))
        XCTAssertEqual(body["p_operation_id"] as? String, operationID.uuidString)
    }

    func testRouteAddressAndCoordinateRecordsRoundTripFrozenWireShape() throws {
        for destination in [
            SystemActionLocation(address: "1600 Amphitheatre Parkway"),
            SystemActionLocation(latitude: 37.422, longitude: -122.084),
        ] {
            let proposal = try SystemActionProposal(
                payload: .route(.init(destination: destination, mode: .any)),
                title: "Open route",
                rationale: "A destination was confirmed.",
                creatorSource: .user,
                creatorDeviceID: deviceID,
                createdAt: now
            )
            let record = try SystemActionRemoteContractMapper.proposalRecord(proposal)
            let local = try SystemActionRemoteContractMapper.localPayload(
                entityType: "proposal",
                record: record
            )
            guard case .proposal(let restored) = local,
                  case .route(let payload) = restored.payload else {
                return XCTFail("Expected route proposal")
            }
            XCTAssertEqual(restored.payloadHash, proposal.payloadHash)
            XCTAssertEqual(payload.mode, .any)
            XCTAssertEqual(payload.destination.address, destination.address)
            XCTAssertEqual(payload.destination.latitude, destination.latitude)
            XCTAssertEqual(payload.destination.longitude, destination.longitude)
        }
    }

    func testClaimDecodesBusyAndTerminalStatusesWithoutInventingLease() async throws {
        let proposal = try makeProposal()
        let operationID = UUID()
        let receiptID = UUID()
        let base: [String: Any] = [
            "operation_id": operationID.uuidString.lowercased(),
            "proposal_id": proposal.id.uuidString.lowercased(),
            "phase": "execute",
            "proposal_revision": proposal.revision,
            "payload_hash": proposal.payloadHash,
            "device_id_hash": SystemActionRemoteContractMapper.hash(deviceID),
        ]
        var busy = base
        busy["status"] = "busy"
        busy["lease_id"] = UUID().uuidString.lowercased()
        busy["issued_at"] = "2026-08-26T11:58:00.000Z"
        busy["expires_at"] = "2026-08-26T12:00:00.000Z"
        busy["receipt_id"] = NSNull()
        var completed = base
        completed["status"] = "already_completed"
        completed["lease_id"] = NSNull()
        completed["issued_at"] = NSNull()
        completed["expires_at"] = NSNull()
        completed["receipt_id"] = receiptID.uuidString.lowercased()
        var attemptCompleted = base
        attemptCompleted["status"] = "attempt_completed"
        attemptCompleted["lease_id"] = NSNull()
        attemptCompleted["issued_at"] = NSNull()
        attemptCompleted["expires_at"] = NSNull()
        attemptCompleted["receipt_id"] = receiptID.uuidString.lowercased()

        let transport = SystemActionQueueTransport(responses: [
            try JSONSerialization.data(withJSONObject: busy),
            try JSONSerialization.data(withJSONObject: completed),
            try JSONSerialization.data(withJSONObject: attemptCompleted),
        ])
        let client = makeClient(transport: transport)
        let request = SystemActionExecutionClaimRequest(
            operationID: operationID,
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID
        )
        guard case .busy(let expiresAt) = try await client.claimExecution(request) else {
            return XCTFail("Expected busy")
        }
        XCTAssertNotNil(expiresAt)
        let completedResult = try await client.claimExecution(request)
        XCTAssertEqual(completedResult, .alreadyCompleted(receiptID: receiptID))
        let attemptResult = try await client.claimExecution(request)
        XCTAssertEqual(attemptResult, .attemptCompleted(receiptID: receiptID))
    }

    func testClaimRejectsNonCanonicalLeaseTimestamp() async throws {
        let proposal = try makeProposal()
        let operationID = UUID()
        let response = try JSONSerialization.data(withJSONObject: [
            "operation_id": operationID.uuidString.lowercased(),
            "proposal_id": proposal.id.uuidString.lowercased(),
            "phase": "execute",
            "proposal_revision": proposal.revision,
            "payload_hash": proposal.payloadHash,
            "device_id_hash": SystemActionRemoteContractMapper.hash(deviceID),
            "status": "claimed",
            "lease_id": UUID().uuidString.lowercased(),
            "issued_at": "2026-08-26T11:58:00.000Z",
            "expires_at": "2026-08-26T20:00:00+08:00",
            "receipt_id": NSNull(),
        ])
        let client = makeClient(transport: SystemActionQueueTransport(responses: [response]))

        await XCTAssertThrowsSystemActionRemoteError(.invalidResponse) {
            _ = try await client.claimExecution(.init(
                operationID: operationID,
                proposalID: proposal.id,
                phase: .execute,
                proposalRevision: proposal.revision,
                payloadHash: proposal.payloadHash,
                deviceID: deviceID
            ))
        }
    }

    func testApplyAcknowledgementMustEchoExactEntityRevisionAndRecord() async throws {
        let proposal = try makeProposal()
        let operation = try SystemActionOutboxOperation(payload: .proposal(proposal))
        let sent = try SystemActionRemoteContractMapper.operation(from: operation)
        let response = SystemActionRemotePushResult(
            accepted: [.init(
                operationID: sent.operationID,
                entityType: sent.entityType,
                entityID: sent.entityID,
                revision: sent.revision,
                status: "applied",
                changeSequence: 9,
                record: .object(["tampered": .boolean(true)])
            )],
            rejected: []
        )
        let client = makeClient(transport: SystemActionQueueTransport(
            responses: [try JSONEncoder().encode(response)]
        ))
        await XCTAssertThrowsSystemActionRemoteError(.invalidResponse) {
            _ = try await client.push(operations: [operation])
        }
    }

    private func makeProposal(
        lifecycle: SystemActionLifecycleState = .pendingReview
    ) throws -> SystemActionProposal {
        try SystemActionProposal(
            payload: .reminder(.init(
                title: "Call Sam",
                dueAt: now.addingTimeInterval(600),
                timeZoneIdentifier: "Asia/Shanghai"
            )),
            title: "Create reminder",
            rationale: "A follow-up exists.",
            sourceReferences: [.init(kind: .memo, identifier: UUID().uuidString)],
            creatorSource: .localAgent,
            creatorDeviceID: deviceID,
            redactionLevel: .boundedSummary,
            createdAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            lifecycleState: lifecycle
        )
    }

    private func makeClient(
        transport: SystemActionQueueTransport
    ) -> SupabaseSystemActionRemoteClient {
        SupabaseSystemActionRemoteClient(
            endpoints: .init(
                apply: URL(string: "https://example.invalid/apply") ?? URL(fileURLWithPath: "/invalid"),
                pull: URL(string: "https://example.invalid/pull") ?? URL(fileURLWithPath: "/invalid"),
                claim: URL(string: "https://example.invalid/claim") ?? URL(fileURLWithPath: "/invalid")
            ),
            anonKey: "test-anon-key",
            transport: transport,
            accessTokenProvider: { "test-access-token" }
        )
    }
}

private actor SystemActionQueueTransport: HTTPTransport {
    enum StubError: Error { case noResponse, invalidHTTPResponse }

    private var responses: [Data]
    private var requests: [URLRequest] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw StubError.noResponse }
        let data = responses.removeFirst()
        guard let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/invalid"),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ) else {
            throw StubError.invalidHTTPResponse
        }
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private struct SystemActionPullFixture: Encodable {
    struct Change: Encodable {
        let changeSequence: Int64
        let entityType: String
        let entityID: UUID
        let record: SystemActionJSONValue

        enum CodingKeys: String, CodingKey {
            case changeSequence = "change_sequence"
            case entityType = "entity_type"
            case entityID = "entity_id"
            case record
        }
    }

    let changes: [Change]
    let nextCursor: Int64
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case changes
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

private func XCTAssertThrowsSystemActionRemoteError(
    _ expected: SystemActionRemoteError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected SystemActionRemoteError")
    } catch {
        XCTAssertEqual(error as? SystemActionRemoteError, expected)
    }
}
