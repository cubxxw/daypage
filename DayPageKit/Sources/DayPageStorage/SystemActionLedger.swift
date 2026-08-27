import Foundation
import DayPageModels

public typealias SystemActionApproval = SystemActionDecision

public enum SystemActionLedgerError: Error, Equatable, Sendable {
    case proposalNotFound
    case staleProposal
    case duplicateConflict
    case missingExactApproval
    case decisionBindingMismatch
    case proposalExpired
    case unsupportedAction
    case capabilityNotOffered(SystemActionCapability)
    case invalidTransition
    case leaseMismatch
    case offlineDeviceMismatch
    case undoUnavailable
    case acknowledgementMismatch
    case cursorRegression
    case corruptState
    case localMaterialTooLarge
    case unresolvedRemoteCoordination
}

public enum SystemActionCoordination: Sendable {
    case offline
    case leased(SystemActionExecutionLease)
}

public enum SystemActionExecutionRecordState: String, Codable, Sendable {
    case claiming
    case claimingRemote = "claiming_remote"
    case executing
    case awaitingReconciliation = "awaiting_reconciliation"
    case completed
}

public struct SystemActionExecutionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { operationID }
    public let operationID: UUID
    public let proposalID: UUID
    public let phase: SystemActionExecutionPhase
    public let proposalRevision: Int64
    public let payloadHash: String
    public let attempt: Int
    public let deviceID: String
    public let startedAt: Date
    public let lease: SystemActionExecutionLease?
    public let state: SystemActionExecutionRecordState

    public init(
        operationID: UUID,
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        proposalRevision: Int64,
        payloadHash: String,
        attempt: Int,
        deviceID: String,
        startedAt: Date,
        lease: SystemActionExecutionLease?,
        state: SystemActionExecutionRecordState
    ) {
        self.operationID = operationID
        self.proposalID = proposalID
        self.phase = phase
        self.proposalRevision = proposalRevision
        self.payloadHash = payloadHash
        self.attempt = attempt
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.lease = lease
        self.state = state
    }

    public var context: SystemActionExecutionContext {
        SystemActionExecutionContext(
            operationID: operationID,
            phase: phase,
            attempt: attempt,
            deviceID: deviceID,
            startedAt: startedAt,
            lease: lease
        )
    }

    fileprivate func replacing(
        operationID: UUID? = nil,
        attempt: Int? = nil,
        startedAt: Date? = nil,
        lease: SystemActionExecutionLease?? = nil,
        state: SystemActionExecutionRecordState
    ) -> SystemActionExecutionRecord {
        SystemActionExecutionRecord(
            operationID: operationID ?? self.operationID,
            proposalID: proposalID,
            phase: phase,
            proposalRevision: proposalRevision,
            payloadHash: payloadHash,
            attempt: attempt ?? self.attempt,
            deviceID: deviceID,
            startedAt: startedAt ?? self.startedAt,
            lease: lease ?? self.lease,
            state: state
        )
    }
}

public enum SystemActionExecutionPreparation: Sendable {
    case ready(SystemActionExecutionRecord)
    case requiresReconciliation(SystemActionExecutionRecord, SystemActionLocalMaterial?)
    case alreadyCompleted(SystemActionReceipt)
}

public enum SystemActionOutboxPayload: Codable, Equatable, Sendable {
    case proposal(SystemActionProposal)
    case decision(SystemActionDecision)
    case receipt(SystemActionReceipt)
    case capabilityPolicy(SystemActionCapabilityPolicy)

    public var recordID: String {
        switch self {
        case .proposal(let value): return value.id.uuidString.lowercased()
        case .decision(let value): return value.id.uuidString.lowercased()
        case .receipt(let value): return value.id.uuidString.lowercased()
        case .capabilityPolicy(let value): return value.id.uuidString.lowercased()
        }
    }

    public var entity: String {
        switch self {
        case .proposal: return "proposal"
        case .decision: return "decision"
        case .receipt: return "receipt"
        case .capabilityPolicy: return "capability_policy"
        }
    }

    private enum CodingKeys: String, CodingKey { case entity, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .entity) {
        case "proposal": self = .proposal(try container.decode(SystemActionProposal.self, forKey: .value))
        case "decision": self = .decision(try container.decode(SystemActionDecision.self, forKey: .value))
        case "receipt": self = .receipt(try container.decode(SystemActionReceipt.self, forKey: .value))
        case "capability_policy":
            self = .capabilityPolicy(try container.decode(SystemActionCapabilityPolicy.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .entity,
                in: container,
                debugDescription: "Unknown system action outbox entity"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entity, forKey: .entity)
        switch self {
        case .proposal(let value): try container.encode(value, forKey: .value)
        case .decision(let value): try container.encode(value, forKey: .value)
        case .receipt(let value): try container.encode(value, forKey: .value)
        case .capabilityPolicy(let value): try container.encode(value, forKey: .value)
        }
    }
}

public struct SystemActionOutboxOperation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { operationID }
    public let operationID: UUID
    public let createdAt: Date
    public let payload: SystemActionOutboxPayload
    public let requestFingerprint: String

    public init(
        operationID: UUID = UUID(),
        createdAt: Date = Date(),
        payload: SystemActionOutboxPayload,
        requestFingerprint: String? = nil
    ) throws {
        let fingerprint = try SystemActionCanonicalJSON.sha256(of: payload)
        if let requestFingerprint, requestFingerprint != fingerprint {
            throw SystemActionValidationError.exactBindingMismatch
        }
        self.operationID = operationID
        self.createdAt = createdAt
        self.payload = payload
        self.requestFingerprint = fingerprint
    }
}

public struct SystemActionLedgerSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceID: String
    public let proposals: [SystemActionProposal]
    public let decisions: [SystemActionDecision]
    public let receipts: [SystemActionReceipt]
    public let capabilityPolicies: [SystemActionCapabilityPolicy]
    public let executions: [SystemActionExecutionRecord]
    public let pendingOutbox: [SystemActionOutboxOperation]
    public let remoteCursor: Int64

    public init(
        schemaVersion: Int,
        deviceID: String,
        proposals: [SystemActionProposal],
        decisions: [SystemActionDecision],
        receipts: [SystemActionReceipt],
        capabilityPolicies: [SystemActionCapabilityPolicy],
        executions: [SystemActionExecutionRecord],
        pendingOutbox: [SystemActionOutboxOperation],
        remoteCursor: Int64
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.proposals = proposals
        self.decisions = decisions
        self.receipts = receipts
        self.capabilityPolicies = capabilityPolicies
        self.executions = executions
        self.pendingOutbox = pendingOutbox
        self.remoteCursor = remoteCursor
    }
}

