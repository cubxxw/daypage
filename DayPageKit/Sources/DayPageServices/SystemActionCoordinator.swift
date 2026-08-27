import Foundation
import DayPageModels
import DayPageStorage

public enum SystemActionCoordinatorError: Error, Equatable, Sendable, SystemActionCodedError {
    case adapterUnavailable(String)
    case invalidAdapterResult
    case originalReceiptMissing
    case capabilityNotOffered(SystemActionCapability)
    case remoteRejected(String)
    case remoteBusy(Date?)
    case remoteCompletedReceiptMissing(UUID)
    case pullPageLimitExceeded
    case authenticationRequired

    public var systemActionErrorCode: String {
        switch self {
        case .adapterUnavailable: return "adapter_unavailable"
        case .invalidAdapterResult: return "invalid_adapter_result"
        case .originalReceiptMissing: return "original_receipt_missing"
        case .capabilityNotOffered: return "capability_not_offered"
        case .remoteRejected: return "remote_rejected"
        case .remoteBusy: return "remote_busy"
        case .remoteCompletedReceiptMissing: return "remote_completed_receipt_missing"
        case .pullPageLimitExceeded: return "pull_page_limit_exceeded"
        case .authenticationRequired: return "authentication_required"
        }
    }
}

public enum SystemActionCoordinatorExecutionMode: Sendable {
    case automatic
    case offline
    case onlineRequired
}

public struct SystemActionBatchItemResult: Sendable {
    public let proposalID: UUID
    public let phase: SystemActionExecutionPhase
    public let receipt: SystemActionReceipt?
    public let errorCode: String?

    public init(
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        receipt: SystemActionReceipt?,
        errorCode: String?
    ) {
        self.proposalID = proposalID
        self.phase = phase
        self.receipt = receipt
        self.errorCode = errorCode
    }
}

public struct SystemActionSyncReport: Equatable, Sendable {
    public let pushedCount: Int
    public let rejectedCount: Int
    public let pulledCount: Int
    public let cursor: Int64

    public init(pushedCount: Int, rejectedCount: Int, pulledCount: Int, cursor: Int64) {
        self.pushedCount = pushedCount
        self.rejectedCount = rejectedCount
        self.pulledCount = pulledCount
        self.cursor = cursor
    }
}

