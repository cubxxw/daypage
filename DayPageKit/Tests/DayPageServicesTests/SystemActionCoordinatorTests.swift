import XCTest
import DayPageModels
import DayPageStorage
@testable import DayPageServices

final class SystemActionCoordinatorTests: XCTestCase {
    private var vaultRoot: URL!
    private let deviceID = "coordinator-device"
    private let now = Date(timeIntervalSince1970: 1_787_500_800)

    override func setUpWithError() throws {
        vaultRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("daypage-system-action-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultRoot.appendingPathComponent("raw", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let vaultRoot { try? FileManager.default.removeItem(at: vaultRoot) }
        vaultRoot = nil
    }

    func testExecuteRequiresApprovalPersistsReceiptAndIsIdempotent() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: false)
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .missingExactApproval)
        }

        try await coordinator.decide(try approval(for: proposal))
        let first = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        let second = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.outcome, .succeeded)
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 1)
    }

    func testBatchKeepsPerItemFailureAndContinuesLaterItems() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [
                .success(.init(outcome: .failed, errorCode: "permission_denied")),
                .success(.init(
                    outcome: .succeeded,
                    boundedResult: .init(summaryCode: "reminder_created")
                )),
            ]
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let first = try makeProposal(title: "First")
        let second = try makeProposal(title: "Second")
        for proposal in [first, second] {
            try await coordinator.saveProposal(proposal)
            try await coordinator.decide(try approval(for: proposal))
        }

        let results = await coordinator.executeBatch(
            proposalIDs: [first.id, second.id],
            mode: .offline
        )
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].receipt?.outcome, .failed)
        XCTAssertEqual(results[0].errorCode, "permission_denied")
        XCTAssertEqual(results[1].receipt?.outcome, .succeeded)
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 2)
    }

    func testThrownNativeErrorIsReducedToStableCode() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [.failure(FakeSystemActionError.permissionDenied)]
        )
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(receipt.outcome, .failed)
        XCTAssertEqual(receipt.errorCode, "permission_denied")
        XCTAssertFalse(String(describing: receipt).contains("private native details"))
    }

    func testPostSideEffectPersistenceFailureRemainsReconcileOnly() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [.success(.init(
                outcome: .succeeded,
                localMaterial: .init(beforeSnapshot: Data(repeating: 7, count: 16 * 1_024 + 1))
            ))],
            reconciliationResults: [.success(.init(
                disposition: .confirmed,
                confirmedResult: .init(outcome: .succeeded)
            ))]
        )
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .localMaterialTooLarge)
        }
        let afterFailure = try await coordinator.ledger.snapshot().executions.first
        let receiptsAfterFailure = try await coordinator.ledger.receipts(proposalID: proposal.id)
        XCTAssertEqual(afterFailure?.state, .executing)
        XCTAssertTrue(receiptsAfterFailure.isEmpty)

        let recovered = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        let executeCalls = await adapter.executeCallCount()
        let reconcileCalls = await adapter.reconcileCallCount()
        XCTAssertEqual(recovered.outcome, .succeeded)
        XCTAssertEqual(executeCalls, 1)
        XCTAssertEqual(reconcileCalls, 1)
    }

    func testThrownAmbiguousUndoBecomesNeedsReviewReceipt() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            undoResults: [.failure(.ambiguous)]
        )
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        _ = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        try await coordinator.decide(try approval(for: proposal, phase: .undo))

        let receipt = try await coordinator.undo(proposalID: proposal.id, mode: .offline)

        XCTAssertEqual(receipt.outcome, .ambiguous)
        XCTAssertEqual(receipt.reconciliationState, .needsReview)
        let persistedProposal = try await coordinator.ledger.proposal(id: proposal.id)
        XCTAssertEqual(persistedProposal?.lifecycleState, .needsReview)
    }

    func testPendingSuccessfulReceiptReconcilesIntoNewImmutableAttempt() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [.success(.init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "created"),
                localMaterial: .init(externalIdentifier: "native-id"),
                reconciliationState: .pending
            ))],
            reconciliationResults: [.success(.init(
                disposition: .confirmed,
                confirmedResult: .init(
                    outcome: .succeeded,
                    boundedResult: .init(summaryCode: "reconciled")
                )
            ))]
        )
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        let pending = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(pending.reconciliationState, .pending)

        let reconciled = try await coordinator.execute(proposalID: proposal.id, mode: .offline)

        XCTAssertEqual(reconciled.outcome, .succeeded)
        XCTAssertEqual(reconciled.reconciliationState, .reconciled)
        XCTAssertEqual(reconciled.attempt, 2)
        let receipts = try await coordinator.ledger.receipts(proposalID: proposal.id)
        let executeCalls = await adapter.executeCallCount()
        let reconcileCalls = await adapter.reconcileCallCount()
        XCTAssertEqual(receipts.map(\.attempt), [1, 2])
        XCTAssertEqual(executeCalls, 1)
        XCTAssertEqual(reconcileCalls, 1)
    }

    func testReceiptedOnlineReconciliationClaimsFreshLeaseForResolutionAttempt() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let releasedLease = SystemActionExecutionLease(
            id: UUID(), proposalID: proposal.id, phase: .execute,
            proposalRevision: proposal.revision, payloadHash: proposal.payloadHash,
            deviceID: deviceID, issuedAt: now, expiresAt: now.addingTimeInterval(60)
        )
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id, phase: .execute,
            coordination: .leased(releasedLease), now: now
        )
        guard case .ready(let first) = initial else { return XCTFail("Expected first attempt") }
        _ = try await ledger.recordAdapterResult(
            operationID: first.operationID,
            result: .init(outcome: .succeeded, reconciliationState: .pending),
            rollbackCapability: .reversible,
            completedAt: now.addingTimeInterval(1)
        )
        let freshLease = SystemActionExecutionLease(
            id: UUID(), proposalID: proposal.id, phase: .execute,
            proposalRevision: proposal.revision, payloadHash: proposal.payloadHash,
            deviceID: deviceID, issuedAt: now, expiresAt: now.addingTimeInterval(120)
        )
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID, now: now, claimResults: [.leased(freshLease)]
        )
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            reconciliationResults: [.success(.init(
                disposition: .confirmed,
                confirmedResult: .init(outcome: .succeeded)
            ))]
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger, adapters: [adapter], remoteClient: remote,
            deviceID: deviceID, authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(5) }
        )

        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        let claimIDs = await remote.allClaimOperationIDs()
        XCTAssertEqual(receipt.attempt, 2)
        XCTAssertNotEqual(receipt.operationID, first.operationID)
        XCTAssertEqual(claimIDs, [receipt.operationID])
        XCTAssertEqual(receipt.leaseID, freshLease.id)
        XCTAssertNotEqual(receipt.leaseID, releasedLease.id)
    }

    func testAutomaticWithConfiguredRemoteNeverFallsBackAfterMutationFailure() async throws {
        let ownerAdapter = FakeSystemActionAdapter(kind: .reminder)
        let ownerLedger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let ownerCoordinator = SystemActionCoordinator(
            ledger: ownerLedger,
            adapters: [ownerAdapter],
            remoteClient: OfflineSystemActionRemoteClient(),
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let owned = try makeProposal()
        try await ownerCoordinator.saveProposal(owned)
        try await ownerCoordinator.decide(try approval(for: owned))
        await XCTAssertThrowsErrorAsync {
            _ = try await ownerCoordinator.execute(proposalID: owned.id, mode: .automatic)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionRemoteError, .networkUnavailable)
        }
        let ownerExecuteCalls = await ownerAdapter.executeCallCount()
        XCTAssertEqual(ownerExecuteCalls, 0)
        let ownerPlan = try await ownerLedger.snapshot().executions.first
        XCTAssertEqual(ownerPlan?.state, .claimingRemote)
        await XCTAssertThrowsErrorAsync {
            _ = try await ownerCoordinator.execute(proposalID: owned.id, mode: .offline)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionLedgerError, .invalidTransition)
        }

        let otherRoot = vaultRoot.appendingPathComponent("other-device", isDirectory: true)
        let otherAdapter = FakeSystemActionAdapter(kind: .reminder)
        let otherLedger = SystemActionLedger(vaultRootURL: otherRoot, deviceID: deviceID)
        let otherCoordinator = SystemActionCoordinator(
            ledger: otherLedger,
            adapters: [otherAdapter],
            remoteClient: OfflineSystemActionRemoteClient(),
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let notOwned = try SystemActionProposal(
            payload: .reminder(.init(title: "Other owner")),
            title: "Other owner",
            rationale: "Ownership test",
            creatorSource: .localAgent,
            creatorDeviceID: "different-device",
            targetDevice: .creatingDevice,
            createdAt: now
        )
        try await otherCoordinator.saveProposal(notOwned)
        try await otherCoordinator.decide(try SystemActionDecision(
            proposalID: notOwned.id,
            proposalRevision: notOwned.revision,
            payloadHash: notOwned.payloadHash,
            outcome: .approved,
            decidedAt: now,
            deviceID: deviceID
        ))
        await XCTAssertThrowsErrorAsync {
            _ = try await otherCoordinator.execute(proposalID: notOwned.id, mode: .automatic)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionRemoteError, .networkUnavailable)
        }
        let otherExecuteCalls = await otherAdapter.executeCallCount()
        XCTAssertEqual(otherExecuteCalls, 0)
    }

    func testOfflineAndAutomaticFallbackFailClosedWithoutAuthenticatedSession() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: OfflineSystemActionRemoteClient(),
            deviceID: deviceID,
            authenticationVerifier: { false },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await coordinator.saveProposal(proposal)
        try await coordinator.decide(try approval(for: proposal))

        for mode in [SystemActionCoordinatorExecutionMode.offline, .automatic] {
            await XCTAssertThrowsErrorAsync {
                _ = try await coordinator.execute(proposalID: proposal.id, mode: mode)
            } verify: { error in
                XCTAssertEqual(error as? SystemActionCoordinatorError, .authenticationRequired)
            }
        }
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 0)
    }

    func testInterruptedExecutionReconcilesBeforeRetry() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready(let interrupted) = initial else { return XCTFail("Expected ready") }

        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [.success(.init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "reminder_created")
            ))],
            reconciliationResults: [.success(.init(disposition: .safeToRetry))]
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(5) }
        )
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        XCTAssertNotEqual(receipt.operationID, interrupted.operationID)
        XCTAssertEqual(receipt.attempt, 2)
        XCTAssertEqual(receipt.outcome, .succeeded)
        let reconcileCalls = await adapter.reconcileCallCount()
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(reconcileCalls, 1)
        XCTAssertEqual(executeCalls, 1)
    }

    func testAmbiguousReconciliationNeverBlindlyExecutesAgain() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .offline,
            now: now
        )
        guard case .ready = initial else { return XCTFail("Expected ready") }

        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            reconciliationResults: [.success(.init(
                disposition: .ambiguous,
                errorCode: "native_state_ambiguous"
            ))]
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(5) }
        )
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(receipt.outcome, .ambiguous)
        XCTAssertEqual(receipt.reconciliationState, .ambiguous)
        let executeCalls = await adapter.executeCallCount()
        let reconcileCalls = await adapter.reconcileCallCount()
        XCTAssertEqual(executeCalls, 0)
        XCTAssertEqual(reconcileCalls, 1)
    }

    func testUndoUsesOriginalDeviceMaterialAndSeparateReceipt() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [.success(.init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "reminder_created"),
                localMaterial: .init(externalIdentifier: "device-only-id")
            ))],
            undoResults: [.success(.init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "reminder_deleted")
            ))]
        )
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        let executeReceipt = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        try await coordinator.decide(try approval(for: proposal, phase: .undo))
        let undoReceipt = try await coordinator.undo(proposalID: proposal.id, mode: .offline)

        XCTAssertEqual(executeReceipt.phase, .execute)
        XCTAssertEqual(undoReceipt.phase, .undo)
        XCTAssertEqual(undoReceipt.outcome, .succeeded)
        let undoIdentifier = await adapter.lastUndoExternalIdentifier()
        let undoCalls = await adapter.undoCallCount()
        XCTAssertEqual(undoIdentifier, "device-only-id")
        XCTAssertEqual(undoCalls, 1)
    }

    func testInterruptedUndoReconciliationReceivesOriginalDeviceMaterial() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            executeResults: [.success(.init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "reminder_created"),
                localMaterial: .init(externalIdentifier: "original-device-id")
            ))],
            reconciliationResults: [.success(.init(
                disposition: .confirmed,
                confirmedResult: .init(outcome: .succeeded)
            ))]
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let initialCoordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await initialCoordinator.saveProposal(proposal)
        try await initialCoordinator.decide(try approval(for: proposal))
        _ = try await initialCoordinator.execute(proposalID: proposal.id, mode: .offline)
        try await initialCoordinator.decide(try approval(for: proposal, phase: .undo))
        _ = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .undo,
            coordination: .offline,
            now: now.addingTimeInterval(1)
        )

        let recovered = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(2) }
        )
        let receipt = try await recovered.undo(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(receipt.outcome, .succeeded)
        let materialID = await adapter.lastReconcileExternalIdentifier()
        XCTAssertEqual(materialID, "original-device-id")
    }

    func testOnlineExecutionPushesApprovalAndUsesExactLease() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let remote = FakeSystemActionRemoteClient(deviceID: deviceID, now: now)
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await coordinator.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now
        ))
        try await coordinator.saveProposal(proposal)
        let exactApproval = try approval(for: proposal)
        try await coordinator.decide(exactApproval)

        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        let repeated = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        XCTAssertEqual(receipt.outcome, .succeeded)
        XCTAssertEqual(repeated.id, receipt.id)
        let claimCalls = await remote.claimCallCount()
        let claimOperationID = await remote.lastClaimOperationID()
        let pushedOperations = await remote.pushedOperationCount()
        let leaseID = await adapter.lastLeaseID()
        XCTAssertEqual(claimCalls, 1)
        XCTAssertEqual(claimOperationID, receipt.operationID)
        XCTAssertNotEqual(claimOperationID, exactApproval.id)
        XCTAssertGreaterThanOrEqual(pushedOperations, 2)
        XCTAssertNotNil(leaseID)
    }

    func testOnlineNativeSuccessReturnsWhileReceiptPushIsPending() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            failingPushCalls: [2]
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await coordinator.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now
        ))
        try await coordinator.saveProposal(proposal)
        try await coordinator.decide(try approval(for: proposal))

        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        XCTAssertEqual(receipt.outcome, .succeeded)
        let pendingAfterFailure = try await ledger.pendingOutbox()
        XCTAssertTrue(pendingAfterFailure.contains { operation in
            guard case .receipt(let queued) = operation.payload else { return false }
            return queued.id == receipt.id
        })

        let repeated = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        XCTAssertEqual(repeated.id, receipt.id)
        let pendingAfterRetry = try await ledger.pendingOutbox()
        XCTAssertTrue(pendingAfterRetry.isEmpty)
    }

    func testTerminalRejectedEnvelopeDoesNotStarveNextAttempt() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            rejectingPushCalls: [1]
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await coordinator.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: true,
            isSynchronized: true,
            disclosureLevel: .fullProposal,
            updatedAt: now
        ))
        try await coordinator.saveProposal(proposal)
        try await coordinator.decide(try approval(for: proposal))

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionCoordinatorError, .remoteRejected("conflict"))
        }
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        XCTAssertEqual(receipt.outcome, .succeeded)
    }

    func testRemoteAlreadyCompletedPullsHistoricalReceiptWithoutNativeExecution() async throws {
        let proposal = try makeProposal()
        let remoteReceipt = try SystemActionReceipt(
            operationID: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            attempt: 1,
            outcome: .succeeded,
            deviceID: "other-device",
            boundedResult: .init(summaryCode: "reminder_created"),
            reconciliationState: .notNeeded,
            rollbackCapability: .reversible,
            startedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            claimResults: [.alreadyCompleted(receiptID: remoteReceipt.id)],
            pullPages: [.init(
                fromCursor: 0,
                nextCursor: 1,
                hasMore: false,
                changes: [.init(sequence: 1, payload: .receipt(remoteReceipt))]
            )]
        )
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        try await coordinator.saveProposal(proposal)
        try await coordinator.decide(try approval(for: proposal))

        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        XCTAssertEqual(receipt.id, remoteReceipt.id)
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 0)
    }

    func testRemoteBusyFailsClosedWithoutNativeExecution() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            claimResults: [.busy(expiresAt: now.addingTimeInterval(60))]
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await coordinator.saveProposal(proposal)
        try await coordinator.decide(try approval(for: proposal))
        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        } verify: { error in
            XCTAssertEqual(
                error as? SystemActionCoordinatorError,
                .remoteBusy(self.now.addingTimeInterval(60))
            )
        }
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 0)
    }

    func testAutomaticLostClaimResponseFailsClosedThenReplaysSameAttemptAndAdvancesAfterTerminalReceipt() async throws {
        let proposal = try makeProposal()
        let firstLeaseID = UUID()
        let terminalReceipt = try SystemActionReceipt(
            operationID: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            attempt: 1,
            outcome: .failed,
            deviceID: "remote:\(SystemActionRemoteContractMapper.hash(deviceID))",
            executionMode: .onlineLease,
            leaseID: firstLeaseID,
            errorCode: "permission_denied",
            reconciliationState: .notNeeded,
            rollbackCapability: .none,
            startedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        let retryLease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            claimFailures: [.networkUnavailable],
            claimResults: [
                .attemptCompleted(receiptID: terminalReceipt.id),
                .leased(retryLease),
            ],
            pullPages: [.init(
                fromCursor: 0,
                nextCursor: 1,
                hasMore: false,
                changes: [.init(sequence: 1, payload: .receipt(terminalReceipt))]
            )]
        )
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let firstCoordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        try await firstCoordinator.saveProposal(proposal)
        try await firstCoordinator.decide(try approval(for: proposal))

        await XCTAssertThrowsErrorAsync {
            _ = try await firstCoordinator.execute(proposalID: proposal.id, mode: .automatic)
        } verify: { error in
            XCTAssertEqual(error as? SystemActionRemoteError, .networkUnavailable)
        }
        let callsAfterLostClaim = await adapter.executeCallCount()
        XCTAssertEqual(callsAfterLostClaim, 0)
        let persistedPlan = try await ledger.snapshot().executions.first
        XCTAssertEqual(persistedPlan?.state, .claimingRemote)

        let restartedLedger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let restarted = SystemActionCoordinator(
            ledger: restartedLedger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(2) }
        )
        let imported = try await restarted.execute(proposalID: proposal.id, mode: .automatic)
        XCTAssertEqual(imported.id, terminalReceipt.id)
        XCTAssertEqual(imported.outcome, .failed)
        let assimilated = try await restartedLedger.snapshot().executions.first
        XCTAssertEqual(assimilated?.state, .completed)

        let retried = try await restarted.execute(proposalID: proposal.id, mode: .automatic)
        let claimIDs = await remote.allClaimOperationIDs()
        XCTAssertEqual(claimIDs.count, 3)
        XCTAssertEqual(claimIDs[0], persistedPlan?.operationID)
        XCTAssertEqual(claimIDs[1], persistedPlan?.operationID)
        XCTAssertNotEqual(claimIDs[2], persistedPlan?.operationID)
        XCTAssertEqual(retried.attempt, 2)
        XCTAssertEqual(retried.operationID, claimIDs[2])
        XCTAssertEqual(retried.leaseID, retryLease.id)
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 1)
    }

    func testOtherDeviceSameAttemptDoesNotConsumeExpiredInterruptedLease() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let oldLease = SystemActionExecutionLease(
            id: UUID(), proposalID: proposal.id, phase: .execute,
            proposalRevision: proposal.revision, payloadHash: proposal.payloadHash,
            deviceID: deviceID, issuedAt: now, expiresAt: now.addingTimeInterval(1)
        )
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id, phase: .execute,
            coordination: .leased(oldLease), now: now
        )
        guard case .ready(let interrupted) = initial else { return XCTFail("Expected execution") }
        let otherDeviceReceipt = try SystemActionReceipt(
            operationID: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            attempt: interrupted.attempt,
            outcome: .failed,
            deviceID: "remote:\(SystemActionRemoteContractMapper.hash("other-device"))",
            executionMode: .onlineLease,
            leaseID: UUID(),
            errorCode: "other_device_failed",
            reconciliationState: .notNeeded,
            rollbackCapability: .none,
            startedAt: now,
            completedAt: now.addingTimeInterval(1)
        )
        try await ledger.applyRemotePage(.init(
            fromCursor: 0,
            nextCursor: 1,
            hasMore: false,
            changes: [.init(sequence: 1, payload: .receipt(otherDeviceReceipt))]
        ))
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID, now: now, claimResults: []
        )
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            reconciliationResults: [.success(.init(
                disposition: .confirmed,
                confirmedResult: .init(outcome: .succeeded)
            ))]
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger, adapters: [adapter], remoteClient: remote,
            deviceID: deviceID, authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(5) }
        )
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        let claimIDs = await remote.allClaimOperationIDs()
        XCTAssertTrue(claimIDs.isEmpty)
        XCTAssertEqual(receipt.operationID, interrupted.operationID)
        XCTAssertEqual(receipt.attempt, 1)
        XCTAssertEqual(receipt.leaseID, oldLease.id)
        let receipts = try await ledger.receipts(proposalID: proposal.id)
        XCTAssertEqual(receipts.count, 2)
    }

    func testExpiredInterruptedLeaseIsRefreshedBeforeAmbiguousReconciliationReceipt() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let oldLease = SystemActionExecutionLease(
            id: UUID(), proposalID: proposal.id, phase: .execute,
            proposalRevision: proposal.revision, payloadHash: proposal.payloadHash,
            deviceID: deviceID, issuedAt: now, expiresAt: now.addingTimeInterval(1)
        )
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id, phase: .execute,
            coordination: .leased(oldLease), now: now
        )
        guard case .ready(let interrupted) = initial else { return XCTFail("Expected execution") }
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID, now: now, claimResults: []
        )
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            reconciliationResults: [.success(.init(
                disposition: .ambiguous,
                errorCode: "native_state_ambiguous"
            ))]
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger, adapters: [adapter], remoteClient: remote,
            deviceID: deviceID, authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(5) }
        )
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        let claimIDs = await remote.allClaimOperationIDs()
        XCTAssertTrue(claimIDs.isEmpty)
        XCTAssertEqual(receipt.operationID, interrupted.operationID)
        XCTAssertEqual(receipt.attempt, 1)
        XCTAssertEqual(receipt.leaseID, oldLease.id)
        XCTAssertEqual(receipt.outcome, .ambiguous)
    }

    func testPullCommitsChildAndLaterProposalAtomicallyAcrossPages() async throws {
        let proposal = try makeProposal().withLifecycleState(.approved)
        let decision = try approval(for: proposal)
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            pullPages: [
                .init(
                    fromCursor: 0,
                    nextCursor: 1,
                    hasMore: true,
                    changes: [.init(sequence: 1, payload: .decision(decision))]
                ),
                .init(
                    fromCursor: 1,
                    nextCursor: 2,
                    hasMore: false,
                    changes: [.init(sequence: 2, payload: .proposal(proposal))]
                ),
            ]
        )
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let report = try await coordinator.sync(pageLimit: 1)
        let storedProposal = try await ledger.proposal(id: proposal.id)
        let storedDecisions = try await ledger.decisions(proposalID: proposal.id)
        XCTAssertEqual(report.pulledCount, 2)
        XCTAssertEqual(storedProposal?.revision, 1)
        XCTAssertEqual(storedDecisions.count, 1)
    }

    func testExpiredLeaseSafeRetryUsesRenewedLease() async throws {
        let proposal = try makeProposal()
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        try await ledger.saveProposal(proposal, now: now)
        try await ledger.recordDecision(try approval(for: proposal), now: now)
        let oldLease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(1)
        )
        let initial = try await ledger.prepareExecution(
            proposalID: proposal.id,
            phase: .execute,
            coordination: .leased(oldLease),
            now: now
        )
        guard case .ready(let interrupted) = initial else { return XCTFail("Expected interrupted attempt") }
        let retryLease = SystemActionExecutionLease(
            id: UUID(),
            proposalID: proposal.id,
            phase: .execute,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let remote = FakeSystemActionRemoteClient(
            deviceID: deviceID,
            now: now,
            claimResults: [.leased(retryLease)]
        )
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            reconciliationResults: [.success(.init(disposition: .safeToRetry))]
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            remoteClient: remote,
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now.addingTimeInterval(5) }
        )
        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .onlineRequired)
        XCTAssertEqual(receipt.leaseID, retryLease.id)
        let usedLeaseID = await adapter.lastLeaseID()
        let claimIDs = await remote.allClaimOperationIDs()
        XCTAssertEqual(usedLeaseID, retryLease.id)
        XCTAssertEqual(claimIDs.count, 1)
        XCTAssertNotEqual(claimIDs[0], interrupted.operationID)
    }

    func testCapabilitySnapshotComesFromAdapterWithoutSyncedPermissionAssumption() async throws {
        let adapter = FakeSystemActionAdapter(
            kind: .reminder,
            capability: .init(
                kind: .reminder,
                availability: .requiresPermission,
                authorization: .notDetermined,
                reasonCode: "confirm_to_request"
            )
        )
        let (coordinator, _) = try await makeCoordinator(adapter: adapter, approved: false)
        let snapshots = await coordinator.capabilitySnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].authorization, .notDetermined)
        XCTAssertEqual(snapshots[0].availability, .requiresPermission)
    }

    func testDisabledCapabilityPolicyBlocksExecuteBeforeNativeAdapter() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        try await coordinator.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled,
            updatedAt: now
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        } verify: { error in
            XCTAssertEqual(
                error as? SystemActionCoordinatorError,
                .capabilityNotOffered(.reminders)
            )
            XCTAssertEqual(
                (error as? SystemActionCodedError)?.systemActionErrorCode,
                "capability_not_offered"
            )
        }
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 0)
    }

    func testDisabledCapabilityPolicyBlocksUndoBeforeNativeAdapter() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        _ = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        try await coordinator.decide(try approval(for: proposal, phase: .undo))
        try await coordinator.setCapabilityPolicy(try .init(
            capability: .reminders,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled,
            updatedAt: now
        ))

        await XCTAssertThrowsErrorAsync {
            _ = try await coordinator.undo(proposalID: proposal.id, mode: .offline)
        } verify: { error in
            XCTAssertEqual(
                error as? SystemActionCoordinatorError,
                .capabilityNotOffered(.reminders)
            )
        }
        let undoCalls = await adapter.undoCallCount()
        XCTAssertEqual(undoCalls, 0)
    }

    func testDeletedCapabilityPolicyRestoresDefaultOfferedBehavior() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        let policyID = UUID()
        try await coordinator.setCapabilityPolicy(try .init(
            id: policyID,
            capability: .reminders,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled,
            updatedAt: now
        ))
        try await coordinator.setCapabilityPolicy(try .init(
            id: policyID,
            revision: 2,
            capability: .reminders,
            isOffered: false,
            isSynchronized: false,
            disclosureLevel: .disabled,
            updatedAt: now.addingTimeInterval(1),
            deletedAt: now.addingTimeInterval(1)
        ))

        let receipt = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(receipt.outcome, .succeeded)
        let executeCalls = await adapter.executeCallCount()
        XCTAssertEqual(executeCalls, 1)
    }

    func testCoordinatorExecutionDoesNotTouchRawMemoBytes() async throws {
        let rawURL = vaultRoot.appendingPathComponent("raw/2026-08-26.md")
        let bytes = Data("raw vault bytes stay authoritative".utf8)
        try bytes.write(to: rawURL)
        let adapter = FakeSystemActionAdapter(kind: .reminder)
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        _ = try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        try await coordinator.decide(try approval(for: proposal, phase: .undo))
        _ = try await coordinator.undo(proposalID: proposal.id, mode: .offline)
        XCTAssertEqual(try Data(contentsOf: rawURL), bytes)
    }

    func testAccountTransitionBarrierWaitsForNativeResultAndReceiptPersistence() async throws {
        let adapter = FakeSystemActionAdapter(kind: .reminder, blocksExecute: true)
        let (coordinator, proposal) = try await makeCoordinator(adapter: adapter, approved: true)
        let execution = Task {
            try await coordinator.execute(proposalID: proposal.id, mode: .offline)
        }
        await adapter.waitUntilExecuteStarted()

        let transition = Task {
            await coordinator.beginAccountTransition()
            await adapter.markTransitionEntered()
            await coordinator.endAccountTransition()
        }
        for _ in 0..<20 { await Task.yield() }
        let enteredBeforeRelease = await adapter.didTransitionEnter()
        XCTAssertFalse(enteredBeforeRelease)

        await adapter.releaseExecute()
        let receipt = try await execution.value
        await transition.value
        let enteredAfterRelease = await adapter.didTransitionEnter()
        let receipts = try await coordinator.ledger.receipts(proposalID: proposal.id)
        XCTAssertTrue(enteredAfterRelease)
        XCTAssertEqual(receipts.first?.id, receipt.id)
    }

    // MARK: Helpers

    private func makeCoordinator(
        adapter: FakeSystemActionAdapter,
        approved: Bool
    ) async throws -> (SystemActionCoordinator, SystemActionProposal) {
        let ledger = SystemActionLedger(vaultRootURL: vaultRoot, deviceID: deviceID)
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: [adapter],
            deviceID: deviceID,
            authenticationVerifier: { true },
            clock: { self.now }
        )
        let proposal = try makeProposal()
        try await coordinator.saveProposal(proposal)
        if approved { try await coordinator.decide(try approval(for: proposal)) }
        return (coordinator, proposal)
    }

    private func makeProposal(title: String = "Call Sam") throws -> SystemActionProposal {
        try SystemActionProposal(
            payload: .reminder(.init(title: title, dueAt: now.addingTimeInterval(600))),
            title: "Create reminder",
            rationale: "A follow-up exists.",
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
}

private enum FakeSystemActionError: SystemActionCodedError, SystemActionAmbiguousError {
    case permissionDenied
    case ambiguous

    var systemActionErrorCode: String {
        switch self {
        case .permissionDenied: return "permission_denied"
        case .ambiguous: return "native_state_ambiguous"
        }
    }

    var isSystemActionAmbiguous: Bool { self == .ambiguous }
}

private actor FakeSystemActionAdapter: SystemActionNativeAdapter {
    nonisolated let kind: SystemActionKind
    nonisolated let rollbackCapability: SystemActionRollbackCapability = .reversible

    private var executeResults: [Result<SystemActionAdapterResult, FakeSystemActionError>]
    private var reconciliationResults: [Result<SystemActionReconciliationResult, FakeSystemActionError>]
    private var undoResults: [Result<SystemActionAdapterResult, FakeSystemActionError>]
    private let capability: SystemActionCapabilitySnapshot
    private var executeCalls = 0
    private var reconcileCalls = 0
    private var undoCalls = 0
    private var undoExternalIdentifier: String?
    private var reconcileExternalIdentifier: String?
    private var leaseID: UUID?
    private let blocksExecute: Bool
    private var executeStarted = false
    private var executeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var executeRelease: CheckedContinuation<Void, Never>?
    private var transitionEntered = false

    init(
        kind: SystemActionKind,
        executeResults: [Result<SystemActionAdapterResult, FakeSystemActionError>] = [
            .success(.init(outcome: .succeeded, boundedResult: .init(summaryCode: "created"), localMaterial: .init(externalIdentifier: "native-id")))
        ],
        reconciliationResults: [Result<SystemActionReconciliationResult, FakeSystemActionError>] = [],
        undoResults: [Result<SystemActionAdapterResult, FakeSystemActionError>] = [
            .success(.init(outcome: .succeeded, boundedResult: .init(summaryCode: "undone")))
        ],
        capability: SystemActionCapabilitySnapshot? = nil,
        blocksExecute: Bool = false
    ) {
        self.kind = kind
        self.executeResults = executeResults
        self.reconciliationResults = reconciliationResults
        self.undoResults = undoResults
        self.capability = capability ?? .init(
            kind: kind,
            availability: .available,
            authorization: .notApplicable
        )
        self.blocksExecute = blocksExecute
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot { capability }

    func execute(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext
    ) async throws -> SystemActionAdapterResult {
        executeCalls += 1
        leaseID = context.lease?.id
        if blocksExecute {
            executeStarted = true
            let waiters = executeStartWaiters
            executeStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { executeRelease = $0 }
        }
        guard !executeResults.isEmpty else {
            return .init(outcome: .succeeded, boundedResult: .init(summaryCode: "created"))
        }
        return try executeResults.removeFirst().get()
    }

    func reconcile(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionReconciliationResult {
        reconcileCalls += 1
        reconcileExternalIdentifier = material?.externalIdentifier
        guard !reconciliationResults.isEmpty else {
            return .init(disposition: .needsReview, errorCode: "no_reconciliation_result")
        }
        return try reconciliationResults.removeFirst().get()
    }

    func undo(
        proposal: SystemActionProposal,
        originalReceipt: SystemActionReceipt,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionAdapterResult {
        undoCalls += 1
        undoExternalIdentifier = material?.externalIdentifier
        guard !undoResults.isEmpty else { return .init(outcome: .failed, errorCode: "no_undo_result") }
        return try undoResults.removeFirst().get()
    }

    func executeCallCount() -> Int { executeCalls }
    func reconcileCallCount() -> Int { reconcileCalls }
    func undoCallCount() -> Int { undoCalls }
    func lastUndoExternalIdentifier() -> String? { undoExternalIdentifier }
    func lastReconcileExternalIdentifier() -> String? { reconcileExternalIdentifier }
    func lastLeaseID() -> UUID? { leaseID }
    func waitUntilExecuteStarted() async {
        if executeStarted { return }
        await withCheckedContinuation { executeStartWaiters.append($0) }
    }
    func releaseExecute() {
        executeRelease?.resume()
        executeRelease = nil
    }
    func markTransitionEntered() { transitionEntered = true }
    func didTransitionEnter() -> Bool { transitionEntered }
}

private actor FakeSystemActionRemoteClient: SystemActionRemoteClientProtocol {
    private let deviceID: String
    private let now: Date
    private var pushed = 0
    private var claims = 0
    private var claimOperationIDs: [UUID] = []
    private var claimFailures: [SystemActionRemoteError]
    private var claimResults: [SystemActionExecutionClaimResult]
    private var pullPages: [SystemActionRemotePullPage]
    private var pushCalls = 0
    private let failingPushCalls: Set<Int>
    private let rejectingPushCalls: Set<Int>

    init(
        deviceID: String,
        now: Date,
        claimFailures: [SystemActionRemoteError] = [],
        claimResults: [SystemActionExecutionClaimResult] = [],
        pullPages: [SystemActionRemotePullPage] = [],
        failingPushCalls: Set<Int> = [],
        rejectingPushCalls: Set<Int> = []
    ) {
        self.deviceID = deviceID
        self.now = now
        self.claimFailures = claimFailures
        self.claimResults = claimResults
        self.pullPages = pullPages
        self.failingPushCalls = failingPushCalls
        self.rejectingPushCalls = rejectingPushCalls
    }

    func push(operations: [SystemActionOutboxOperation]) async throws -> SystemActionRemotePushResult {
        pushCalls += 1
        pushed += operations.count
        if failingPushCalls.contains(pushCalls) {
            throw SystemActionRemoteError.networkUnavailable
        }
        if rejectingPushCalls.contains(pushCalls), let first = operations.first {
            let rejectedRemote = try SystemActionRemoteContractMapper.operation(from: first)
            let accepted = try operations.dropFirst().enumerated().map { offset, operation in
                let remote = try SystemActionRemoteContractMapper.operation(from: operation)
                return SystemActionRemoteAcknowledgement(
                    operationID: operation.operationID,
                    entityType: remote.entityType,
                    entityID: remote.entityID,
                    revision: remote.revision,
                    status: "applied",
                    changeSequence: Int64(offset + 1),
                    record: remote.record
                )
            }
            return .init(
                accepted: accepted,
                rejected: [.init(
                    operationID: first.operationID,
                    entityType: rejectedRemote.entityType,
                    entityID: rejectedRemote.entityID,
                    errorCode: "conflict"
                )]
            )
        }
        return SystemActionRemotePushResult(
            accepted: try operations.enumerated().map { offset, operation in
                let remote = try SystemActionRemoteContractMapper.operation(from: operation)
                return .init(
                    operationID: operation.operationID,
                    entityType: remote.entityType,
                    entityID: remote.entityID,
                    revision: remote.revision,
                    status: "applied",
                    changeSequence: Int64(offset + 1),
                    record: remote.record
                )
            },
            rejected: []
        )
    }

    func pull(after cursor: Int64, limit: Int) async throws -> SystemActionRemotePullPage {
        if !pullPages.isEmpty { return pullPages.removeFirst() }
        return .init(fromCursor: cursor, nextCursor: cursor, hasMore: false, changes: [])
    }

    func claimExecution(_ request: SystemActionExecutionClaimRequest) async throws -> SystemActionExecutionClaimResult {
        claims += 1
        claimOperationIDs.append(request.operationID)
        if !claimFailures.isEmpty { throw claimFailures.removeFirst() }
        if !claimResults.isEmpty { return claimResults.removeFirst() }
        return .leased(.init(
            id: UUID(),
            proposalID: request.proposalID,
            phase: request.phase,
            proposalRevision: request.proposalRevision,
            payloadHash: request.payloadHash,
            deviceID: deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(120)
        ))
    }

    func pushedOperationCount() -> Int { pushed }
    func claimCallCount() -> Int { claims }
    func lastClaimOperationID() -> UUID? { claimOperationIDs.last }
    func allClaimOperationIDs() -> [UUID] { claimOperationIDs }
}

private actor OfflineSystemActionRemoteClient: SystemActionRemoteClientProtocol {
    func push(operations: [SystemActionOutboxOperation]) async throws -> SystemActionRemotePushResult {
        throw SystemActionRemoteError.networkUnavailable
    }

    func pull(after cursor: Int64, limit: Int) async throws -> SystemActionRemotePullPage {
        throw SystemActionRemoteError.networkUnavailable
    }

    func claimExecution(_ request: SystemActionExecutionClaimRequest) async throws -> SystemActionExecutionClaimResult {
        throw SystemActionRemoteError.networkUnavailable
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