/// Actor-isolated, single-file action ledger. All durable records, the exact
/// sync outbox, cursor, and device-only undo material are replaced in one
/// atomic write under `<vault>/_agent/system-actions/ledger-v1.json`.
public actor SystemActionLedger {
    private static let schemaVersion = 1
    private static let maximumLocalMaterialBytes = 16 * 1_024

    private struct LocalMaterialRecord: Codable, Equatable {
        let operationID: UUID
        let material: SystemActionLocalMaterial
    }

    private struct RejectedRemoteRecord: Codable, Equatable, Hashable {
        enum Kind: String, Codable { case proposal, decision, receipt, policy }

        let kind: Kind
        let stableID: String
        let revision: Int64
    }

    private struct State: Codable, Equatable {
        var schemaVersion: Int
        var deviceID: String
        var proposals: [SystemActionProposal]
        var decisions: [SystemActionDecision]
        var receipts: [SystemActionReceipt]
        var policies: [SystemActionCapabilityPolicy]
        var executions: [SystemActionExecutionRecord]
        var localMaterials: [LocalMaterialRecord]
        var outbox: [SystemActionOutboxOperation]
        var remoteCursor: Int64
        // Optional so ledgers written by the first v1 development builds can
        // be opened without a one-shot migration. History is needed when a
        // user enables full sync after privately revising a proposal: the
        // server requires every proposal revision in causal order.
        var proposalHistory: [SystemActionProposal]?
        // Accepted, pulled, and terminally rejected fingerprints must not be
        // regenerated by a later policy toggle. The immutable local records
        // remain available even when an outbox envelope is settled.
        var settledOutboxFingerprints: [String]?
        // A terminally rejected mutable write may have lost a same-revision
        // race to another device. Remember that exact mutable key so the next
        // pull can adopt the authenticated server winner instead of poisoning
        // the cursor forever.
        var rejectedRemoteRecords: [RejectedRemoteRecord]?
        // Account transitions may erase an online execution only after the
        // server has acknowledged or returned its exact terminal receipt.
        var confirmedRemoteReceiptIDs: [UUID]?
    }

    public nonisolated let vaultRootURL: URL
    public nonisolated let directoryURL: URL
    public nonisolated let ledgerURL: URL
    public nonisolated let deviceID: String

    private var loadedState: State?

    public init(vaultRootURL: URL, deviceID: String) {
        self.vaultRootURL = vaultRootURL.standardizedFileURL
        self.directoryURL = vaultRootURL.standardizedFileURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
        self.ledgerURL = directoryURL.appendingPathComponent("ledger-v1.json")
        self.deviceID = deviceID
    }

    public func snapshot() throws -> SystemActionLedgerSnapshot {
        let state = try load()
        return snapshot(from: state)
    }

    /// Removes every account-scoped action record before a local sign-out or
    /// account transition. The device identifier is retained, but proposals,
    /// approvals, receipts, local undo material, outbox operations, policies,
    /// and the remote cursor are atomically replaced together.
    public func resetForAccountTransition() throws {
        let state = try load()
        guard !hasUnresolvedRemoteCoordination(in: state) else {
            throw SystemActionLedgerError.unresolvedRemoteCoordination
        }
        try commit(emptyState())
    }

    /// A sign-out preflight runs while the old authenticated identity is still
    /// available. Once the coordinator barrier is closed, this assertion stays
    /// true until reset because no new claim or Apple side effect can start.
    public func assertAccountTransitionReady() throws {
        guard !hasUnresolvedRemoteCoordination(in: try load()) else {
            throw SystemActionLedgerError.unresolvedRemoteCoordination
        }
    }

    private func hasUnresolvedRemoteCoordination(in state: State) -> Bool {
        let confirmed = Set(state.confirmedRemoteReceiptIDs ?? [])
        return state.executions.contains { execution in
            let receipt = state.receipts.first(where: {
                $0.operationID == execution.operationID
                    && $0.phase == execution.phase
                    && $0.proposalRevision == execution.proposalRevision
                    && $0.payloadHash == execution.payloadHash
            })
            if execution.state == .claimingRemote {
                guard let receipt else { return true }
                return !confirmed.contains(receipt.id)
            }
            guard execution.lease != nil else { return false }
            guard let receipt else { return true }
            return !confirmed.contains(receipt.id)
        }
    }

    public func proposal(id: UUID) throws -> SystemActionProposal? {
        try load().proposals.first { $0.id == id }
    }

    public func decisions(proposalID: UUID) throws -> [SystemActionDecision] {
        try load().decisions
            .filter { $0.proposalID == proposalID }
            .sorted { $0.decidedAt < $1.decidedAt }
    }

    public func receipts(proposalID: UUID) throws -> [SystemActionReceipt] {
        try load().receipts
            .filter { $0.proposalID == proposalID }
            .sorted { $0.completedAt < $1.completedAt }
    }

    /// Returns the current active product policy. A deleted tombstone means
    /// there is no active policy and preserves the backward-compatible
    /// default that an action is offered when no policy has been configured.
    public func capabilityPolicy(
        for capability: SystemActionCapability
    ) throws -> SystemActionCapabilityPolicy? {
        try load().policies.first {
            $0.capability == capability && $0.deletedAt == nil
        }
    }

    public func pendingOutbox() throws -> [SystemActionOutboxOperation] {
        // Append order is dependency order: proposal v1, its decision, then a
        // replacement proposal v2. UUID sorting would make that nondeterministic
        // whenever records share a timestamp.
        var state = try load()
        let eligible = state.outbox.filter { isCloudEligible($0.payload, in: state) }
        if eligible.count != state.outbox.count {
            state.outbox = eligible
            try commit(state)
        }
        return eligible
    }

    public func saveProposal(_ proposal: SystemActionProposal, now: Date = Date()) throws {
        var state = try load()
        if let existing = state.proposals.first(where: { $0.id == proposal.id }) {
            if existing == proposal { return }
            guard !state.executions.contains(where: { $0.proposalID == proposal.id }),
                  !state.receipts.contains(where: { $0.proposalID == proposal.id }) else {
                throw SystemActionLedgerError.invalidTransition
            }
            guard proposal.revision == existing.revision + 1 else { throw SystemActionLedgerError.staleProposal }
        } else if proposal.revision != 1 {
            throw SystemActionLedgerError.staleProposal
        }
        replaceProposal(proposal, in: &state)
        if isCloudEligible(proposal, in: state) {
            try enqueue(.proposal(proposal), replacingMutableRecord: false, at: now, in: &state)
        } else {
            removeCloudOperations(for: proposal.id, in: &state)
        }
        try commit(state)
    }

    public func recordDecision(_ decision: SystemActionDecision, now: Date = Date()) throws {
        var state = try load()
        if let existing = state.decisions.first(where: { $0.id == decision.id }) {
            guard existing == decision else { throw SystemActionLedgerError.duplicateConflict }
            return
        }
        guard let proposal = state.proposals.first(where: { $0.id == decision.proposalID }) else {
            throw SystemActionLedgerError.proposalNotFound
        }
        if state.decisions.contains(where: {
            $0.proposalID == decision.proposalID
                && $0.phase == decision.phase
                && $0.proposalRevision == decision.proposalRevision
        }) {
            throw SystemActionLedgerError.duplicateConflict
        }
        guard decision.proposalRevision == proposal.revision, decision.payloadHash == proposal.payloadHash else {
            throw SystemActionLedgerError.decisionBindingMismatch
        }
        if decision.phase == .undo {
            let succeeded = state.receipts.contains {
                $0.proposalID == proposal.id && $0.phase == .execute && $0.outcome == .succeeded
            }
            guard succeeded else { throw SystemActionLedgerError.undoUnavailable }
        }

        if decision.outcome == .replacementProposed {
            guard let replacement = decision.replacementProposal,
                  replacement.id == proposal.id,
                  replacement.revision == proposal.revision + 1 else {
                throw SystemActionLedgerError.decisionBindingMismatch
            }
            state.decisions.append(decision)
            replaceProposal(replacement, in: &state)
            if isCloudEligible(proposal, in: state), isCloudEligible(replacement, in: state) {
                try enqueue(.decision(decision), replacingMutableRecord: false, at: now, in: &state)
                try enqueue(.proposal(replacement), replacingMutableRecord: false, at: now, in: &state)
            } else {
                removeCloudOperations(for: proposal.id, in: &state)
            }
        } else {
            let nextLifecycle: SystemActionLifecycleState = decision.outcome == .approved ? .approved : .rejected
            replaceProposal(try proposal.withLifecycleState(nextLifecycle), in: &state)
            state.decisions.append(decision)
            if isCloudEligible(proposal, in: state) {
                try enqueue(.decision(decision), replacingMutableRecord: false, at: now, in: &state)
            } else {
                removeCloudOperations(for: proposal.id, in: &state)
            }
        }
        try commit(state)
    }

    public func setCapabilityPolicy(_ policy: SystemActionCapabilityPolicy, now: Date = Date()) throws {
        var state = try load()
        let previouslyEligible = Dictionary(uniqueKeysWithValues: state.proposals.map {
            ($0.id, isCloudEligible($0, in: state))
        })
        if let existing = state.policies.first(where: { $0.capability == policy.capability }) {
            if existing == policy { return }
            guard policy.revision == existing.revision + 1,
                  policy.updatedAt >= existing.updatedAt else {
                throw SystemActionLedgerError.staleProposal
            }
        } else if policy.revision != 1 {
            throw SystemActionLedgerError.staleProposal
        }
        state.policies.removeAll { $0.capability == policy.capability }
        state.policies.append(policy)
        // Policies contain no framework data. Publish every valid policy,
        // including every intermediate private/disabled revision. The server
        // enforces current+1, so collapsing rev1 -> rev2 would make rev2
        // permanently stale.
        try enqueueIfUnsettled(.capabilityPolicy(policy), at: now, in: &state)

        for proposal in state.proposals.sorted(by: { $0.createdAt < $1.createdAt }) {
            guard isCloudEligible(proposal, in: state) else {
                removeCloudOperations(for: proposal.id, in: &state)
                continue
            }

            // A transition from device-private to full proposal sync must
            // publish the complete causal chain, not merely the new policy.
            // Re-running this for an already-full proposal is harmless because
            // settled/request fingerprints suppress exact duplicates.
            if previouslyEligible[proposal.id] != true || policy.disclosureLevel == .fullProposal {
                try enqueueCausalHistory(for: proposal.id, at: now, in: &state)
            }
        }
        try commit(state)
    }

    /// Persists the idempotency identity for the next execution attempt before
    /// any remote claim is sent. A crash or lost HTTP response therefore
    /// reloads the same `.claiming` record, while a terminal attempt creates a
    /// fresh operation identifier for the next attempt.
    public func prepareExecutionPlan(
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        now: Date = Date(),
        enforceLocalExpiry: Bool = true
    ) throws -> SystemActionExecutionPreparation {
        var state = try load()
        guard var proposal = state.proposals.first(where: { $0.id == proposalID }) else {
            throw SystemActionLedgerError.proposalNotFound
        }
        guard proposal.kind.isSupported else { throw SystemActionLedgerError.unsupportedAction }
        for capability in proposal.payload.requiredCapabilities {
            if let policy = state.policies.first(where: {
                $0.capability == capability && $0.deletedAt == nil
            }), !policy.isOffered {
                throw SystemActionLedgerError.capabilityNotOffered(capability)
            }
        }
        guard let decision = latestExactApproval(for: proposal, phase: phase, in: state) else {
            throw SystemActionLedgerError.missingExactApproval
        }
        _ = decision

        if phase == .undo {
            guard successfulExecuteReceipt(for: proposal, in: state)?.deviceID == deviceID else {
                throw SystemActionLedgerError.undoUnavailable
            }
        }

        let boundReceipts = state.receipts.filter {
            exactBinding($0, proposal: proposal, phase: phase)
        }
        if let completed = boundReceipts.last(where: {
            $0.outcome == .succeeded
                && ($0.reconciliationState == .notNeeded || $0.reconciliationState == .reconciled)
        }) {
            return .alreadyCompleted(completed)
        }

        // Offline execution has no server-issued timestamp to arbitrate clock
        // skew, so reject expiry before creating or advancing a durable claim.
        // Online preparation defers this check to the server lease issuedAt.
        if enforceLocalExpiry, proposal.isExpired(at: now) {
            throw SystemActionLedgerError.proposalExpired
        }

        if let index = state.executions.firstIndex(where: {
            exactBinding($0, proposal: proposal, phase: phase)
        }) {
            let existing = state.executions[index]
            // Attempt ordinals are scoped to an executor identity. A pulled
            // receipt from another device may legitimately use this same
            // ordinal and must never consume this execution's lease or advance
            // its retry state.
            let lastReceipt = boundReceipts
                .filter { exactBinding($0, execution: existing) }
                .max { $0.attempt < $1.attempt }
            if let lastReceipt, lastReceipt.attempt == existing.attempt {
                if lastReceipt.outcome == .ambiguous
                    || lastReceipt.reconciliationState == .pending
                    || lastReceipt.reconciliationState == .ambiguous
                    || lastReceipt.reconciliationState == .needsReview {
                    let material = material(operationID: existing.operationID, in: state)
                    return .requiresReconciliation(existing, material)
                }
                removeDiscardableLocalMaterial(for: existing, in: &state)
                let retried = existing.replacing(
                    operationID: UUID(),
                    attempt: existing.attempt + 1,
                    startedAt: now,
                    lease: .some(nil),
                    state: .claiming
                )
                state.executions[index] = retried
                proposal = try proposal.withLifecycleState(phase == .undo ? .undoPending : .executing)
                replaceProposal(proposal, in: &state)
                try commit(state)
                return .ready(retried)
            }
            if existing.state == .claiming || existing.state == .claimingRemote {
                return .ready(existing)
            }
            if existing.state == .executing || existing.state == .awaitingReconciliation {
                let material = material(operationID: existing.operationID, in: state)
                return .requiresReconciliation(existing, material)
            }
            throw SystemActionLedgerError.invalidTransition
        }

        let priorAttempt = boundReceipts
            .filter { receiptBelongsToDevice($0, deviceID: deviceID) }
            .map(\.attempt)
            .max() ?? 0
        guard priorAttempt < 1_000 else { throw SystemActionLedgerError.invalidTransition }
        let record = SystemActionExecutionRecord(
            operationID: UUID(),
            proposalID: proposal.id,
            phase: phase,
            proposalRevision: proposal.revision,
            payloadHash: proposal.payloadHash,
            attempt: priorAttempt + 1,
            deviceID: deviceID,
            startedAt: now,
            lease: nil,
            state: .claiming
        )
        state.executions.append(record)
        proposal = try proposal.withLifecycleState(phase == .undo ? .undoPending : .executing)
        replaceProposal(proposal, in: &state)
        try commit(state)
        return .ready(record)
    }

    /// Binds the exact coordination result to a previously persisted claim
    /// plan. This is the only transition from remote idempotency planning to a
    /// native side-effect attempt.
    public func authorizeExecution(
        operationID: UUID,
        coordination: SystemActionCoordination,
        now: Date = Date()
    ) throws -> SystemActionExecutionPreparation {
        var state = try load()
        guard let index = state.executions.firstIndex(where: { $0.operationID == operationID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        let planned = state.executions[index]
        let authoritativeNow: Date
        switch coordination {
        case .offline: authoritativeNow = now
        case .leased(let lease): authoritativeNow = lease.issuedAt
        }
        guard planned.state == .claiming || planned.state == .claimingRemote,
              let proposal = state.proposals.first(where: { $0.id == planned.proposalID }),
              exactBinding(planned, proposal: proposal, phase: planned.phase),
              latestExactApproval(for: proposal, phase: planned.phase, in: state) != nil else {
            throw SystemActionLedgerError.invalidTransition
        }
        if proposal.isExpired(at: authoritativeNow) {
            // A proposal may cross its boundary between offline planning and
            // authorization. Roll back that newly prepared local claim so a
            // retry is not trapped forever in `executing` without a side
            // effect or receipt. Server-leased execution remains governed by
            // the authoritative issuedAt and retains its remote evidence.
            if case .offline = coordination, planned.state == .claiming {
                state.executions.remove(at: index)
                replaceProposal(try proposal.withLifecycleState(.approved), in: &state)
                try commit(state)
            }
            throw SystemActionLedgerError.proposalExpired
        }
        for capability in proposal.payload.requiredCapabilities {
            if let policy = state.policies.first(where: {
                $0.capability == capability && $0.deletedAt == nil
            }), !policy.isOffered {
                throw SystemActionLedgerError.capabilityNotOffered(capability)
            }
        }
        if planned.phase == .undo {
            guard successfulExecuteReceipt(for: proposal, in: state)?.deviceID == deviceID else {
                throw SystemActionLedgerError.undoUnavailable
            }
        }
        switch coordination {
        case .offline:
            guard planned.state == .claiming else {
                throw SystemActionLedgerError.invalidTransition
            }
        case .leased:
            guard planned.state == .claimingRemote else {
                throw SystemActionLedgerError.invalidTransition
            }
        }

        let lease = try executionLease(
            for: proposal,
            phase: planned.phase,
            coordination: coordination,
            now: now,
            in: state
        )
        let executing = planned.replacing(
            startedAt: lease?.issuedAt ?? now,
            lease: .some(lease),
            state: .executing
        )
        state.executions[index] = executing
        try commit(state)
        return .ready(executing)
    }

    /// Commits that this planned attempt is entering a remote mutation path.
    /// Once set, the attempt cannot be silently reinterpreted as offline after
    /// an indeterminate push or claim response.
    public func prepareRemoteClaim(operationID: UUID) throws -> SystemActionExecutionRecord {
        var state = try load()
        guard let index = state.executions.firstIndex(where: { $0.operationID == operationID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        let current = state.executions[index]
        if current.state == .claimingRemote { return current }
        guard current.state == .claiming else { throw SystemActionLedgerError.invalidTransition }
        let remote = current.replacing(state: .claimingRemote)
        state.executions[index] = remote
        try commit(state)
        return remote
    }

    /// Convenience API for local callers that already have coordination. The
    /// coordinator uses the two-phase plan/authorize methods so the plan is on
    /// disk before its claim RPC.
    public func prepareExecution(
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        coordination: SystemActionCoordination,
        now: Date = Date()
    ) throws -> SystemActionExecutionPreparation {
        let plan = try prepareExecutionPlan(proposalID: proposalID, phase: phase, now: now)
        guard case .ready(let record) = plan else { return plan }
        let coordinatedRecord: SystemActionExecutionRecord
        switch coordination {
        case .offline:
            coordinatedRecord = record
        case .leased:
            coordinatedRecord = try prepareRemoteClaim(operationID: record.operationID)
        }
        return try authorizeExecution(
            operationID: coordinatedRecord.operationID,
            coordination: coordination,
            now: now
        )
    }

    /// Called only after reconciliation proves that retry cannot duplicate an
    /// external effect. The prior attempt must already have immutable terminal
    /// evidence. The next claim identity is then persisted with no inherited
    /// lease before any new claim RPC or adapter call.
    public func markSafeToRetry(
        operationID: UUID,
        now: Date = Date()
    ) throws -> SystemActionExecutionRecord {
        var state = try load()
        guard let index = state.executions.firstIndex(where: { $0.operationID == operationID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        let current = state.executions[index]
        guard current.state == .completed || current.state == .awaitingReconciliation,
              state.receipts.contains(where: {
                  exactBinding($0, execution: current) && $0.attempt == current.attempt
              }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        removeDiscardableLocalMaterial(for: current, in: &state)
        let retried = current.replacing(
            operationID: UUID(),
            attempt: current.attempt + 1,
            startedAt: now,
            lease: .some(nil),
            state: current.lease == nil ? .claiming : .claimingRemote
        )
        state.executions[index] = retried
        try commit(state)
        return retried
    }

    /// Reconciliation may resolve a previously persisted pending/ambiguous
    /// receipt. Receipts are immutable, so write the resolution as the next
    /// attempt rather than overwriting the original evidence.
    public func prepareReconciliationResolution(
        operationID: UUID,
        now: Date = Date()
    ) throws -> SystemActionExecutionRecord {
        var state = try load()
        guard let index = state.executions.firstIndex(where: { $0.operationID == operationID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        let current = state.executions[index]
        guard current.state == .executing || current.state == .awaitingReconciliation else {
            throw SystemActionLedgerError.invalidTransition
        }
        let currentReceipt = state.receipts.first(where: {
            exactBinding($0, execution: current) && $0.attempt == current.attempt
        })
        let hasCurrentReceipt = currentReceipt != nil
        let nextOperationID = hasCurrentReceipt ? UUID() : current.operationID
        if hasCurrentReceipt {
            carryLocalMaterial(from: current.operationID, to: nextOperationID, in: &state)
        }
        let resolution = current.replacing(
            operationID: nextOperationID,
            attempt: current.attempt + (hasCurrentReceipt ? 1 : 0),
            startedAt: now,
            lease: .some(nil),
            state: current.lease != nil || currentReceipt?.executionMode == .onlineLease
                ? .claimingRemote
                : .claiming
        )
        state.executions[index] = resolution
        try commit(state)
        return resolution
    }

    public func recordAdapterResult(
        operationID: UUID,
        result: SystemActionAdapterResult,
        rollbackCapability: SystemActionRollbackCapability,
        completedAt: Date = Date()
    ) throws -> SystemActionReceipt {
        var state = try load()
        guard let index = state.executions.firstIndex(where: { $0.operationID == operationID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        let execution = state.executions[index]
        if let existing = state.receipts.first(where: {
            exactBinding($0, execution: execution) && $0.attempt == execution.attempt
        }) {
            return existing
        }

        if let material = result.localMaterial {
            let bytes = try SystemActionCanonicalJSON.data(for: material)
            guard bytes.count <= Self.maximumLocalMaterialBytes else {
                throw SystemActionLedgerError.localMaterialTooLarge
            }
            state.localMaterials.removeAll { $0.operationID == operationID }
            state.localMaterials.append(LocalMaterialRecord(operationID: operationID, material: material))
        }

        let boundedResult = try redactedResult(result.boundedResult, material: result.localMaterial)
        let receipt = try SystemActionReceipt(
            operationID: operationID,
            proposalID: execution.proposalID,
            phase: execution.phase,
            proposalRevision: execution.proposalRevision,
            payloadHash: execution.payloadHash,
            attempt: execution.attempt,
            outcome: result.outcome,
            deviceID: execution.deviceID,
            executionMode: execution.lease == nil ? .offlineOwner : .onlineLease,
            leaseID: execution.lease?.id,
            boundedResult: boundedResult,
            errorCode: result.errorCode,
            reconciliationState: result.reconciliationState,
            rollbackCapability: rollbackCapability,
            startedAt: execution.startedAt,
            completedAt: completedAt
        )
        state.receipts.append(receipt)
        let nextExecutionState: SystemActionExecutionRecordState = result.outcome == .ambiguous
            || result.reconciliationState == .pending
            ? .awaitingReconciliation
            : .completed
        state.executions[index] = execution.replacing(state: nextExecutionState)
        if let proposalIndex = state.proposals.firstIndex(where: { $0.id == execution.proposalID }) {
            let proposal = state.proposals[proposalIndex]
            let lifecycle = lifecycle(for: receipt)
            state.proposals[proposalIndex] = try proposal.withLifecycleState(lifecycle)
        }
        if receipt.executionMode == .onlineLease
            || state.proposals.contains(where: {
                $0.id == receipt.proposalID && isCloudEligible($0, in: state)
            }) {
            try enqueue(.receipt(receipt), replacingMutableRecord: false, at: completedAt, in: &state)
        } else {
            removeCloudOperations(for: receipt.proposalID, in: &state)
        }
        try commit(state)
        return receipt
    }

    public func localMaterial(operationID: UUID) throws -> SystemActionLocalMaterial? {
        material(operationID: operationID, in: try load())
    }

    public func successfulExecuteReceipt(proposalID: UUID) throws -> SystemActionReceipt? {
        guard let proposal = try load().proposals.first(where: { $0.id == proposalID }) else { return nil }
        return successfulExecuteReceipt(for: proposal, in: try load())
    }

    /// Returns whether the current durable execution already has immutable
    /// evidence from the same executor and, when known, the same lease.
    /// Cross-device receipts may share an attempt ordinal and are deliberately
    /// excluded from this association.
    public func hasCurrentReceipt(operationID: UUID) throws -> Bool {
        let state = try load()
        guard let execution = state.executions.first(where: { $0.operationID == operationID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        return state.receipts.contains {
            exactBinding($0, execution: execution) && $0.attempt == execution.attempt
        }
    }

    /// Advances a persisted claim plan from exact remote terminal evidence.
    /// The claim RPC has already bound `operationID` to `receiptID`; the pulled
    /// receipt is additionally checked against the local attempt, payload, and
    /// hashed device identity before this transition is committed.
    public func assimilateRemoteAttemptReceipt(
        operationID: UUID,
        receiptID: UUID
    ) throws -> SystemActionReceipt {
        var state = try load()
        guard let index = state.executions.firstIndex(where: { $0.operationID == operationID }),
              let receipt = state.receipts.first(where: { $0.id == receiptID }) else {
            throw SystemActionLedgerError.invalidTransition
        }
        let execution = state.executions[index]
        guard exactBinding(receipt, execution: execution),
              receipt.attempt == execution.attempt,
              receipt.outcome != .succeeded,
              receipt.executionMode == .onlineLease,
              receipt.leaseID != nil,
              receipt.deviceID == "remote:\(SystemActionRemoteContractMapper.hash(execution.deviceID))",
              execution.lease == nil || execution.lease?.id == receipt.leaseID else {
            throw SystemActionLedgerError.leaseMismatch
        }
        let nextState: SystemActionExecutionRecordState = receipt.outcome == .ambiguous
            || receipt.reconciliationState == .pending
            || receipt.reconciliationState == .ambiguous
            || receipt.reconciliationState == .needsReview
            ? .awaitingReconciliation
            : .completed
        state.executions[index] = execution.replacing(state: nextState)
        try commit(state)
        return receipt
    }

    public func acknowledge(operationID: UUID, requestFingerprint: String) throws {
        var state = try load()
        guard let operation = state.outbox.first(where: { $0.operationID == operationID }),
              operation.requestFingerprint == requestFingerprint else {
            throw SystemActionLedgerError.acknowledgementMismatch
        }
        if case .receipt(let receipt) = operation.payload {
            rememberConfirmedRemoteReceipt(receipt.id, in: &state)
        }
        state.outbox.removeAll { $0.operationID == operationID }
        rememberSettledFingerprint(requestFingerprint, in: &state)
        try commit(state)
    }

    /// Removes one exact operation after the remote service has returned a
    /// validated, terminal rejection. The underlying proposal/decision/
    /// receipt remains immutable in the ledger; only the rejected transport
    /// envelope is quarantined so it cannot block unrelated future actions.
    public func discardRejected(operationID: UUID, requestFingerprint: String) throws {
        var state = try load()
        guard let operation = state.outbox.first(where: { $0.operationID == operationID }),
              operation.requestFingerprint == requestFingerprint else {
            throw SystemActionLedgerError.acknowledgementMismatch
        }
        if let rejectedRecord = rejectedRemoteRecord(for: operation.payload) {
            var records = state.rejectedRemoteRecords ?? []
            if !records.contains(rejectedRecord) { records.append(rejectedRecord) }
            state.rejectedRemoteRecords = records
        }
        state.outbox.removeAll { $0.operationID == operationID }
        rememberSettledFingerprint(requestFingerprint, in: &state)
        try commit(state)
    }

    public func advanceRemoteCursor(to cursor: Int64) throws {
        var state = try load()
        guard cursor >= state.remoteCursor else { throw SystemActionLedgerError.cursorRegression }
        if cursor == state.remoteCursor { return }
        state.remoteCursor = cursor
        try commit(state)
    }

    /// Applies server records without producing echo outbox entries. Immutable
    /// evidence must match exactly; mutable proposal/policy snapshots use their
    /// revision or timestamp to reject stale remote values.
    public func applyRemotePage(_ page: SystemActionRemotePullPage) throws {
        var state = try load()
        guard page.fromCursor == state.remoteCursor,
              page.isValid(limit: 20_000) else {
            throw SystemActionLedgerError.cursorRegression
        }
        for change in page.changes.sorted(by: { $0.sequence < $1.sequence }) {
            try rememberSettledPayload(change.payload, in: &state)
            switch change.payload {
            case .proposal(let proposal):
                if let local = state.proposals.first(where: { $0.id == proposal.id }) {
                    if local.revision > proposal.revision { continue }
                    if local.revision == proposal.revision {
                        if try !cloudEquivalentProposal(local, proposal) {
                            let key = RejectedRemoteRecord(
                                kind: .proposal,
                                stableID: proposal.id.uuidString.lowercased(),
                                revision: proposal.revision
                            )
                            guard consumeRejectedRemoteRecord(key, in: &state) else {
                                throw SystemActionLedgerError.duplicateConflict
                            }
                            let hasLocalExecutionEvidence = state.executions.contains {
                                $0.proposalID == proposal.id
                                    && $0.proposalRevision == proposal.revision
                            } || state.receipts.contains {
                                $0.proposalID == proposal.id
                                    && $0.proposalRevision == proposal.revision
                            }
                            if hasLocalExecutionEvidence {
                                replaceProposal(try local.withLifecycleState(.needsReview), in: &state)
                                removeCloudOperations(for: proposal.id, in: &state)
                            } else {
                                replaceProposal(proposal, in: &state)
                            }
                            continue
                        }
                        // The backend lifecycle may advance without changing
                        // the executable proposal revision. Preserve the raw
                        // creator-device identity held by the originating
                        // device while accepting only that explicit state.
                        replaceProposal(
                            try local.withLifecycleState(proposal.lifecycleState),
                            in: &state
                        )
                        continue
                    }
                }
                replaceProposal(proposal, in: &state)
            case .decision(let decision):
                if let existing = state.decisions.first(where: { $0.id == decision.id }) {
                    guard SystemActionRemoteContractMapper.decisionRecord(existing)
                            == SystemActionRemoteContractMapper.decisionRecord(decision) else {
                        throw SystemActionLedgerError.duplicateConflict
                    }
                } else if state.decisions.contains(where: {
                    $0.proposalID == decision.proposalID
                        && $0.phase == decision.phase
                        && $0.proposalRevision == decision.proposalRevision
                }) {
                    let key = rejectedRemoteRecord(for: .decision(decision))!
                    guard consumeRejectedRemoteRecord(key, in: &state) else {
                        throw SystemActionLedgerError.duplicateConflict
                    }
                    let hasLocalExecutionEvidence = state.executions.contains {
                        $0.proposalID == decision.proposalID
                            && $0.phase == decision.phase
                            && $0.proposalRevision == decision.proposalRevision
                    } || state.receipts.contains {
                        $0.proposalID == decision.proposalID
                            && $0.phase == decision.phase
                            && $0.proposalRevision == decision.proposalRevision
                    }
                    if hasLocalExecutionEvidence {
                        if let proposalIndex = state.proposals.firstIndex(where: {
                            $0.id == decision.proposalID
                        }) {
                            state.proposals[proposalIndex] = try state.proposals[proposalIndex]
                                .withLifecycleState(.needsReview)
                        }
                    } else {
                        state.decisions.removeAll {
                            $0.proposalID == decision.proposalID
                                && $0.phase == decision.phase
                                && $0.proposalRevision == decision.proposalRevision
                        }
                        state.decisions.append(decision)
                    }
                } else {
                    state.decisions.append(decision)
                }
            case .receipt(let receipt):
                if let existing = state.receipts.first(where: { $0.id == receipt.id }) {
                    guard SystemActionRemoteContractMapper.receiptRecord(existing)
                            == SystemActionRemoteContractMapper.receiptRecord(receipt) else {
                        throw SystemActionLedgerError.duplicateConflict
                    }
                } else if state.receipts.contains(where: {
                    $0.proposalID == receipt.proposalID
                        && $0.phase == receipt.phase
                        && $0.attempt == receipt.attempt
                        && normalizedReceiptDeviceID($0.deviceID)
                            == normalizedReceiptDeviceID(receipt.deviceID)
                }) {
                    let key = rejectedRemoteRecord(for: .receipt(receipt))!
                    guard consumeRejectedRemoteRecord(key, in: &state) else {
                        throw SystemActionLedgerError.duplicateConflict
                    }
                    if let proposalIndex = state.proposals.firstIndex(where: {
                        $0.id == receipt.proposalID
                    }) {
                        state.proposals[proposalIndex] = try state.proposals[proposalIndex]
                            .withLifecycleState(.needsReview)
                    }
                } else {
                    state.receipts.append(receipt)
                }
            case .capabilityPolicy(let policy):
                if let local = state.policies.first(where: { $0.capability == policy.capability }) {
                    if local.revision > policy.revision { continue }
                    if local.revision == policy.revision {
                        if local != policy {
                            let key = RejectedRemoteRecord(
                                kind: .policy,
                                stableID: policy.capability.rawValue,
                                revision: policy.revision
                            )
                            guard consumeRejectedRemoteRecord(key, in: &state) else {
                                throw SystemActionLedgerError.duplicateConflict
                            }
                            state.policies.removeAll { $0.capability == policy.capability }
                            state.policies.append(policy)
                        }
                        continue
                    }
                }
                state.policies.removeAll { $0.capability == policy.capability }
                state.policies.append(policy)
            }
        }
        for index in state.proposals.indices {
            let proposal = state.proposals[index]
            if let latestReceipt = state.receipts
                .filter({ exactBinding($0, proposal: proposal, phase: $0.phase) })
                .max(by: { $0.completedAt < $1.completedAt }) {
                state.proposals[index] = try proposal.withLifecycleState(lifecycle(for: latestReceipt))
            }
        }
        state.remoteCursor = page.nextCursor
        try commit(state)
    }

    // MARK: Persistence

    private func load() throws -> State {
        if let loadedState { return loadedState }
        let state: State
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            let data = try Data(contentsOf: ledgerURL)
            let decoded = try Self.decoder.decode(State.self, from: data)
            guard decoded.schemaVersion == Self.schemaVersion,
                  decoded.deviceID == deviceID,
                  decoded.remoteCursor >= 0 else {
                throw SystemActionLedgerError.corruptState
            }
            try validateLoadedState(decoded)
            state = decoded
        } else {
            guard !deviceID.isEmpty, deviceID.utf8.count <= 128 else {
                throw SystemActionLedgerError.corruptState
            }
            state = emptyState()
        }
        loadedState = state
        return state
    }

    private func emptyState() -> State {
        State(
            schemaVersion: Self.schemaVersion,
            deviceID: deviceID,
            proposals: [],
            decisions: [],
            receipts: [],
            policies: [],
            executions: [],
            localMaterials: [],
            outbox: [],
            remoteCursor: 0,
            proposalHistory: [],
            settledOutboxFingerprints: [],
            rejectedRemoteRecords: [],
            confirmedRemoteReceiptIDs: []
        )
    }

    private func commit(_ state: State) throws {
        try validateLoadedState(state)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(state)
        try data.write(to: ledgerURL, options: [.atomic])
        loadedState = state
    }

    private func validateLoadedState(_ state: State) throws {
        guard Set(state.proposals.map(\.id)).count == state.proposals.count,
              Set(state.decisions.map(\.id)).count == state.decisions.count,
              Set(state.decisions.map {
                  "\($0.proposalID.uuidString)|\($0.phase.rawValue)|\($0.proposalRevision)"
              }).count == state.decisions.count,
              Set(state.receipts.map(\.id)).count == state.receipts.count,
              Set(state.receipts.map {
                  "\($0.proposalID.uuidString)|\($0.phase.rawValue)|\($0.attempt)|\(normalizedReceiptDeviceID($0.deviceID))"
              }).count == state.receipts.count,
              Set(state.policies.map(\.id)).count == state.policies.count,
              Set(state.policies.map(\.capability)).count == state.policies.count,
              Set(state.executions.map(\.operationID)).count == state.executions.count,
              Set(state.executions.map {
                  "\($0.proposalID.uuidString)|\($0.phase.rawValue)|\($0.proposalRevision)"
              }).count == state.executions.count,
              Set(state.localMaterials.map(\.operationID)).count == state.localMaterials.count,
              Set(state.outbox.map(\.operationID)).count == state.outbox.count else {
            throw SystemActionLedgerError.corruptState
        }
        let proposals = Dictionary(uniqueKeysWithValues: state.proposals.map { ($0.id, $0) })
        for decision in state.decisions {
            guard let proposal = proposals[decision.proposalID],
                  decision.proposalRevision <= proposal.revision,
                  decision.proposalRevision != proposal.revision || decision.payloadHash == proposal.payloadHash else {
                throw SystemActionLedgerError.corruptState
            }
            let validated = try SystemActionDecision(
                id: decision.id,
                schemaVersion: decision.schemaVersion,
                proposalID: decision.proposalID,
                phase: decision.phase,
                proposalRevision: decision.proposalRevision,
                payloadHash: decision.payloadHash,
                outcome: decision.outcome,
                decidedAt: decision.decidedAt,
                deviceID: decision.deviceID,
                replacementProposalID: decision.replacementProposalID,
                replacementProposal: decision.replacementProposal
            )
            guard validated == decision else { throw SystemActionLedgerError.corruptState }
        }
        for receipt in state.receipts {
            guard let proposal = proposals[receipt.proposalID],
                  receipt.proposalRevision <= proposal.revision,
                  receipt.proposalRevision != proposal.revision || receipt.payloadHash == proposal.payloadHash else {
                throw SystemActionLedgerError.corruptState
            }
            let validated = try SystemActionReceipt(
                id: receipt.id,
                schemaVersion: receipt.schemaVersion,
                operationID: receipt.operationID,
                proposalID: receipt.proposalID,
                phase: receipt.phase,
                proposalRevision: receipt.proposalRevision,
                payloadHash: receipt.payloadHash,
                attempt: receipt.attempt,
                outcome: receipt.outcome,
                deviceID: receipt.deviceID,
                executionMode: receipt.executionMode,
                leaseID: receipt.leaseID,
                boundedResult: receipt.boundedResult,
                errorCode: receipt.errorCode,
                reconciliationState: receipt.reconciliationState,
                rollbackCapability: receipt.rollbackCapability,
                startedAt: receipt.startedAt,
                completedAt: receipt.completedAt
            )
            guard validated == receipt else { throw SystemActionLedgerError.corruptState }
        }
        for policy in state.policies {
            let validated = try SystemActionCapabilityPolicy(
                id: policy.id,
                schemaVersion: policy.schemaVersion,
                revision: policy.revision,
                capability: policy.capability,
                isOffered: policy.isOffered,
                isSynchronized: policy.isSynchronized,
                disclosureLevel: policy.disclosureLevel,
                updatedAt: policy.updatedAt,
                deletedAt: policy.deletedAt
            )
            guard validated == policy else { throw SystemActionLedgerError.corruptState }
        }
        for execution in state.executions {
            guard let proposal = proposals[execution.proposalID],
                  execution.proposalRevision > 0,
                  execution.proposalRevision <= proposal.revision,
                  execution.proposalRevision != proposal.revision || execution.payloadHash == proposal.payloadHash,
                  execution.payloadHash.utf8.count == 64,
                  execution.payloadHash.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }),
                  execution.attempt > 0,
                  !execution.deviceID.isEmpty,
                  (execution.state != .claiming && execution.state != .claimingRemote)
                    || execution.lease == nil,
                  execution.lease == nil || (
                    execution.lease?.proposalID == execution.proposalID
                        && execution.lease?.phase == execution.phase
                        && execution.lease?.proposalRevision == execution.proposalRevision
                        && execution.lease?.payloadHash == execution.payloadHash
                        && execution.lease?.deviceID == execution.deviceID
                        && execution.lease?.expiresAt ?? .distantPast > execution.startedAt
                  ) else {
                throw SystemActionLedgerError.corruptState
            }
        }
        for localMaterial in state.localMaterials {
            guard state.executions.contains(where: { $0.operationID == localMaterial.operationID })
                    || state.receipts.contains(where: {
                        $0.operationID == localMaterial.operationID
                            && $0.phase == .execute
                            && $0.outcome == .succeeded
                    }),
                  try SystemActionCanonicalJSON.data(for: localMaterial.material).count <= Self.maximumLocalMaterialBytes else {
                throw SystemActionLedgerError.corruptState
            }
        }
        for operation in state.outbox {
            let validated = try SystemActionOutboxOperation(
                operationID: operation.operationID,
                createdAt: operation.createdAt,
                payload: operation.payload,
                requestFingerprint: operation.requestFingerprint
            )
            guard validated == operation else { throw SystemActionLedgerError.corruptState }
        }
        for proposal in state.proposalHistory ?? [] {
            guard state.proposals.contains(where: { $0.id == proposal.id }),
                  proposal.revision > 0 else {
                throw SystemActionLedgerError.corruptState
            }
        }
        for fingerprint in state.settledOutboxFingerprints ?? [] {
            guard fingerprint.utf8.count == 64,
                  fingerprint.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }) else {
                throw SystemActionLedgerError.corruptState
            }
        }
        guard Set(state.rejectedRemoteRecords ?? []).count == (state.rejectedRemoteRecords ?? []).count,
              Set(state.confirmedRemoteReceiptIDs ?? []).count == (state.confirmedRemoteReceiptIDs ?? []).count,
              (state.rejectedRemoteRecords ?? []).allSatisfy({
                  !$0.stableID.isEmpty && $0.stableID.utf8.count <= 160 && $0.revision > 0
              }) else {
            throw SystemActionLedgerError.corruptState
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func snapshot(from state: State) -> SystemActionLedgerSnapshot {
        SystemActionLedgerSnapshot(
            schemaVersion: state.schemaVersion,
            deviceID: state.deviceID,
            proposals: state.proposals.sorted { $0.createdAt > $1.createdAt },
            decisions: state.decisions.sorted { $0.decidedAt < $1.decidedAt },
            receipts: state.receipts.sorted { $0.completedAt < $1.completedAt },
            capabilityPolicies: state.policies.sorted { $0.capability.rawValue < $1.capability.rawValue },
            executions: state.executions.sorted { $0.startedAt < $1.startedAt },
            pendingOutbox: state.outbox,
            remoteCursor: state.remoteCursor
        )
    }

    private func replaceProposal(_ proposal: SystemActionProposal, in state: inout State) {
        var history = state.proposalHistory ?? []
        if !history.contains(where: {
            $0.id == proposal.id
                && $0.revision == proposal.revision
                && $0.payloadHash == proposal.payloadHash
        }) {
            history.append(proposal)
            state.proposalHistory = history
        }
        state.proposals.removeAll { $0.id == proposal.id }
        state.proposals.append(proposal)
    }

    private func cloudEquivalentProposal(
        _ lhs: SystemActionProposal,
        _ rhs: SystemActionProposal
    ) throws -> Bool {
        guard case .object(var left) = try SystemActionRemoteContractMapper.proposalRecord(lhs),
              case .object(var right) = try SystemActionRemoteContractMapper.proposalRecord(rhs) else {
            return false
        }
        left.removeValue(forKey: "state")
        right.removeValue(forKey: "state")
        return left == right
    }

    private func enqueue(
        _ payload: SystemActionOutboxPayload,
        replacingMutableRecord: Bool,
        at date: Date,
        in state: inout State
    ) throws {
        if replacingMutableRecord {
            state.outbox.removeAll {
                $0.payload.entity == payload.entity && $0.payload.recordID == payload.recordID
            }
        }
        state.outbox.append(try SystemActionOutboxOperation(createdAt: date, payload: payload))
    }

    private func enqueueIfUnsettled(
        _ payload: SystemActionOutboxPayload,
        at date: Date,
        in state: inout State
    ) throws {
        let candidate = try SystemActionOutboxOperation(createdAt: date, payload: payload)
        guard !(state.settledOutboxFingerprints ?? []).contains(candidate.requestFingerprint),
              !state.outbox.contains(where: {
                  $0.requestFingerprint == candidate.requestFingerprint
              }) else { return }
        state.outbox.append(candidate)
    }

    private func enqueueCausalHistory(
        for proposalID: UUID,
        at date: Date,
        in state: inout State
    ) throws {
        let history = (state.proposalHistory ?? state.proposals)
            .filter { $0.id == proposalID }
            .sorted { $0.revision < $1.revision }
        for proposal in history {
            try enqueueIfUnsettled(.proposal(proposal), at: date, in: &state)
            for decision in state.decisions
                .filter({
                    $0.proposalID == proposalID
                        && $0.proposalRevision == proposal.revision
                        && $0.payloadHash == proposal.payloadHash
                })
                .sorted(by: { $0.decidedAt < $1.decidedAt }) {
                try enqueueIfUnsettled(.decision(decision), at: date, in: &state)
            }
            for receipt in state.receipts
                .filter({
                    $0.proposalID == proposalID
                        && $0.proposalRevision == proposal.revision
                        && $0.payloadHash == proposal.payloadHash
                })
                .sorted(by: { $0.completedAt < $1.completedAt }) {
                try enqueueIfUnsettled(.receipt(receipt), at: date, in: &state)
            }
        }
    }

    private func rememberSettledPayload(
        _ payload: SystemActionOutboxPayload,
        in state: inout State
    ) throws {
        let fingerprint = try SystemActionOutboxOperation(payload: payload).requestFingerprint
        rememberSettledFingerprint(fingerprint, in: &state)
        if case .receipt(let receipt) = payload {
            rememberConfirmedRemoteReceipt(receipt.id, in: &state)
        }
    }

    private func rejectedRemoteRecord(
        for payload: SystemActionOutboxPayload
    ) -> RejectedRemoteRecord? {
        switch payload {
        case .proposal(let proposal):
            return RejectedRemoteRecord(
                kind: .proposal,
                stableID: proposal.id.uuidString.lowercased(),
                revision: proposal.revision
            )
        case .capabilityPolicy(let policy):
            return RejectedRemoteRecord(
                kind: .policy,
                stableID: policy.capability.rawValue,
                revision: policy.revision
            )
        case .decision(let decision):
            return RejectedRemoteRecord(
                kind: .decision,
                stableID: "\(decision.proposalID.uuidString.lowercased())|\(decision.phase.rawValue)",
                revision: decision.proposalRevision
            )
        case .receipt(let receipt):
            return RejectedRemoteRecord(
                kind: .receipt,
                stableID: "\(receipt.proposalID.uuidString.lowercased())|\(receipt.phase.rawValue)|\(receipt.attempt)|\(normalizedReceiptDeviceID(receipt.deviceID))",
                revision: receipt.proposalRevision
            )
        }
    }

    private func normalizedReceiptDeviceID(_ value: String) -> String {
        let remotePrefix = "remote:"
        if value.hasPrefix(remotePrefix) {
            return String(value.dropFirst(remotePrefix.count))
        }
        return SystemActionRemoteContractMapper.hash(value)
    }

    @discardableResult
    private func consumeRejectedRemoteRecord(
        _ record: RejectedRemoteRecord,
        in state: inout State
    ) -> Bool {
        var records = state.rejectedRemoteRecords ?? []
        guard let index = records.firstIndex(of: record) else { return false }
        records.remove(at: index)
        state.rejectedRemoteRecords = records
        return true
    }

    private func rememberConfirmedRemoteReceipt(_ id: UUID, in state: inout State) {
        var ids = state.confirmedRemoteReceiptIDs ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        state.confirmedRemoteReceiptIDs = ids
    }

    private func rememberSettledFingerprint(_ fingerprint: String, in state: inout State) {
        var fingerprints = state.settledOutboxFingerprints ?? []
        guard !fingerprints.contains(fingerprint) else { return }
        fingerprints.append(fingerprint)
        if fingerprints.count > 20_000 {
            fingerprints.removeFirst(fingerprints.count - 20_000)
        }
        state.settledOutboxFingerprints = fingerprints
    }

    /// Executable payloads are never partially redacted because that would
    /// invalidate the exact approval hash. Only an explicit full-proposal
    /// policy for every required capability permits the proposal and its
    /// evidence to enter the cloud outbox. Missing/deleted/summary policies
    /// therefore fail closed to device-local execution.
    public func isCloudEligible(_ proposal: SystemActionProposal) throws -> Bool {
        isCloudEligible(proposal, in: try load())
    }

    private func isCloudEligible(_ proposal: SystemActionProposal, in state: State) -> Bool {
        let required = proposal.payload.requiredCapabilities
        guard !required.isEmpty else { return false }
        return required.allSatisfy { capability in
            state.policies.contains { policy in
                policy.capability == capability
                    && policy.deletedAt == nil
                    && policy.isOffered
                    && policy.isSynchronized
                    && policy.disclosureLevel == .fullProposal
            }
        }
    }

    private func isCloudEligible(_: SystemActionCapabilityPolicy) -> Bool {
        // A deny, privacy downgrade, or tombstone is itself safe bounded data
        // and must reach the cloud to revoke a previously synchronized grant.
        true
    }

    private func isCloudEligible(_ payload: SystemActionOutboxPayload, in state: State) -> Bool {
        switch payload {
        case .proposal(let proposal):
            return isCloudEligible(proposal, in: state)
        case .decision(let decision):
            guard let proposal = state.proposals.first(where: { $0.id == decision.proposalID }) else {
                return false
            }
            return isCloudEligible(proposal, in: state)
        case .receipt(let receipt):
            if receipt.executionMode == .onlineLease { return true }
            guard let proposal = state.proposals.first(where: { $0.id == receipt.proposalID }) else {
                return false
            }
            return isCloudEligible(proposal, in: state)
        case .capabilityPolicy(let policy):
            return isCloudEligible(policy)
        }
    }

    private func removeCloudOperations(for proposalID: UUID, in state: inout State) {
        state.outbox.removeAll { operation in
            switch operation.payload {
            case .proposal(let proposal): return proposal.id == proposalID
            case .decision(let decision): return decision.proposalID == proposalID
            case .receipt(let receipt):
                return receipt.proposalID == proposalID && receipt.executionMode != .onlineLease
            case .capabilityPolicy: return false
            }
        }
    }

    private func latestExactApproval(
        for proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        in state: State
    ) -> SystemActionDecision? {
        state.decisions
            .filter {
                $0.proposalID == proposal.id
                    && $0.phase == phase
                    && $0.proposalRevision == proposal.revision
                    && $0.payloadHash == proposal.payloadHash
                    && $0.outcome == .approved
            }
            .max { $0.decidedAt < $1.decidedAt }
    }

    private func successfulExecuteReceipt(for proposal: SystemActionProposal, in state: State) -> SystemActionReceipt? {
        state.receipts
            .filter {
                exactBinding($0, proposal: proposal, phase: .execute) && $0.outcome == .succeeded
            }
            .max { $0.completedAt < $1.completedAt }
    }

    private func exactBinding(
        _ receipt: SystemActionReceipt,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase
    ) -> Bool {
        receipt.proposalID == proposal.id
            && receipt.phase == phase
            && receipt.proposalRevision == proposal.revision
            && receipt.payloadHash == proposal.payloadHash
    }

    private func exactBinding(
        _ execution: SystemActionExecutionRecord,
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase
    ) -> Bool {
        execution.proposalID == proposal.id
            && execution.phase == phase
            && execution.proposalRevision == proposal.revision
            && execution.payloadHash == proposal.payloadHash
    }

    private func exactBinding(
        _ receipt: SystemActionReceipt,
        execution: SystemActionExecutionRecord
    ) -> Bool {
        guard receipt.proposalID == execution.proposalID
            && receipt.phase == execution.phase
            && receipt.proposalRevision == execution.proposalRevision
            && receipt.payloadHash == execution.payloadHash
            && receiptBelongsToDevice(receipt, deviceID: execution.deviceID) else {
            return false
        }
        if receipt.deviceID == execution.deviceID {
            return receipt.operationID == execution.operationID
        }
        if let lease = execution.lease {
            return receipt.leaseID == lease.id
        }
        // Pulled receipts intentionally redact operation IDs. For a persisted
        // claim that has not yet stored its lease, the per-device attempt key
        // is the strongest representable binding; the claim RPC separately
        // supplies and validates the exact receipt ID before assimilation.
        return receipt.executionMode == .onlineLease
    }

    private func receiptBelongsToDevice(
        _ receipt: SystemActionReceipt,
        deviceID: String
    ) -> Bool {
        normalizedReceiptDeviceID(receipt.deviceID)
            == SystemActionRemoteContractMapper.deviceHash(deviceID)
    }

    private func executionLease(
        for proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        coordination: SystemActionCoordination,
        now: Date,
        in state: State
    ) throws -> SystemActionExecutionLease? {
        switch coordination {
        case .offline:
            let originalDevice = successfulExecuteReceipt(for: proposal, in: state)?.deviceID
            let proposalOwner: String
            switch proposal.targetDevice {
            case .creatingDevice, .anyOwnedOnline:
                proposalOwner = proposal.creatorDeviceID
            case .specific(let targetDeviceID):
                proposalOwner = targetDeviceID
            }
            let owner = originalDevice ?? proposalOwner
            guard SystemActionRemoteContractMapper.deviceHash(owner)
                    == SystemActionRemoteContractMapper.hash(deviceID) else {
                throw SystemActionLedgerError.offlineDeviceMismatch
            }
            return nil
        case .leased(let candidate):
            guard candidate.exactlyMatches(
                proposal: proposal,
                phase: phase,
                deviceID: deviceID
            ) else {
                throw SystemActionLedgerError.leaseMismatch
            }
            return candidate
        }
    }

    private func material(operationID: UUID, in state: State) -> SystemActionLocalMaterial? {
        state.localMaterials.first { $0.operationID == operationID }?.material
    }

    private func removeDiscardableLocalMaterial(
        for execution: SystemActionExecutionRecord,
        in state: inout State
    ) {
        let neededForUndo = state.receipts.contains {
            $0.operationID == execution.operationID
                && $0.phase == .execute
                && $0.outcome == .succeeded
        }
        if !neededForUndo {
            state.localMaterials.removeAll { $0.operationID == execution.operationID }
        }
    }

    private func carryLocalMaterial(
        from oldOperationID: UUID,
        to newOperationID: UUID,
        in state: inout State
    ) {
        guard let existing = state.localMaterials.first(where: {
            $0.operationID == oldOperationID
        }) else { return }
        let oldMaterialIsNeededForUndo = state.receipts.contains {
            $0.operationID == oldOperationID
                && $0.phase == .execute
                && $0.outcome == .succeeded
        }
        if !oldMaterialIsNeededForUndo {
            state.localMaterials.removeAll { $0.operationID == oldOperationID }
        }
        state.localMaterials.removeAll { $0.operationID == newOperationID }
        state.localMaterials.append(LocalMaterialRecord(
            operationID: newOperationID,
            material: existing.material
        ))
    }

    private func redactedResult(
        _ supplied: SystemActionBoundedResult?,
        material: SystemActionLocalMaterial?
    ) throws -> SystemActionBoundedResult? {
        guard let identifier = material?.externalIdentifier else { return supplied }
        let hash = SystemActionCanonicalJSON.sha256(of: Data(identifier.utf8))
        if let suppliedHash = supplied?.externalIdentifierHash, suppliedHash != hash {
            throw SystemActionLedgerError.duplicateConflict
        }
        return SystemActionBoundedResult(
            summaryCode: supplied?.summaryCode ?? "native_effect_recorded",
            externalIdentifierHash: hash,
            metadata: supplied?.metadata ?? [:]
        )
    }

    private func lifecycle(for receipt: SystemActionReceipt) -> SystemActionLifecycleState {
        if receipt.reconciliationState == .pending
            || receipt.reconciliationState == .ambiguous
            || receipt.reconciliationState == .needsReview {
            return .needsReview
        }
        if receipt.phase == .undo, receipt.outcome == .succeeded { return .undone }
        switch receipt.outcome {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .ambiguous: return .needsReview
        case .unsupported: return .unsupported
        }
    }
}