/// Serializes proposal execution so two UI/system entry points in one process
/// cannot race the same action. The durable ledger still owns crash recovery
/// and cross-process truth; this actor is orchestration, not persistence.
public actor SystemActionCoordinator {
    public typealias Clock = @Sendable () -> Date
    public typealias AuthenticationVerifier = @Sendable () async -> Bool

    public let ledger: SystemActionLedger
    public let deviceID: String

    private let adapters: [SystemActionKind: any SystemActionNativeAdapter]
    private let remoteClient: (any SystemActionRemoteClientProtocol)?
    private let errorCodeMapper: any SystemActionErrorCodeMapping
    private let clock: Clock
    private let authenticationVerifier: AuthenticationVerifier
    private var activeCriticalSections = 0
    private var accountTransitionDepth = 0
    private var accountTransitionWaiters: [CheckedContinuation<Void, Never>] = []

    private enum ResolvedCoordination {
        case execution(SystemActionCoordination)
        case alreadyCompleted(receiptID: UUID)
        case attemptCompleted(receiptID: UUID)
    }

    private enum AuthorizedExecution {
        case ready(SystemActionExecutionRecord)
        case remoteReceipt(SystemActionReceipt)
    }

    public init(
        ledger: SystemActionLedger,
        adapters: [any SystemActionNativeAdapter],
        remoteClient: (any SystemActionRemoteClientProtocol)? = nil,
        deviceID: String,
        authenticationVerifier: @escaping AuthenticationVerifier = { false },
        errorCodeMapper: any SystemActionErrorCodeMapping = DefaultSystemActionErrorCodeMapper(),
        clock: @escaping Clock = { Date() }
    ) {
        var indexed: [SystemActionKind: any SystemActionNativeAdapter] = [:]
        for adapter in adapters where indexed[adapter.kind] == nil {
            indexed[adapter.kind] = adapter
        }
        self.ledger = ledger
        self.adapters = indexed
        self.remoteClient = remoteClient
        self.deviceID = deviceID
        self.authenticationVerifier = authenticationVerifier
        self.errorCodeMapper = errorCodeMapper
        self.clock = clock
    }

    public func saveProposal(_ proposal: SystemActionProposal) async throws {
        try beginCriticalSection()
        defer { endCriticalSection() }
        try await ledger.saveProposal(proposal, now: clock())
    }

    public func decide(_ decision: SystemActionDecision) async throws {
        try beginCriticalSection()
        defer { endCriticalSection() }
        try await ledger.recordDecision(decision, now: clock())
    }

    public func setCapabilityPolicy(_ policy: SystemActionCapabilityPolicy) async throws {
        try beginCriticalSection()
        defer { endCriticalSection() }
        try await ledger.setCapabilityPolicy(policy, now: clock())
    }

    /// Prevents an account transition from clearing a lease, operation plan,
    /// local rollback material, or terminal receipt while a coordinator call
    /// is suspended in network or Apple-framework I/O. New mutations fail
    /// closed once a transition has requested the barrier.
    public func beginAccountTransition() async {
        accountTransitionDepth += 1
        guard activeCriticalSections > 0 else { return }
        await withCheckedContinuation { continuation in
            accountTransitionWaiters.append(continuation)
        }
    }

    public func endAccountTransition() {
        precondition(accountTransitionDepth > 0)
        accountTransitionDepth -= 1
    }

    public func capabilitySnapshots() async -> [SystemActionCapabilitySnapshot] {
        var values: [SystemActionCapabilitySnapshot] = []
        for kind in adapters.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let adapter = adapters[kind] {
                values.append(await adapter.capabilitySnapshot())
            }
        }
        return values
    }

    public func execute(
        proposalID: UUID,
        mode: SystemActionCoordinatorExecutionMode = .automatic
    ) async throws -> SystemActionReceipt {
        try beginCriticalSection()
        defer { endCriticalSection() }
        return try await perform(proposalID: proposalID, phase: .execute, mode: mode)
    }

    public func undo(
        proposalID: UUID,
        mode: SystemActionCoordinatorExecutionMode = .automatic
    ) async throws -> SystemActionReceipt {
        try beginCriticalSection()
        defer { endCriticalSection() }
        return try await perform(proposalID: proposalID, phase: .undo, mode: mode)
    }

    /// Executes independent items without pretending the batch is atomic.
    /// A failure before receipt creation is returned only for that proposal;
    /// later items still run and successful siblings are never rolled back.
    public func executeBatch(
        proposalIDs: [UUID],
        mode: SystemActionCoordinatorExecutionMode = .automatic
    ) async -> [SystemActionBatchItemResult] {
        var results: [SystemActionBatchItemResult] = []
        for proposalID in proposalIDs {
            do {
                let receipt = try await execute(proposalID: proposalID, mode: mode)
                results.append(SystemActionBatchItemResult(
                    proposalID: proposalID,
                    phase: .execute,
                    receipt: receipt,
                    errorCode: receipt.errorCode
                ))
            } catch {
                results.append(SystemActionBatchItemResult(
                    proposalID: proposalID,
                    phase: .execute,
                    receipt: nil,
                    errorCode: errorCodeMapper.boundedCode(for: error)
                ))
            }
        }
        return results
    }

    public func sync(pageLimit: Int = 200) async throws -> SystemActionSyncReport {
        try beginCriticalSection()
        defer { endCriticalSection() }
        guard let remoteClient else {
            let snapshot = try await ledger.snapshot()
            return SystemActionSyncReport(
                pushedCount: 0,
                rejectedCount: 0,
                pulledCount: 0,
                cursor: snapshot.remoteCursor
            )
        }

        var pushed = 0
        var rejected = 0
        let operations = try await ledger.pendingOutbox()
        for start in stride(from: 0, to: operations.count, by: 100) {
            let end = min(start + 100, operations.count)
            let batch = Array(operations[start..<end])
            let result = try await remoteClient.push(operations: batch)
            let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.operationID, $0) })
            for acknowledgement in result.accepted {
                guard let local = byID[acknowledgement.operationID] else {
                    throw SystemActionRemoteError.invalidResponse
                }
                try await ledger.acknowledge(
                    operationID: local.operationID,
                    requestFingerprint: local.requestFingerprint
                )
                pushed += 1
            }
            for rejection in result.rejected {
                guard let local = byID[rejection.operationID] else {
                    throw SystemActionRemoteError.invalidResponse
                }
                try await ledger.discardRejected(
                    operationID: local.operationID,
                    requestFingerprint: local.requestFingerprint
                )
                rejected += 1
            }
        }

        let startCursor = try await ledger.snapshot().remoteCursor
        let combinedPage = try await collectRemoteChanges(
            remoteClient: remoteClient,
            after: startCursor,
            pageLimit: pageLimit
        )
        try await ledger.applyRemotePage(combinedPage)
        let pulled = combinedPage.changes.count
        let cursor = try await ledger.snapshot().remoteCursor
        return SystemActionSyncReport(
            pushedCount: pushed,
            rejectedCount: rejected,
            pulledCount: pulled,
            cursor: cursor
        )
    }

    // MARK: - Execution

    private func perform(
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        mode: SystemActionCoordinatorExecutionMode
    ) async throws -> SystemActionReceipt {
        try await requireAuthenticatedSession()
        guard let proposal = try await ledger.proposal(id: proposalID) else {
            throw SystemActionLedgerError.proposalNotFound
        }
        if let completed = try await ledger.receipts(proposalID: proposalID)
            .filter({ receipt in
                receipt.phase == phase
                    && receipt.proposalRevision == proposal.revision
                    && receipt.payloadHash == proposal.payloadHash
                    && receipt.outcome == .succeeded
                    && (receipt.reconciliationState == .notNeeded
                        || receipt.reconciliationState == .reconciled)
            })
            .max(by: { $0.completedAt < $1.completedAt }) {
            await publishOnlineReceiptBestEffort(completed)
            return completed
        }
        try await enforceCapabilityPolicies(for: proposal)
        guard let adapter = adapters[proposal.kind] else {
            throw SystemActionCoordinatorError.adapterUnavailable(proposal.kind.rawValue)
        }

        let preparation: SystemActionExecutionPreparation
        do {
            preparation = try await ledger.prepareExecutionPlan(
                proposalID: proposalID,
                phase: phase,
                now: clock(),
                enforceLocalExpiry: mode == .offline
                    || (mode == .automatic && remoteClient == nil)
            )
        } catch SystemActionLedgerError.capabilityNotOffered(let capability) {
            throw SystemActionCoordinatorError.capabilityNotOffered(capability)
        }
        switch preparation {
        case .alreadyCompleted(let receipt):
            return receipt
        case .ready(let planned):
            switch try await authorize(
                planned,
                proposal: proposal,
                phase: phase,
                mode: mode
            ) {
            case .ready(let execution):
                return try await callAdapter(
                    adapter,
                    proposal: proposal,
                    execution: execution,
                    phase: phase
                )
            case .remoteReceipt(let receipt):
                return receipt
            }
        case .requiresReconciliation(let execution, let material):
            return try await reconcile(
                adapter,
                proposal: proposal,
                execution: execution,
                material: material,
                phase: phase,
                mode: mode
            )
        }
    }

    private func authorize(
        _ planned: SystemActionExecutionRecord,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        mode: SystemActionCoordinatorExecutionMode
    ) async throws -> AuthorizedExecution {
        let coordinatedPlan: SystemActionExecutionRecord
        switch mode {
        case .offline:
            coordinatedPlan = planned
        case .automatic where remoteClient == nil:
            coordinatedPlan = planned
        case .automatic, .onlineRequired:
            coordinatedPlan = try await ledger.prepareRemoteClaim(
                operationID: planned.operationID
            )
        }
        let resolved = try await coordination(
            for: proposal,
            phase: phase,
            operationID: coordinatedPlan.operationID,
            mode: mode
        )
        switch resolved {
        case .alreadyCompleted(let receiptID):
            return .remoteReceipt(try await pullCompletedReceipt(
                receiptID: receiptID,
                proposal: proposal,
                phase: phase
            ))
        case .attemptCompleted(let receiptID):
            return .remoteReceipt(try await pullAttemptReceipt(
                receiptID: receiptID,
                proposal: proposal,
                planned: coordinatedPlan
            ))
        case .execution(let coordination):
            let preparation = try await ledger.authorizeExecution(
                operationID: coordinatedPlan.operationID,
                coordination: coordination,
                now: clock()
            )
            guard case .ready(let execution) = preparation else {
                throw SystemActionLedgerError.invalidTransition
            }
            return .ready(execution)
        }
    }

    private func enforceCapabilityPolicies(for proposal: SystemActionProposal) async throws {
        for capability in proposal.payload.requiredCapabilities {
            if let policy = try await ledger.capabilityPolicy(for: capability),
               !policy.isOffered {
                throw SystemActionCoordinatorError.capabilityNotOffered(capability)
            }
        }
    }

    private func coordination(
        for proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        operationID: UUID,
        mode: SystemActionCoordinatorExecutionMode
    ) async throws -> ResolvedCoordination {
        switch mode {
        case .offline:
            return try await authenticatedOfflineCoordination()
        case .automatic where remoteClient == nil:
            return try await authenticatedOfflineCoordination()
        case .automatic:
            guard let remoteClient else { throw SystemActionRemoteError.notConfigured }
            // Every remote mutation is indeterminate if its response is lost:
            // an approval/receipt push may have committed, and a claim may have
            // leased another device-visible attempt. Automatic mode therefore
            // never changes to offline after choosing a configured remote path.
            try await flushPendingOutbox(remoteClient: remoteClient)
            return try await claimOnlineExecution(
                remoteClient: remoteClient,
                proposal: proposal,
                phase: phase,
                operationID: operationID
            )
        case .onlineRequired:
            guard let remoteClient else { throw SystemActionRemoteError.notConfigured }
            try await flushPendingOutbox(remoteClient: remoteClient)
            return try await claimOnlineExecution(
                remoteClient: remoteClient,
                proposal: proposal,
                phase: phase,
                operationID: operationID
            )
        }
    }

    private func authenticatedOfflineCoordination() async throws -> ResolvedCoordination {
        try await requireAuthenticatedSession()
        return .execution(.offline)
    }

    private func requireAuthenticatedSession() async throws {
        guard await authenticationVerifier() else {
            throw SystemActionCoordinatorError.authenticationRequired
        }
    }

    private func beginCriticalSection() throws {
        guard accountTransitionDepth == 0 else {
            throw SystemActionCoordinatorError.authenticationRequired
        }
        activeCriticalSections += 1
    }

    private func endCriticalSection() {
        precondition(activeCriticalSections > 0)
        activeCriticalSections -= 1
        guard activeCriticalSections == 0 else { return }
        let waiters = accountTransitionWaiters
        accountTransitionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func flushPendingOutbox(
        remoteClient: any SystemActionRemoteClientProtocol
    ) async throws {
        // The exact approval must reach the server before a lease can be
        // claimed. A terminal rejection is removed from the transport queue
        // after its exact response is validated; immutable ledger evidence is
        // retained. This invocation still fails closed, but unrelated future
        // actions are no longer starved by the same rejected envelope.
        while true {
            let operations = Array(try await ledger.pendingOutbox().prefix(100))
            if operations.isEmpty { break }
            let result = try await remoteClient.push(operations: operations)
            let byID = Dictionary(uniqueKeysWithValues: operations.map { ($0.operationID, $0) })
            for acknowledgement in result.accepted {
                if let local = byID[acknowledgement.operationID] {
                    try await ledger.acknowledge(
                        operationID: local.operationID,
                        requestFingerprint: local.requestFingerprint
                    )
                }
            }
            for rejection in result.rejected {
                if let local = byID[rejection.operationID] {
                    try await ledger.discardRejected(
                        operationID: local.operationID,
                        requestFingerprint: local.requestFingerprint
                    )
                }
            }
            if let first = result.rejected.first {
                throw SystemActionCoordinatorError.remoteRejected(first.errorCode)
            }
            guard !result.accepted.isEmpty else {
                throw SystemActionRemoteError.exactReceiptMissing
            }
        }
    }

    private func claimOnlineExecution(
        remoteClient: any SystemActionRemoteClientProtocol,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        operationID: UUID
    ) async throws -> ResolvedCoordination {
        let decisions = try await ledger.decisions(proposalID: proposal.id)
        guard decisions
            .filter({ decision in
                decision.phase == phase
                    && decision.proposalRevision == proposal.revision
                    && decision.payloadHash == proposal.payloadHash
                    && decision.outcome == .approved
            })
            .max(by: { $0.decidedAt < $1.decidedAt }) != nil else {
            throw SystemActionLedgerError.missingExactApproval
        }
        let claim = try await remoteClient.claimExecution(SystemActionExecutionClaimRequest(
            operationID: operationID,
            proposalID: proposal.id,
            phase: phase,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            deviceID: deviceID
        ))
        switch claim {
        case .leased(let lease):
            return .execution(.leased(lease))
        case .busy(let expiresAt):
            throw SystemActionCoordinatorError.remoteBusy(expiresAt)
        case .alreadyCompleted(let receiptID):
            return .alreadyCompleted(receiptID: receiptID)
        case .attemptCompleted(let receiptID):
            return .attemptCompleted(receiptID: receiptID)
        }
    }

    private func pullCompletedReceipt(
        receiptID: UUID,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase
    ) async throws -> SystemActionReceipt {
        let receipt = try await pullRemoteReceipt(receiptID: receiptID, proposalID: proposal.id)
        return try validateCompletedReceipt(receipt, proposal: proposal, phase: phase)
    }

    private func pullAttemptReceipt(
        receiptID: UUID,
        proposal: SystemActionProposal,
        planned: SystemActionExecutionRecord
    ) async throws -> SystemActionReceipt {
        let receipt = try await pullRemoteReceipt(receiptID: receiptID, proposalID: proposal.id)
        guard receipt.phase == planned.phase,
              receipt.proposalRevision == planned.proposalRevision,
              receipt.payloadHash == planned.payloadHash,
              receipt.attempt == planned.attempt,
              receipt.outcome != .succeeded,
              receipt.executionMode == .onlineLease,
              receipt.leaseID != nil,
              receipt.deviceID == "remote:\(SystemActionRemoteContractMapper.hash(planned.deviceID))" else {
            throw SystemActionRemoteError.invalidResponse
        }
        do {
            return try await ledger.assimilateRemoteAttemptReceipt(
                operationID: planned.operationID,
                receiptID: receipt.id
            )
        } catch {
            throw SystemActionRemoteError.invalidResponse
        }
    }

    private func pullRemoteReceipt(
        receiptID: UUID,
        proposalID: UUID
    ) async throws -> SystemActionReceipt {
        guard let remoteClient else { throw SystemActionRemoteError.notConfigured }
        if let receipt = try await ledger.receipts(proposalID: proposalID)
            .first(where: { $0.id == receiptID }) {
            return receipt
        }
        let cursor = try await ledger.snapshot().remoteCursor
        let combinedPage = try await collectRemoteChanges(
            remoteClient: remoteClient,
            after: cursor,
            pageLimit: 200
        )
        try await ledger.applyRemotePage(combinedPage)
        guard let receipt = try await ledger.receipts(proposalID: proposalID)
            .first(where: { $0.id == receiptID }) else {
            throw SystemActionCoordinatorError.remoteCompletedReceiptMissing(receiptID)
        }
        return receipt
    }

    private func validateCompletedReceipt(
        _ receipt: SystemActionReceipt,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase
    ) throws -> SystemActionReceipt {
        guard receipt.phase == phase,
              receipt.proposalRevision == proposal.revision,
              receipt.payloadHash == proposal.payloadHash,
              receipt.outcome == .succeeded else {
            throw SystemActionRemoteError.invalidResponse
        }
        return receipt
    }

    /// A mutable proposal row can receive a later change sequence than its
    /// approval or receipt. Pull all bounded pages before committing so a page
    /// boundary never persists an orphan immutable record on a fresh device.
    private func collectRemoteChanges(
        remoteClient: any SystemActionRemoteClientProtocol,
        after startCursor: Int64,
        pageLimit: Int
    ) async throws -> SystemActionRemotePullPage {
        var cursor = startCursor
        var changes: [SystemActionRemoteChange] = []
        for _ in 0..<100 {
            let page = try await remoteClient.pull(after: cursor, limit: pageLimit)
            changes.append(contentsOf: page.changes)
            cursor = page.nextCursor
            if !page.hasMore {
                return SystemActionRemotePullPage(
                    fromCursor: startCursor,
                    nextCursor: cursor,
                    hasMore: false,
                    changes: changes
                )
            }
        }
        throw SystemActionCoordinatorError.pullPageLimitExceeded
    }

    private func callAdapter(
        _ adapter: any SystemActionNativeAdapter,
        proposal: SystemActionProposal,
        execution: SystemActionExecutionRecord,
        phase: SystemActionExecutionPhase
    ) async throws -> SystemActionReceipt {
        // Re-check immediately before the native side effect. Authentication
        // can change while an online claim or interrupted-operation
        // reconciliation is awaiting I/O.
        try await requireAuthenticatedSession()
        let result: SystemActionAdapterResult
        if phase == .execute {
            do {
                result = try await adapter.execute(proposal: proposal, context: execution.context)
            } catch {
                let ambiguous = (error as? SystemActionAmbiguousError)?.isSystemActionAmbiguous == true
                result = SystemActionAdapterResult(
                    outcome: ambiguous ? .ambiguous : .failed,
                    errorCode: errorCodeMapper.boundedCode(for: error),
                    reconciliationState: ambiguous ? .needsReview : .notNeeded
                )
            }
        } else {
            guard let original = try await ledger.successfulExecuteReceipt(proposalID: proposal.id) else {
                throw SystemActionCoordinatorError.originalReceiptMissing
            }
            let material = try await ledger.localMaterial(operationID: original.operationID)
            do {
                result = try await adapter.undo(
                    proposal: proposal,
                    originalReceipt: original,
                    context: execution.context,
                    material: material
                )
            } catch {
                let ambiguous = (error as? SystemActionAmbiguousError)?.isSystemActionAmbiguous == true
                result = SystemActionAdapterResult(
                    outcome: ambiguous ? .ambiguous : .failed,
                    errorCode: errorCodeMapper.boundedCode(for: error),
                    reconciliationState: ambiguous ? .needsReview : .notNeeded
                )
            }
        }
        // Persistence happens outside the adapter-error boundary. Once a
        // native call has returned, any ledger failure is indeterminate and
        // must leave the durable execution reconcilable rather than fabricate
        // a failed receipt that could permit a duplicate retry.
        return try await recordAndPublishAdapterResult(
            operationID: execution.operationID,
            result: result,
            rollbackCapability: adapter.rollbackCapability,
            completedAt: max(clock(), execution.startedAt)
        )
    }

    private func reconcile(
        _ adapter: any SystemActionNativeAdapter,
        proposal: SystemActionProposal,
        execution: SystemActionExecutionRecord,
        material: SystemActionLocalMaterial?,
        phase: SystemActionExecutionPhase,
        mode: SystemActionCoordinatorExecutionMode
    ) async throws -> SystemActionReceipt {
        var reconciliationMaterial = material
        if phase == .undo, reconciliationMaterial == nil,
           let original = try await ledger.successfulExecuteReceipt(proposalID: proposal.id) {
            reconciliationMaterial = try await ledger.localMaterial(operationID: original.operationID)
        }
        let resolution: SystemActionReconciliationResult
        do {
            resolution = try await adapter.reconcile(
                proposal: proposal,
                context: execution.context,
                material: reconciliationMaterial
            )
        } catch {
            resolution = SystemActionReconciliationResult(
                disposition: .needsReview,
                errorCode: errorCodeMapper.boundedCode(for: error)
            )
        }

        switch resolution.disposition {
        case .confirmed:
            guard let confirmed = resolution.confirmedResult,
                  confirmed.outcome == .succeeded || confirmed.outcome == .cancelled else {
                throw SystemActionCoordinatorError.invalidAdapterResult
            }
            let normalized = SystemActionAdapterResult(
                outcome: confirmed.outcome,
                boundedResult: confirmed.boundedResult,
                localMaterial: confirmed.localMaterial ?? reconciliationMaterial,
                errorCode: confirmed.errorCode,
                reconciliationState: .reconciled
            )
            let evidenceExecution: SystemActionExecutionRecord
            switch try await reconciliationEvidenceExecution(
                execution,
                proposal: proposal,
                phase: phase,
                mode: mode
            ) {
            case .ready(let prepared): evidenceExecution = prepared
            case .remoteReceipt(let receipt): return receipt
            }
            return try await recordAndPublishAdapterResult(
                operationID: evidenceExecution.operationID,
                result: normalized,
                rollbackCapability: adapter.rollbackCapability,
                completedAt: max(clock(), evidenceExecution.startedAt)
            )
        case .safeToRetry:
            let evidenceExecution: SystemActionExecutionRecord
            switch try await reconciliationEvidenceExecution(
                execution,
                proposal: proposal,
                phase: phase,
                mode: mode
            ) {
            case .ready(let prepared): evidenceExecution = prepared
            case .remoteReceipt(let receipt): return receipt
            }
            _ = try await recordAndPublishAdapterResult(
                operationID: evidenceExecution.operationID,
                result: SystemActionAdapterResult(
                    outcome: .cancelled,
                    localMaterial: reconciliationMaterial,
                    errorCode: "reconciliation_safe_to_retry",
                    reconciliationState: .reconciled
                ),
                rollbackCapability: adapter.rollbackCapability,
                completedAt: max(clock(), evidenceExecution.startedAt)
            )
            let plannedRetry = try await ledger.markSafeToRetry(
                operationID: evidenceExecution.operationID,
                now: clock()
            )
            let retried: SystemActionExecutionRecord
            switch try await authorize(
                plannedRetry,
                proposal: proposal,
                phase: phase,
                mode: mode
            ) {
            case .ready(let execution):
                retried = execution
            case .remoteReceipt(let receipt):
                return receipt
            }
            return try await callAdapter(
                adapter,
                proposal: proposal,
                execution: retried,
                phase: phase
            )
        case .ambiguous, .needsReview:
            let state: SystemActionReconciliationState = resolution.disposition == .ambiguous
                ? .ambiguous
                : .needsReview
            let result = SystemActionAdapterResult(
                outcome: .ambiguous,
                localMaterial: reconciliationMaterial,
                errorCode: resolution.errorCode ?? "reconciliation_ambiguous",
                reconciliationState: state
            )
            let evidenceExecution: SystemActionExecutionRecord
            switch try await reconciliationEvidenceExecution(
                execution,
                proposal: proposal,
                phase: phase,
                mode: mode
            ) {
            case .ready(let prepared): evidenceExecution = prepared
            case .remoteReceipt(let receipt): return receipt
            }
            return try await recordAndPublishAdapterResult(
                operationID: evidenceExecution.operationID,
                result: result,
                rollbackCapability: adapter.rollbackCapability,
                completedAt: max(clock(), evidenceExecution.startedAt)
            )
        }
    }

    /// A crash-interrupted attempt has no receipt yet and must write its
    /// reconciliation result against the original lease, even after expiry.
    /// Once an immutable receipt already exists, a resolution is a new attempt
    /// and therefore receives a fresh operation/lease before new evidence.
    private func reconciliationEvidenceExecution(
        _ execution: SystemActionExecutionRecord,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        mode: SystemActionCoordinatorExecutionMode
    ) async throws -> AuthorizedExecution {
        let hasCurrentReceipt = try await ledger.hasCurrentReceipt(
            operationID: execution.operationID
        )
        guard hasCurrentReceipt else { return .ready(execution) }
        let resolution = try await ledger.prepareReconciliationResolution(
            operationID: execution.operationID,
            now: clock()
        )
        return try await authorize(
            resolution,
            proposal: proposal,
            phase: phase,
            mode: mode
        )
    }

    /// Persists immutable evidence before network I/O, then immediately
    /// publishes an online receipt so the server can release its fail-closed
    /// lease. If the response is lost, the receipt remains durable in the
    /// outbox and a later call retries the same idempotent operation.
    private func recordAndPublishAdapterResult(
        operationID: UUID,
        result: SystemActionAdapterResult,
        rollbackCapability: SystemActionRollbackCapability,
        completedAt: Date
    ) async throws -> SystemActionReceipt {
        let receipt = try await ledger.recordAdapterResult(
            operationID: operationID,
            result: result,
            rollbackCapability: rollbackCapability,
            completedAt: completedAt
        )
        await publishOnlineReceiptBestEffort(receipt)
        return receipt
    }

    /// Native success is defined by a durable local immutable receipt. A
    /// network failure after that point must not be surfaced as native action
    /// failure; the exact receipt remains in the outbox for idempotent retry.
    private func publishOnlineReceiptBestEffort(_ receipt: SystemActionReceipt) async {
        guard receipt.executionMode == .onlineLease, let remoteClient else { return }
        do {
            try await flushPendingOutbox(remoteClient: remoteClient)
        } catch {
            // Pending sync is visible from the ledger/outbox. Never reinterpret
            // a completed Apple side effect as failed because transport broke.
        }
    }
}
