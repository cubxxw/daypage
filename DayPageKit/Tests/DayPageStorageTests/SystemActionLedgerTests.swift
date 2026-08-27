import XCTest
import DayPageModels
@testable import DayPageStorage

final class SystemActionLedgerTests: XCTestCase {
    private var vaultRoot: URL!
    private let deviceID = "ledger-device"
    private let now = Date(timeIntervalSince1970: 1_787_500_800)

    override func setUpWithError() throws {
        vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-system-action-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultRoot.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let vaultRoot { try? FileManager.default.removeItem(at: vaultRoot) }
        vaultRoot = nil
    }

    func testProposalDecisionOutboxAndCursorSurviveFreshLedgerInstance() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now.addingTimeInterval(1))
        try await ledger.advanceRemoteCursor(to: 41)

        let reloaded = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let snapshot = try await reloaded.snapshot()
        XCTAssertEqual(snapshot.proposals.count, 1)
        XCTAssertEqual(snapshot.decisions.count, 1)
        XCTAssertEqual(snapshot.pendingOutbox.count, 2)
        XCTAssertEqual(snapshot.remoteCursor, 41)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.ledgerURL.path))
    }

    func testAccountTransitionResetAtomicallyRemovesLedgerAndOutboxState() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now.addingTimeInterval(1))
        try await ledger.advanceRemoteCursor(to: 41)

        try await ledger.resetForAccountTransition()

        let reloaded = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let snapshot = try await reloaded.snapshot()
        XCTAssertTrue(snapshot.proposals.isEmpty)
        XCTAssertTrue(snapshot.decisions.isEmpty)
        XCTAssertTrue(snapshot.receipts.isEmpty)
        XCTAssertTrue(snapshot.capabilityPolicies.isEmpty)
        XCTAssertTrue(snapshot.executions.isEmpty)
        XCTAssertTrue(snapshot.pendingOutbox.isEmpty)
        XCTAssertEqual(snapshot.remoteCursor, 0)
    }

    func testAccountTransitionRefusesUnconfirmedRemoteLeaseEvidence() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let plan = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now
        )
        guard case .ready(let planned) = plan else { return XCTFail("Expected plan") }
        _ = try await ledger.prepareRemoteClaim(operationID: planned.operationID)

        await XCTAssertThrowsErrorAsync {
            try await ledger.resetForAccountTransition()
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .unresolvedRemoteCoordination)
        }
        let preservedSnapshot = try await ledger.snapshot()
        XCTAssertEqual(preservedSnapshot.executions.count, 1)

        let lease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        _ = try await ledger.authorizeExecution(
            operationID: planned.operationID,
            coordination: .leased(lease),
            now: now
        )
        _ = try await ledger.recordAdapterResult(
            operationID: planned.operationID,
            result: .init(outcome: .succeeded),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(1)
        )
        await XCTAssertThrowsErrorAsync {
            try await ledger.resetForAccountTransition()
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .unresolvedRemoteCoordination)
        }

        for operation in try await ledger.pendingOutbox() {
            try await ledger.acknowledge(
                operationID: operation.operationID,
                requestFingerprint: operation.requestFingerprint
            )
        }
        try await ledger.resetForAccountTransition()
        let clearedSnapshot = try await ledger.snapshot()
        XCTAssertTrue(clearedSnapshot.executions.isEmpty)
    }

    func testExpiredOfflineProposalNeverCreatesAClaimingExecution() async throws {
        let proposal = try SystemActionProposal(
            payload: .reminder(.init(title: "Expiring")),
            title: "Expiring reminder",
            rationale: "Expiry regression",
            creatorSource: .localAgent,
            creatorDeviceID: deviceID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(1)
        )
        let ledger = try await approvedLedger(proposal: proposal)

        await XCTAssertThrowsErrorAsync {
            _ = try await ledger.prepareExecutionPlan(
                proposalID: proposal.id,
                phase: .execute,
                now: self.now.addingTimeInterval(2)
            )
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .proposalExpired)
        }
        let snapshot = try await ledger.snapshot()
        XCTAssertTrue(snapshot.executions.isEmpty)
        XCTAssertEqual(snapshot.proposals.first?.lifecycleState, .approved)
    }

    func testOnlinePreparationDefersExpiryToServerIssuedLeaseTime() async throws {
        let proposal = try SystemActionProposal(
            payload: .reminder(.init(title: "Clock-skew safe")),
            title: "Clock-skew safe reminder",
            rationale: "Server time is authoritative",
            creatorSource: .localAgent,
            creatorDeviceID: deviceID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let ledger = try await approvedLedger(proposal: proposal)
        let plan = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now.addingTimeInterval(3_600),
            enforceLocalExpiry: false
        )
        guard case .ready(let planned) = plan else { return XCTFail("Expected online plan") }
        _ = try await ledger.prepareRemoteClaim(operationID: planned.operationID)
        let lease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now.addingTimeInterval(30),
            expiresAt: now.addingTimeInterval(50)
        )
        let authorized = try await ledger.authorizeExecution(
            operationID: planned.operationID,
            coordination: .leased(lease),
            now: now.addingTimeInterval(3_600)
        )
        guard case .ready(let execution) = authorized else { return XCTFail("Expected execution") }
        XCTAssertEqual(execution.lease?.id, lease.id)
    }

    func testApprovalIsBoundToExactRevisionAndHash() async throws {
        let original = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(original)
        try await ledger.recordDecision(try approval(for: original))

        let edited = try original.revised(
            payload: .reminder(.init(title: "Changed", dueAt: now.addingTimeInterval(900))),
            title: original.title,
            rationale: original.rationale,
            now: now.addingTimeInterval(1)
        )
        try await ledger.saveProposal(edited)
        await XCTAssertThrowsErrorAsync {
            _ = try await ledger.prepareExecution(
                proposalID: edited.id,
                phase: .execute,
                coordination: .offline,
                now: self.now.addingTimeInterval(2)
            )
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .missingExactApproval)
        }
    }

    func testPreparationIsDurableBeforeNativeSideEffect() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let preparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let prepared) = preparation else {
            return XCTFail("Expected a fresh execution")
        }

        let reloaded = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let snapshot = try await reloaded.snapshot()
        XCTAssertEqual(snapshot.executions.first?.operationID, prepared.operationID)
        XCTAssertEqual(snapshot.executions.first?.state, .executing)

        let recovered = try await reloaded.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now.addingTimeInterval(10)
        )
        guard case .requiresReconciliation(let record, _) = recovered else {
            return XCTFail("Interrupted execution must reconcile before retry")
        }
        XCTAssertEqual(record.operationID, prepared.operationID)
        XCTAssertEqual(record.attempt, 1)
    }

    func testClaimPlanSurvivesRestartAndAuthorizesTheExactSameAttempt() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let first = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now
        )
        guard case .ready(let planned) = first else { return XCTFail("Expected plan") }
        XCTAssertEqual(planned.state, .claiming)
        XCTAssertNil(planned.lease)

        let reloaded = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let replay = try await reloaded.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now.addingTimeInterval(1)
        )
        guard case .ready(let replayed) = replay else { return XCTFail("Expected replayed plan") }
        XCTAssertEqual(replayed.operationID, planned.operationID)
        XCTAssertEqual(replayed.attempt, 1)

        let lease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let remotePlan = try await reloaded.prepareRemoteClaim(operationID: replayed.operationID)
        let authorized = try await reloaded.authorizeExecution(
            operationID: remotePlan.operationID,
            coordination: .leased(lease),
            now: now.addingTimeInterval(2)
        )
        guard case .ready(let execution) = authorized else { return XCTFail("Expected execution") }
        XCTAssertEqual(execution.operationID, planned.operationID)
        XCTAssertEqual(execution.lease?.id, lease.id)
        XCTAssertEqual(execution.state, .executing)
    }

    func testCommittedSuccessIsIdempotentAndExternalIdentifierStaysLocal() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let preparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let execution) = preparation else { return XCTFail("Expected ready") }
        let rawIdentifier = "EKEvent/raw/device-only/123"
        let receipt = try await ledger.recordAdapterResult(
            operationID: execution.operationID,
            result: .init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "event_created", metadata: ["resource_kind": "calendar_event"]),
                localMaterial: .init(externalIdentifier: rawIdentifier, beforeSnapshot: Data("before".utf8))
            ),
            rollbackCapability: .reversible,
            completedAt: now.addingTimeInterval(1)
        )
        XCTAssertNotNil(receipt.boundedResult?.externalIdentifierHash)
        XCTAssertNotEqual(receipt.boundedResult?.externalIdentifierHash, rawIdentifier)

        let repeatPreparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now.addingTimeInterval(2)
        )
        guard case .alreadyCompleted(let historical) = repeatPreparation else {
            return XCTFail("Exact retry must return the historical receipt")
        }
        XCTAssertEqual(historical.id, receipt.id)

        let outboxData = try JSONEncoder().encode(try await ledger.pendingOutbox())
        let outboxText = try XCTUnwrap(String(data: outboxData, encoding: .utf8))
        XCTAssertFalse(outboxText.contains(rawIdentifier))
        let storedMaterial = try await ledger.localMaterial(operationID: execution.operationID)
        XCTAssertEqual(storedMaterial?.externalIdentifier, rawIdentifier)
    }

    func testClearFailureRetriesWithFreshPerAttemptOperationID() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let first = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let firstRecord) = first else { return XCTFail("Expected ready") }
        _ = try await ledger.recordAdapterResult(
            operationID: firstRecord.operationID,
            result: .init(outcome: .failed, errorCode: "permission_denied"),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(1)
        )

        let retry = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now.addingTimeInterval(2)
        )
        guard case .ready(let retried) = retry else { return XCTFail("Clear failure should retry") }
        XCTAssertNotEqual(retried.operationID, firstRecord.operationID)
        XCTAssertEqual(retried.attempt, 2)
    }

    func testRetryRemovesPriorFailedAttemptMaterialInsteadOfOrphaningIt() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let first = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let execution) = first else { return XCTFail("Expected execution") }
        _ = try await ledger.recordAdapterResult(
            operationID: execution.operationID,
            result: .init(
                outcome: .failed,
                localMaterial: .init(externalIdentifier: "failed-attempt-only"),
                errorCode: "synthetic_failure"
            ),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(1)
        )
        let storedBeforeRetry = try await ledger.localMaterial(operationID: execution.operationID)
        XCTAssertNotNil(storedBeforeRetry)

        _ = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now.addingTimeInterval(2)
        )
        let storedAfterRetry = try await ledger.localMaterial(operationID: execution.operationID)
        XCTAssertNil(storedAfterRetry)
        _ = try await SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID).snapshot()
    }

    func testReceiptedReconciliationUsesFreshOperationAndFreshLease() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let oldLease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30)
        )
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .leased(oldLease),
            now: now
        )
        guard case .ready(let first) = initial else { return XCTFail("Expected first attempt") }
        _ = try await ledger.recordAdapterResult(
            operationID: first.operationID,
            result: .init(
                outcome: .ambiguous,
                errorCode: "native_state_ambiguous",
                reconciliationState: .needsReview
            ),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(1)
        )

        let planned = try await ledger.prepareReconciliationResolution(
            operationID: first.operationID,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(planned.attempt, 2)
        XCTAssertNotEqual(planned.operationID, first.operationID)
        XCTAssertEqual(planned.state, .claimingRemote)
        XCTAssertNil(planned.lease)

        let freshLease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let authorized = try await ledger.authorizeExecution(
            operationID: planned.operationID,
            coordination: .leased(freshLease),
            now: now.addingTimeInterval(3)
        )
        guard case .ready(let resolution) = authorized else { return XCTFail("Expected resolution") }
        let receipt = try await ledger.recordAdapterResult(
            operationID: resolution.operationID,
            result: .init(outcome: .succeeded, reconciliationState: .reconciled),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(4)
        )
        XCTAssertEqual(receipt.operationID, planned.operationID)
        XCTAssertEqual(receipt.attempt, 2)
        XCTAssertEqual(receipt.leaseID, freshLease.id)
        XCTAssertNotEqual(receipt.leaseID, oldLease.id)
    }

    func testLeaseMustBindEveryExecutionField() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let invalidLease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: String(repeating: "f", count: 64),
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await ledger.prepareExecution(
                proposalID: proposal.id,
                phase: .execute,
                coordination: .leased(invalidLease),
                now: self.now
            )
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .leaseMismatch)
        }
    }

    func testOnlineLeaseUsesServerIssuedTimeDespiteClientClockSkew() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let lease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let localClockFarAhead = now.addingTimeInterval(86_400)
        let plan = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: localClockFarAhead,
            enforceLocalExpiry: false
        )
        guard case .ready(let planned) = plan else { return XCTFail("Expected plan") }
        _ = try await ledger.prepareRemoteClaim(operationID: planned.operationID)
        let authorized = try await ledger.authorizeExecution(
            operationID: planned.operationID,
            coordination: .leased(lease),
            now: localClockFarAhead
        )
        guard case .ready(let execution) = authorized else {
            return XCTFail("Expected execution")
        }
        XCTAssertEqual(execution.startedAt, lease.issuedAt)
    }

    func testPulledSpecificDeviceHashAllowsMatchingOwnerOffline() async throws {
        let target = "remote:\(SystemActionRemoteContractMapper.hash(deviceID))"
        let proposal = try SystemActionProposal(
            payload: .reminder(.init(title: "Owned reminder")),
            title: "Create reminder",
            rationale: "",
            creatorSource: .user,
            creatorDeviceID: "remote:\(SystemActionRemoteContractMapper.hash("creator"))",
            targetDevice: .specific(target),
            createdAt: now
        )
        let ledger = try await approvedLedger(proposal: proposal)
        let preparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let execution) = preparation else {
            return XCTFail("Expected matching hashed owner to execute offline")
        }
        XCTAssertNil(execution.lease)
    }

    func testUndoRequiresSeparateApprovalAndOriginalDeviceMaterial() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let execute = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let executeRecord) = execute else { return XCTFail("Expected execute") }
        _ = try await ledger.recordAdapterResult(
            operationID: executeRecord.operationID,
            result: .init(outcome: .succeeded, localMaterial: .init(externalIdentifier: "local-id")),
            rollbackCapability: .reversible,
            completedAt: now.addingTimeInterval(1)
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await ledger.prepareExecution(
                proposalID: proposal.id,
                phase: .undo,
                coordination: .offline,
                now: self.now.addingTimeInterval(2)
            )
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .missingExactApproval)
        }

        try await ledger.recordDecision(try approval(for: proposal, phase: .undo), now: now.addingTimeInterval(2))
        let undo = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .undo,
            coordination: .offline,
            now: now.addingTimeInterval(3)
        )
        guard case .ready(let undoRecord) = undo else { return XCTFail("Expected undo") }
        XCTAssertNotEqual(undoRecord.operationID, executeRecord.operationID)
    }

    func testExactAcknowledgementCannotClearDifferentOutboxOperation() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(proposal)
        let initialOutbox = try await ledger.pendingOutbox()
        let operation = try XCTUnwrap(initialOutbox.first)
        await XCTAssertThrowsErrorAsync {
            try await ledger.acknowledge(
                operationID: operation.operationID,
                requestFingerprint: String(repeating: "0", count: 64)
            )
        }
        let remainingOutbox = try await ledger.pendingOutbox()
        XCTAssertEqual(remainingOutbox.count, 1)
    }

    func testActionLedgerNeverChangesRawVaultBytes() async throws {
        let rawURL = vaultRoot.appendingPathComponent("raw/2026-08-26.md")
        let rawBytes = Data("---\nid: untouched\n---\nprivate memo bytes\n".utf8)
        try rawBytes.write(to: rawURL)

        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let preparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let execution) = preparation else { return XCTFail("Expected ready") }
        _ = try await ledger.recordAdapterResult(
            operationID: execution.operationID,
            result: .init(outcome: .failed, errorCode: "synthetic_failure"),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(1)
        )

        XCTAssertEqual(try Data(contentsOf: rawURL), rawBytes)
        let agentPath = ledger.ledgerURL.path
        XCTAssertTrue(agentPath.contains("/_agent/system-actions/"))
        XCTAssertFalse(agentPath.contains("/raw/"))
    }

    func testRemotePullIsMonotonicAndDoesNotEchoToOutbox() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let page = SystemActionRemotePullPage(
            fromCursor: 0,
            nextCursor: 7,
            hasMore: false,
            changes: [.init(sequence: 7, payload: .proposal(proposal))]
        )
        try await ledger.applyRemotePage(page)
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.remoteCursor, 7)
        XCTAssertEqual(snapshot.proposals, [proposal])
        XCTAssertTrue(snapshot.pendingOutbox.isEmpty)

        await XCTAssertThrowsErrorAsync {
            try await ledger.applyRemotePage(SystemActionRemotePullPage(
                fromCursor: 0,
                nextCursor: 8,
                hasMore: false,
                changes: []
            ))
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .cursorRegression)
        }
    }

    func testPulledOtherDeviceAttemptsDoNotAdvanceLocalExecutorCounter() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let remoteReceipt = try SystemActionReceipt(
            operationID: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            attempt: 1,
            outcome: .failed,
            deviceID: "remote:\(SystemActionRemoteContractMapper.hash("other-device"))",
            executionMode: .onlineLease,
            leaseID: UUID(),
            errorCode: "remote_failure",
            reconciliationState: .notNeeded,
            rollbackCapability: .none,
            startedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        let otherRemoteReceipt = try SystemActionReceipt(
            operationID: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            attempt: 1,
            outcome: .failed,
            deviceID: "remote:\(SystemActionRemoteContractMapper.hash("third-device"))",
            executionMode: .onlineLease,
            leaseID: UUID(),
            errorCode: "remote_failure",
            reconciliationState: .notNeeded,
            rollbackCapability: .none,
            startedAt: now.addingTimeInterval(1),
            completedAt: now.addingTimeInterval(2)
        )
        try await ledger.applyRemotePage(.init(
            fromCursor: 0,
            nextCursor: 2,
            hasMore: false,
            changes: [
                .init(sequence: 1, payload: .receipt(remoteReceipt)),
                .init(sequence: 2, payload: .receipt(otherRemoteReceipt)),
            ]
        ))
        let pulledReceipts = try await ledger.receipts(proposalID: proposal.id)
        XCTAssertEqual(pulledReceipts.count, 2)

        let preparation = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now.addingTimeInterval(2)
        )
        guard case .ready(let planned) = preparation else {
            return XCTFail("Expected a new local attempt")
        }
        XCTAssertEqual(planned.attempt, 1)
        XCTAssertEqual(planned.deviceID, deviceID)
    }

    func testTerminallyRejectedSameRevisionProposalAdoptsServerWinnerAndAdvancesCursor() async throws {
        let local = try makeProposal()
        let remote = try SystemActionProposal(
            id: local.id,
            payload: .reminder(.init(title: "Server winner", dueAt: now.addingTimeInterval(1_200))),
            title: "Server winner",
            rationale: "Another device won the same revision race.",
            creatorSource: .localAgent,
            creatorDeviceID: "other-device",
            createdAt: local.createdAt,
            expiresAt: local.expiresAt
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(local, now: now)
        let localOutbox = try await ledger.pendingOutbox()
        let operation = try XCTUnwrap(localOutbox.first)
        try await ledger.discardRejected(
            operationID: operation.operationID,
            requestFingerprint: operation.requestFingerprint
        )

        try await ledger.applyRemotePage(.init(
            fromCursor: 0,
            nextCursor: 8,
            hasMore: false,
            changes: [.init(sequence: 8, payload: .proposal(remote))]
        ))
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.remoteCursor, 8)
        XCTAssertEqual(snapshot.proposals.first?.payloadHash, remote.payloadHash)
        XCTAssertTrue(snapshot.pendingOutbox.isEmpty)
    }

    func testTerminallyRejectedSameRevisionPolicyAdoptsServerWinnerByCapability() async throws {
        let local = try SystemActionCapabilityPolicy(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now
        )
        let remote = try SystemActionCapabilityPolicy(
            capability: .reminders,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled,
            updatedAt: now.addingTimeInterval(1)
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.setCapabilityPolicy(local, now: now)
        let localOutbox = try await ledger.pendingOutbox()
        let operation = try XCTUnwrap(localOutbox.first)
        try await ledger.discardRejected(
            operationID: operation.operationID,
            requestFingerprint: operation.requestFingerprint
        )

        try await ledger.applyRemotePage(.init(
            fromCursor: 0,
            nextCursor: 9,
            hasMore: false,
            changes: [.init(sequence: 9, payload: .capabilityPolicy(remote))]
        ))
        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.remoteCursor, 9)
        XCTAssertEqual(snapshot.capabilityPolicies, [remote])
        XCTAssertTrue(snapshot.pendingOutbox.isEmpty)
    }

    func testRejectedReplacementDecisionAndProposalConvergeToServerWinner() async throws {
        let original = try makeProposal()
        let localReplacement = try original.revised(
            payload: .reminder(.init(
                title: "Local revision",
                dueAt: now.addingTimeInterval(1_200)
            )),
            title: "Local revision",
            rationale: "Local replacement",
            now: now.addingTimeInterval(1)
        )
        let remoteReplacement = try original.revised(
            payload: .reminder(.init(
                title: "Server revision",
                dueAt: now.addingTimeInterval(2_400)
            )),
            title: "Server revision",
            rationale: "Remote replacement",
            now: now.addingTimeInterval(2)
        )
        let localDecision = try SystemActionDecision(
            proposalID: original.id,
            proposalRevision: original.revision,
            payloadHash: original.payloadHash,
            outcome: .replacementProposed,
            decidedAt: now,
            deviceID: deviceID,
            replacementProposal: localReplacement
        )
        let remoteDecision = try SystemActionDecision(
            proposalID: original.id,
            proposalRevision: original.revision,
            payloadHash: original.payloadHash,
            outcome: .replacementProposed,
            decidedAt: now.addingTimeInterval(0.5),
            deviceID: "other-device",
            replacementProposal: remoteReplacement
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(original, now: now)
        for operation in try await ledger.pendingOutbox() {
            try await ledger.acknowledge(
                operationID: operation.operationID,
                requestFingerprint: operation.requestFingerprint
            )
        }
        try await ledger.recordDecision(localDecision, now: now.addingTimeInterval(1))
        for operation in try await ledger.pendingOutbox() {
            try await ledger.discardRejected(
                operationID: operation.operationID,
                requestFingerprint: operation.requestFingerprint
            )
        }

        try await ledger.applyRemotePage(.init(
            fromCursor: 0,
            nextCursor: 11,
            hasMore: false,
            changes: [
                .init(sequence: 10, payload: .decision(remoteDecision)),
                .init(sequence: 11, payload: .proposal(remoteReplacement)),
            ]
        ))

        let snapshot = try await ledger.snapshot()
        XCTAssertEqual(snapshot.remoteCursor, 11)
        XCTAssertEqual(snapshot.proposals, [remoteReplacement])
        XCTAssertEqual(snapshot.decisions, [remoteDecision])
        XCTAssertTrue(snapshot.pendingOutbox.isEmpty)
    }

    func testReplacementOutboxPreservesBackendDependencyOrder() async throws {
        let original = try makeProposal()
        let replacement = try original.revised(
            payload: .reminder(.init(title: "Call Sam tomorrow", dueAt: now.addingTimeInterval(86_400))),
            title: original.title,
            rationale: original.rationale,
            now: now.addingTimeInterval(1)
        )
        let decision = try SystemActionDecision(
            proposalID: original.id,
            proposalRevision: original.revision,
            payloadHash: original.payloadHash,
            outcome: .replacementProposed,
            decidedAt: now,
            deviceID: deviceID,
            replacementProposal: replacement
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(original, now: now)
        try await ledger.recordDecision(decision, now: now.addingTimeInterval(1))

        let operations = try await ledger.pendingOutbox()
        let remote = try operations.map(SystemActionRemoteContractMapper.operation)
        XCTAssertEqual(remote.map(\.entityType), ["proposal", "approval", "proposal"])
        XCTAssertEqual(remote.map(\.revision), [1, 1, 2])

        let approvalPayload = try SystemActionRemoteContractMapper.localPayload(
            entityType: "approval",
            record: remote[1].record
        )
        guard case .decision(let restored) = approvalPayload else {
            return XCTFail("Expected replacement decision")
        }
        XCTAssertEqual(restored.outcome, .replacementProposed)
        XCTAssertEqual(restored.replacementProposalID, original.id)
        XCTAssertNil(restored.replacementProposal)
    }

    func testEnablingFullSyncBackfillsEveryPrivateProposalRevisionInOrder() async throws {
        let original = try makeProposal()
        let replacement = try original.revised(
            payload: .reminder(.init(title: "Revised privately", dueAt: now.addingTimeInterval(900))),
            title: original.title,
            rationale: original.rationale,
            now: now.addingTimeInterval(1)
        )
        let replacementDecision = try SystemActionDecision(
            proposalID: original.id,
            proposalRevision: original.revision,
            payloadHash: original.payloadHash,
            outcome: .replacementProposed,
            decidedAt: now.addingTimeInterval(1),
            deviceID: deviceID,
            replacementProposal: replacement
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(original, now: now)
        try await ledger.recordDecision(replacementDecision, now: now.addingTimeInterval(1))
        try await ledger.recordDecision(try approval(for: replacement), now: now.addingTimeInterval(2))
        let privateOutbox = try await ledger.pendingOutbox()
        XCTAssertTrue(privateOutbox.isEmpty)

        try await ledger.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now.addingTimeInterval(3)
        ), now: now.addingTimeInterval(3))

        let remote = try await ledger.pendingOutbox().map(SystemActionRemoteContractMapper.operation)
        XCTAssertEqual(remote.map(\.entityType), ["policy", "proposal", "approval", "proposal", "approval"])
        XCTAssertEqual(remote.map(\.revision), [1, 1, 1, 2, 2])
    }

    func testExecutableOutboxFailsClosedUnlessEveryCapabilityAllowsFullProposalSync() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)

        try await ledger.saveProposal(proposal, now: now)
        let isEligibleWithoutPolicy = try await ledger.isCloudEligible(proposal)
        XCTAssertFalse(isEligibleWithoutPolicy)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let missingPolicyOutbox = try await ledger.pendingOutbox()
        XCTAssertTrue(missingPolicyOutbox.isEmpty)

        let redacted = try SystemActionCapabilityPolicy(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .redactedSync,
            updatedAt: now.addingTimeInterval(1)
        )
        try await ledger.setCapabilityPolicy(redacted, now: now.addingTimeInterval(1))
        let isEligibleWithRedactedPolicy = try await ledger.isCloudEligible(proposal)
        XCTAssertFalse(isEligibleWithRedactedPolicy)
        let policyOnly = try await ledger.pendingOutbox()
        XCTAssertEqual(policyOnly.count, 1)
        guard case .capabilityPolicy = policyOnly[0].payload else {
            return XCTFail("Redacted sync may publish only the policy record")
        }

        let privatePolicy = try SystemActionCapabilityPolicy(
            id: redacted.id,
            revision: 2,
            capability: .reminders,
            isOffered: true,
            isSynchronized: false,
            disclosureLevel: .privateDeviceOnly,
            updatedAt: now.addingTimeInterval(2)
        )
        try await ledger.setCapabilityPolicy(privatePolicy, now: now.addingTimeInterval(2))
        let isEligibleWithPrivatePolicy = try await ledger.isCloudEligible(proposal)
        XCTAssertFalse(isEligibleWithPrivatePolicy)
        let privateOutbox = try await ledger.pendingOutbox()
        XCTAssertEqual(privateOutbox.count, 2)
        guard case .capabilityPolicy(let privateRevocation) = privateOutbox[1].payload else {
            return XCTFail("Privacy downgrade must publish the bounded policy revocation")
        }
        XCTAssertFalse(privateRevocation.isSynchronized)

        let fullPolicy = try SystemActionCapabilityPolicy(
            id: redacted.id,
            revision: 3,
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now.addingTimeInterval(3)
        )
        try await ledger.setCapabilityPolicy(fullPolicy, now: now.addingTimeInterval(3))
        let isEligibleWithFullPolicy = try await ledger.isCloudEligible(proposal)
        XCTAssertTrue(isEligibleWithFullPolicy)
        let fullOutbox = try await ledger.pendingOutbox()
        XCTAssertEqual(fullOutbox.count, 5)
        XCTAssertEqual(fullOutbox.compactMap { operation -> Int64? in
            guard case .capabilityPolicy(let value) = operation.payload else { return nil }
            return value.revision
        }, [1, 2, 3])
        guard case .proposal(let backfilledProposal) = fullOutbox[3].payload,
              case .decision(let backfilledDecision) = fullOutbox[4].payload else {
            return XCTFail("Enabling full sync must backfill proposal then decision")
        }
        XCTAssertEqual(backfilledProposal.id, proposal.id)
        XCTAssertEqual(backfilledDecision.proposalID, proposal.id)

        let disabled = try SystemActionCapabilityPolicy(
            id: redacted.id,
            revision: 4,
            capability: .reminders,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled,
            updatedAt: now.addingTimeInterval(4)
        )
        try await ledger.setCapabilityPolicy(disabled, now: now.addingTimeInterval(4))
        let isEligibleWhenDisabled = try await ledger.isCloudEligible(proposal)
        XCTAssertFalse(isEligibleWhenDisabled)
        let disabledOutbox = try await ledger.pendingOutbox()
        XCTAssertEqual(disabledOutbox.count, 4)
        guard case .capabilityPolicy(let denied) = disabledOutbox[3].payload else {
            return XCTFail("Capability deny must revoke a stale remote grant")
        }
        XCTAssertFalse(denied.isOffered)
    }

    func testPulledRedactedCopyOfLocalReceiptDoesNotConflict() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let preparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let execution) = preparation else { return XCTFail("Expected ready") }
        let local = try await ledger.recordAdapterResult(
            operationID: execution.operationID,
            result: .init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "reminder_created"),
                localMaterial: .init(externalIdentifier: "device-private-id")
            ),
            rollbackCapability: .reversible,
            completedAt: now.addingTimeInterval(1)
        )
        let wire = SystemActionRemoteContractMapper.receiptRecord(local)
        let pulled = try SystemActionRemoteContractMapper.localPayload(entityType: "receipt", record: wire)
        try await ledger.applyRemotePage(.init(
            fromCursor: 0,
            nextCursor: 1,
            hasMore: false,
            changes: [.init(sequence: 1, payload: pulled)]
        ))
        let receipts = try await ledger.receipts(proposalID: proposal.id)
        let material = try await ledger.localMaterial(operationID: execution.operationID)
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(material?.externalIdentifier, "device-private-id")
    }

    func testPolicyDowngradePreservesOnlineLeaseReceiptForRelease() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await enableFullSync(on: ledger)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let plan = try await ledger.prepareExecutionPlan(
            proposalID: proposal.id,
            phase: .execute,
            now: now
        )
        guard case .ready(let planned) = plan else { return XCTFail("Expected plan") }
        _ = try await ledger.prepareRemoteClaim(operationID: planned.operationID)
        let lease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        _ = try await ledger.authorizeExecution(
            operationID: planned.operationID,
            coordination: .leased(lease),
            now: now
        )

        let activePolicy = try await ledger.capabilityPolicy(for: .reminders)
        let full = try XCTUnwrap(activePolicy)
        try await ledger.setCapabilityPolicy(try .init(
            id: full.id,
            revision: full.revision + 1,
            capability: .reminders,
            isOffered: true,
            isSynchronized: false,
            disclosureLevel: .privateDeviceOnly,
            updatedAt: now.addingTimeInterval(1)
        ), now: now.addingTimeInterval(1))
        let receipt = try await ledger.recordAdapterResult(
            operationID: planned.operationID,
            result: .init(outcome: .succeeded),
            rollbackCapability: .reversible,
            completedAt: now.addingTimeInterval(2)
        )

        XCTAssertEqual(receipt.executionMode, .onlineLease)
        let pending = try await ledger.pendingOutbox()
        XCTAssertTrue(pending.contains { operation in
            guard case .receipt(let queued) = operation.payload else { return false }
            return queued.id == receipt.id
        })
    }

    func testExecutedProposalCannotBeRevisedAndOrphanItsUndoMaterial() async throws {
        let proposal = try makeProposal()
        let ledger = try await approvedLedger(proposal: proposal)
        let preparation = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let execution) = preparation else { return XCTFail("Expected ready") }
        _ = try await ledger.recordAdapterResult(
            operationID: execution.operationID,
            result: .init(outcome: .failed, errorCode: "synthetic"),
            rollbackCapability: .none,
            completedAt: now.addingTimeInterval(1)
        )
        let revised = try proposal.revised(
            payload: .reminder(.init(title: "Different")),
            title: proposal.title,
            rationale: proposal.rationale,
            now: now.addingTimeInterval(2)
        )
        await XCTAssertThrowsErrorAsync {
            try await ledger.saveProposal(revised)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .invalidTransition)
        }
    }

    // MARK: Helpers

    private func makeProposal() throws -> SystemActionProposal {
        try SystemActionProposal(
            payload: .reminder(.init(title: "Call Sam", dueAt: now.addingTimeInterval(600))),
            title: "Create reminder",
            rationale: "A concrete follow-up exists.",
            sourceReferences: [.init(kind: .memo, identifier: UUID().uuidString)],
            creatorSource: .localAgent,
            creatorDeviceID: deviceID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(86_400)
        )
    }

    private func approval(
        for proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase = .execute
    ) throws -> SystemActionDecision {
        try SystemActionDecision(
            proposalID: proposal.id,
            phase: phase,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            outcome: .approved,
            decidedAt: now,
            deviceID: deviceID
        )
    }

    private func approvedLedger(proposal: SystemActionProposal) async throws -> SystemActionLedger {
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        return ledger
    }

    private func enableFullSync(on ledger: SystemActionLedger) async throws {
        try await ledger.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now
        ), now: now)
        for operation in try await ledger.pendingOutbox() {
            try await ledger.acknowledge(
                operationID: operation.operationID,
                requestFingerprint: operation.requestFingerprint
            )
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
