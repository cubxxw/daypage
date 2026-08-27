import Foundation
import DayPageModels

public enum SystemActionRemoteContractError: Error, Equatable, Sendable {
    case unsupportedKind(String)
    case invalidRecord(String)
    case invalidState(String)
}

/// Exact operation accepted by `daypage_apply_system_action_operations_v1`.
/// Local ledger envelopes and device-only material never cross this boundary.
public struct SystemActionRemoteOperationDTO: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let operationID: UUID
    public let entityType: String
    public let entityID: UUID
    public let operationKind: String
    public let revision: Int64
    public let record: SystemActionJSONValue

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case operationID = "operation_id"
        case entityType = "entity_type"
        case entityID = "entity_id"
        case operationKind = "operation_kind"
        case revision
        case record
    }

    public init(
        protocolVersion: Int = 1,
        operationID: UUID,
        entityType: String,
        entityID: UUID,
        operationKind: String,
        revision: Int64,
        record: SystemActionJSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.operationKind = operationKind
        self.revision = revision
        self.record = record
    }
}

/// Explicit local ↔ cloud vocabulary mapping. In particular, local lifecycle
/// names are never silently encoded as backend states.
public enum SystemActionRemoteContractMapper {
    public static func operation(
        from local: SystemActionOutboxOperation
    ) throws -> SystemActionRemoteOperationDTO {
        switch local.payload {
        case .proposal(let proposal):
            return SystemActionRemoteOperationDTO(
                operationID: local.operationID,
                entityType: "proposal",
                entityID: proposal.id,
                operationKind: proposal.deletedAt == nil ? "upsert" : "delete",
                revision: proposal.revision,
                record: try proposalRecord(proposal)
            )
        case .decision(let decision):
            return SystemActionRemoteOperationDTO(
                operationID: local.operationID,
                entityType: "approval",
                entityID: decision.id,
                operationKind: "append",
                revision: decision.proposalRevision,
                record: decisionRecord(decision)
            )
        case .receipt(let receipt):
            return SystemActionRemoteOperationDTO(
                operationID: local.operationID,
                entityType: "receipt",
                entityID: receipt.id,
                operationKind: "append",
                revision: receipt.proposalRevision,
                record: receiptRecord(receipt)
            )
        case .capabilityPolicy(let policy):
            return SystemActionRemoteOperationDTO(
                operationID: local.operationID,
                entityType: "policy",
                entityID: policy.id,
                operationKind: policy.deletedAt == nil ? "upsert" : "delete",
                revision: policy.revision,
                record: policyRecord(policy)
            )
        }
    }

    public static func backendState(
        for local: SystemActionLifecycleState
    ) -> String {
        switch local {
        case .pendingReview: return "pending"
        case .approved: return "approved"
        case .rejected: return "rejected"
        case .executing, .undoPending: return "executing"
        case .succeeded, .undone: return "completed"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .needsReview, .expired, .unsupported: return "needs_review"
        }
    }

    public static func localState(
        for backend: String
    ) throws -> SystemActionLifecycleState {
        switch backend {
        case "pending": return .pendingReview
        case "approved": return .approved
        case "rejected": return .rejected
        case "executing": return .executing
        case "completed": return .succeeded
        case "failed": return .failed
        case "cancelled": return .cancelled
        case "needs_review": return .needsReview
        default: throw SystemActionRemoteContractError.invalidState(backend)
        }
    }

    public static func proposalRecord(
        _ proposal: SystemActionProposal
    ) throws -> SystemActionJSONValue {
        guard proposal.kind.isSupported else {
            throw SystemActionRemoteContractError.unsupportedKind(proposal.kind.rawValue)
        }
        let target: (preference: String, hash: SystemActionJSONValue)
        switch proposal.targetDevice {
        case .creatingDevice:
            target = ("creating_device", .null)
        case .anyOwnedOnline:
            target = ("any", .null)
        case .specific(let deviceID):
            target = ("specific_device", .string(deviceHash(deviceID)))
        }
        return .object([
            "schema_version": .integer(Int64(proposal.schemaVersion)),
            "proposal_id": .string(proposal.id.uuidString.lowercased()),
            "revision": .integer(proposal.revision),
            "kind": .string(proposal.kind.rawValue),
            "payload": try proposal.payload.canonicalCloudValue(),
            "payload_hash": .string(proposal.payloadHash),
            "title": .string(proposal.title),
            "rationale": .string(proposal.rationale),
            "source_refs": .array(proposal.sourceReferences.map(sourceRecord)),
            "creator_source": .string(backendCreator(proposal.creatorSource)),
            "creator_device_id_hash": .string(deviceHash(proposal.creatorDeviceID)),
            "redaction_level": .string(backendRedaction(proposal.redactionLevel)),
            "target_device_preference": .string(target.preference),
            "target_device_id_hash": target.hash,
            "state": .string(backendState(for: proposal.lifecycleState)),
            "created_at": .string(timestamp(proposal.createdAt)),
            "expires_at": optionalTimestamp(proposal.expiresAt),
            "deleted_at": optionalTimestamp(proposal.deletedAt),
        ])
    }

    public static func decisionRecord(
        _ decision: SystemActionDecision
    ) -> SystemActionJSONValue {
        let backendDecision = decision.outcome == .approved ? "approve" : "reject"
        return .object([
            "schema_version": .integer(Int64(decision.schemaVersion)),
            "approval_id": .string(decision.id.uuidString.lowercased()),
            "proposal_id": .string(decision.proposalID.uuidString.lowercased()),
            "phase": .string(decision.phase.rawValue),
            "proposal_revision": .integer(decision.proposalRevision),
            "payload_hash": .string(decision.payloadHash),
            "decision": .string(backendDecision),
            "device_id_hash": .string(deviceHash(decision.deviceID)),
            "decided_at": .string(timestamp(decision.decidedAt)),
            // The wire shape uses a boolean so ordinary JSON Schema can fully
            // validate the replacement invariant. The replacement always
            // belongs to this same proposal; the server derives its internal
            // foreign key instead of accepting a second, forgeable UUID.
            "has_replacement": .boolean(decision.replacementProposalID != nil),
        ])
    }

    public static func receiptRecord(
        _ receipt: SystemActionReceipt
    ) -> SystemActionJSONValue {
        let outcome = receipt.outcome == .unsupported ? "ambiguous" : receipt.outcome.rawValue
        let reconciliation: String
        switch receipt.reconciliationState {
        case .notNeeded: reconciliation = "not_applicable"
        case .pending: reconciliation = "pending"
        case .reconciled: reconciliation = "confirmed"
        case .ambiguous, .needsReview: reconciliation = "needs_review"
        }
        var result: [String: SystemActionJSONValue] = [:]
        if let bounded = receipt.boundedResult {
            result["summary"] = .string(bounded.summaryCode)
            if let resourceKind = bounded.metadata["resource_kind"] {
                result["resource_kind"] = .string(resourceKind)
            }
            result["scheduled_at"] = bounded.metadata["scheduled_at"].map(SystemActionJSONValue.string) ?? .null
            result["ended_at"] = bounded.metadata["ended_at"].map(SystemActionJSONValue.string) ?? .null
        }
        return .object([
            "schema_version": .integer(Int64(receipt.schemaVersion)),
            "receipt_id": .string(receipt.id.uuidString.lowercased()),
            "proposal_id": .string(receipt.proposalID.uuidString.lowercased()),
            "phase": .string(receipt.phase.rawValue),
            "proposal_revision": .integer(receipt.proposalRevision),
            "payload_hash": .string(receipt.payloadHash),
            "attempt": .integer(Int64(receipt.attempt)),
            "outcome": .string(outcome),
            "device_id_hash": .string(deviceHash(receipt.deviceID)),
            "execution_mode": .string(receipt.executionMode.rawValue),
            "lease_id": receipt.leaseID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "result": .object(result),
            "error_code": receipt.errorCode.map(SystemActionJSONValue.string) ?? .null,
            "reconciliation_state": .string(reconciliation),
            "undo_capability": .string(receipt.rollbackCapability.rawValue),
            "external_id_hash": receipt.boundedResult?.externalIdentifierHash
                .map(SystemActionJSONValue.string) ?? .null,
            "started_at": .string(timestamp(receipt.startedAt)),
            "completed_at": .string(timestamp(receipt.completedAt)),
        ])
    }

    public static func policyRecord(
        _ policy: SystemActionCapabilityPolicy
    ) -> SystemActionJSONValue {
        let disclosure: String
        switch policy.disclosureLevel {
        case .disabled, .privateDeviceOnly: disclosure = "private"
        case .redactedSync: disclosure = "summary"
        case .fullProposal: disclosure = "full_proposal"
        }
        return .object([
            "schema_version": .integer(Int64(policy.schemaVersion)),
            "policy_id": .string(policy.id.uuidString.lowercased()),
            "capability": .string(policy.capability.rawValue),
            "revision": .integer(policy.revision),
            "is_offered": .boolean(policy.isOffered),
            "sync_enabled": .boolean(policy.isSynchronized),
            "disclosure_level": .string(disclosure),
            "updated_at": .string(timestamp(policy.updatedAt)),
            "deleted_at": optionalTimestamp(policy.deletedAt),
        ])
    }

    public static func localPayload(
        entityType: String,
        record: SystemActionJSONValue
    ) throws -> SystemActionOutboxPayload {
        switch entityType {
        case "proposal": return .proposal(try localProposal(record))
        case "approval": return .decision(try localDecision(record))
        case "receipt": return .receipt(try localReceipt(record))
        case "policy": return .capabilityPolicy(try localPolicy(record))
        default: throw SystemActionRemoteContractError.invalidRecord("entity_type")
        }
    }

    private static func localProposal(_ value: SystemActionJSONValue) throws -> SystemActionProposal {
        let object = try requireObject(value)
        let id = try requireUUID(object, "proposal_id")
        let payloadObject = try requireObject(try require(object, "payload"))
        let kind = SystemActionKind(rawValue: try requireString(object, "kind"))
        let payload = try localActionPayload(kind: kind, object: payloadObject)
        let creator: SystemActionCreatorSource
        switch try requireString(object, "creator_source") {
        case "mcp": creator = .cloudMCP
        case "local_inference": creator = .localAgent
        case "shortcut", "widget", "share": creator = .systemEntry
        case "native": creator = .user
        default: throw SystemActionRemoteContractError.invalidRecord("creator_source")
        }
        let creatorHash = try optionalString(object, "creator_device_id_hash")
        let creatorDeviceID = creatorHash.map { "remote:\($0)" } ?? "remote-unowned:\(id.uuidString.lowercased())"
        let redaction: SystemActionRedactionLevel
        switch try requireString(object, "redaction_level") {
        case "private": redaction = .privateOnLockScreen
        case "sensitive": redaction = .titleOnly
        case "summary": redaction = .boundedSummary
        default: throw SystemActionRemoteContractError.invalidRecord("redaction_level")
        }
        let target: SystemActionTargetDevice
        switch try requireString(object, "target_device_preference") {
        case "any": target = .anyOwnedOnline
        case "creating_device": target = .creatingDevice
        case "specific_device":
            target = .specific("remote:\(try requireString(object, "target_device_id_hash"))")
        default: throw SystemActionRemoteContractError.invalidRecord("target_device_preference")
        }
        let sources = try requireArray(object, "source_refs").map { item -> SystemActionSourceReference in
            let source = try requireObject(item)
            let kind: SystemActionSourceKind
            switch try requireString(source, "kind") {
            case "memo": kind = .memo
            case "daily_page": kind = .dailyPage
            case "entity": kind = .entity
            case "place": kind = .place
            case "system_entry": kind = .systemEntry
            default: throw SystemActionRemoteContractError.invalidRecord("source_ref.kind")
            }
            return SystemActionSourceReference(kind: kind, identifier: try requireString(source, "id"))
        }
        return try SystemActionProposal(
            id: id,
            schemaVersion: Int(try requireInteger(object, "schema_version")),
            revision: try requireInteger(object, "revision"),
            payload: payload,
            payloadHash: try requireString(object, "payload_hash"),
            title: try requireString(object, "title"),
            rationale: try requireString(object, "rationale"),
            sourceReferences: sources,
            creatorSource: creator,
            creatorDeviceID: creatorDeviceID,
            redactionLevel: redaction,
            targetDevice: target,
            createdAt: try requireDate(object, "created_at"),
            expiresAt: try optionalDate(object, "expires_at"),
            lifecycleState: try localState(for: requireString(object, "state")),
            deletedAt: try optionalDate(object, "deleted_at")
        )
    }

    private static func localActionPayload(
        kind: SystemActionKind,
        object: [String: SystemActionJSONValue]
    ) throws -> SystemActionPayload {
        switch kind {
        case .calendarEvent:
            return .calendarEvent(.init(
                title: try requireString(object, "title"),
                notes: try optionalString(object, "notes"),
                startAt: try requireDate(object, "start_at"),
                endAt: try requireDate(object, "end_at"),
                isAllDay: try requireBool(object, "all_day"),
                timeZoneIdentifier: try optionalString(object, "time_zone"),
                location: try optionalString(object, "location_label").map { .init(label: $0) }
            ))
        case .reminder:
            let priorityValue = try requireInteger(object, "priority")
            return .reminder(.init(
                title: try requireString(object, "title"),
                notes: try optionalString(object, "notes"),
                dueAt: try optionalDate(object, "due_at"),
                timeZoneIdentifier: try optionalString(object, "time_zone"),
                priority: priorityValue == 0 ? nil : Int(priorityValue)
            ))
        case .contactDraft:
            return .contactDraft(.init(
                givenName: try requireString(object, "given_name"),
                familyName: try requireString(object, "family_name"),
                organization: try optionalString(object, "organization"),
                phoneNumbers: try requireArray(object, "phones").map {
                    .init(label: "phone", value: try requireString($0))
                },
                emailAddresses: try requireArray(object, "emails").map {
                    .init(label: "email", value: try requireString($0))
                }
            ))
        case .notification:
            let interruption = SystemActionNotificationInterruption(
                rawValue: try requireString(object, "interruption_level")
            )
            guard let interruption else {
                throw SystemActionRemoteContractError.invalidRecord("interruption_level")
            }
            return .notification(.init(
                title: try requireString(object, "title"),
                body: try requireString(object, "body"),
                fireAt: try requireDate(object, "fire_at"),
                timeZoneIdentifier: try optionalString(object, "time_zone"),
                interruption: interruption
            ))
        case .route:
            let mode = SystemActionRouteMode(rawValue: try requireString(object, "transport"))
            guard let mode else { throw SystemActionRemoteContractError.invalidRecord("transport") }
            let address = try optionalStringIfPresent(object, "destination_address")
            let latitude = try optionalNumber(object, "destination_latitude")
            let longitude = try optionalNumber(object, "destination_longitude")
            guard (address != nil) != (latitude != nil && longitude != nil),
                  (latitude == nil) == (longitude == nil) else {
                throw SystemActionRemoteContractError.invalidRecord("route.destination")
            }
            return .route(.init(
                destination: .init(
                    label: try requireString(object, "destination_label"),
                    latitude: latitude,
                    longitude: longitude,
                    address: address
                ),
                mode: mode
            ))
        case .capture:
            let captureKind: SystemActionCaptureKind
            switch try requireString(object, "mode") {
            case "text": captureKind = .text
            case "photo": captureKind = .photo
            case "camera": captureKind = .camera
            case "scan": captureKind = .document
            case "ocr": captureKind = .textScan
            case "ink": captureKind = .ink
            case "file": captureKind = .file
            case "voice": captureKind = .voice
            default: throw SystemActionRemoteContractError.invalidRecord("capture.mode")
            }
            return .capture(.init(
                captureKind: captureKind,
                suggestedTitle: try optionalString(object, "suggested_title"),
                attachesToSource: try requireString(object, "destination") == "current_draft"
            ))
        case .focusSession:
            return .focusSession(.init(
                title: try requireString(object, "title"),
                durationSeconds: Int(try requireInteger(object, "duration_seconds")),
                schedulesEndAlert: try requireBool(object, "schedule_end_alert"),
                allowsLiveActivity: try requireBool(object, "allow_live_activity")
            ))
        case .moment:
            return .moment(.init(
                occurredAt: try requireDate(object, "captured_at"),
                title: try optionalString(object, "title"),
                location: try optionalString(object, "place_label").map { .init(label: $0) },
                selectedContactReferenceHashes: try requireArray(object, "people_refs").map(requireString)
            ))
        case .localContextAttachment:
            let contextKind: SystemActionLocalContextKind
            switch try requireString(object, "context_kind") {
            case "weather_summary": contextKind = .weatherSummary
            case "health_summary": contextKind = .healthSummary
            case "location_summary": contextKind = .placeSummary
            case "photo": contextKind = .photo
            case "contact_selection": contextKind = .contactSelection
            default: throw SystemActionRemoteContractError.invalidRecord("context_kind")
            }
            return .localContextAttachment(.init(
                contextKind: contextKind,
                summaryCode: try requireString(object, "local_reference"),
                observedAt: try requireDate(object, "observed_at")
            ))
        case .unsupported(let raw):
            return .unsupported(kind: raw, value: .object(object))
        }
    }

    private static func localDecision(_ value: SystemActionJSONValue) throws -> SystemActionDecision {
        let object = try requireObject(value)
        let hasReplacement = try requireBool(object, "has_replacement")
        let proposalID = try requireUUID(object, "proposal_id")
        let outcome: SystemActionDecisionOutcome
        switch try requireString(object, "decision") {
        case "approve" where !hasReplacement: outcome = .approved
        case "reject": outcome = hasReplacement ? .replacementProposed : .rejected
        default: throw SystemActionRemoteContractError.invalidRecord("decision")
        }
        return try SystemActionDecision(
            id: requireUUID(object, "approval_id"),
            schemaVersion: Int(try requireInteger(object, "schema_version")),
            proposalID: proposalID,
            phase: try requirePhase(object, "phase"),
            proposalRevision: requireInteger(object, "proposal_revision"),
            payloadHash: requireString(object, "payload_hash"),
            outcome: outcome,
            decidedAt: requireDate(object, "decided_at"),
            deviceID: "remote:\(try requireString(object, "device_id_hash"))",
            replacementProposalID: hasReplacement ? proposalID : nil
        )
    }

    private static func localReceipt(_ value: SystemActionJSONValue) throws -> SystemActionReceipt {
        let object = try requireObject(value)
        let receiptID = try requireUUID(object, "receipt_id")
        let outcome = SystemActionReceiptOutcome(rawValue: try requireString(object, "outcome"))
        let executionMode = SystemActionReceiptExecutionMode(rawValue: try requireString(object, "execution_mode"))
        let rollback = SystemActionRollbackCapability(rawValue: try requireString(object, "undo_capability"))
        guard let outcome, let executionMode, let rollback else {
            throw SystemActionRemoteContractError.invalidRecord("receipt_enum")
        }
        let reconciliation: SystemActionReconciliationState
        switch try requireString(object, "reconciliation_state") {
        case "confirmed": reconciliation = .reconciled
        case "pending": reconciliation = .pending
        case "needs_review": reconciliation = .needsReview
        case "not_applicable": reconciliation = .notNeeded
        default: throw SystemActionRemoteContractError.invalidRecord("reconciliation_state")
        }
        let resultObject = try requireObject(try require(object, "result"))
        let summary = try optionalString(resultObject, "summary")
        let externalHash = try optionalString(object, "external_id_hash")
        let bounded: SystemActionBoundedResult? = summary.map {
            var metadata: [String: String] = [:]
            for key in ["resource_kind", "scheduled_at", "ended_at"] {
                if let value = try? optionalString(resultObject, key) { metadata[key] = value }
            }
            return .init(summaryCode: $0, externalIdentifierHash: externalHash, metadata: metadata)
        }
        return try SystemActionReceipt(
            id: receiptID,
            schemaVersion: Int(try requireInteger(object, "schema_version")),
            operationID: receiptID,
            proposalID: requireUUID(object, "proposal_id"),
            phase: requirePhase(object, "phase"),
            proposalRevision: requireInteger(object, "proposal_revision"),
            payloadHash: requireString(object, "payload_hash"),
            attempt: Int(try requireInteger(object, "attempt")),
            outcome: outcome,
            deviceID: "remote:\(try requireString(object, "device_id_hash"))",
            executionMode: executionMode,
            leaseID: try optionalUUID(object, "lease_id"),
            boundedResult: bounded,
            errorCode: try optionalString(object, "error_code"),
            reconciliationState: reconciliation,
            rollbackCapability: rollback,
            startedAt: requireDate(object, "started_at"),
            completedAt: requireDate(object, "completed_at")
        )
    }

    private static func localPolicy(_ value: SystemActionJSONValue) throws -> SystemActionCapabilityPolicy {
        let object = try requireObject(value)
        let isOffered = try requireBool(object, "is_offered")
        let disclosure: SystemActionDisclosureLevel
        switch try requireString(object, "disclosure_level") {
        case "private": disclosure = isOffered ? .privateDeviceOnly : .disabled
        case "summary": disclosure = .redactedSync
        case "full_proposal": disclosure = .fullProposal
        default: throw SystemActionRemoteContractError.invalidRecord("disclosure_level")
        }
        return try SystemActionCapabilityPolicy(
            id: requireUUID(object, "policy_id"),
            schemaVersion: Int(try requireInteger(object, "schema_version")),
            revision: requireInteger(object, "revision"),
            capability: .init(rawValue: requireString(object, "capability")),
            isOffered: isOffered,
            isSynchronized: requireBool(object, "sync_enabled"),
            disclosureLevel: disclosure,
            updatedAt: requireDate(object, "updated_at"),
            deletedAt: try optionalDate(object, "deleted_at")
        )
    }

    public static func hash(_ value: String) -> String {
        SystemActionCanonicalJSON.sha256(of: Data(value.utf8))
    }

    /// Pulled records use `remote:<sha256>` placeholders so the local ledger
    /// never learns raw identifiers from another device. Re-encoding such a
    /// record must preserve the server hash rather than hashing it twice.
    public static func deviceHash(_ value: String) -> String {
        let prefix = "remote:"
        if value.hasPrefix(prefix) {
            let suffix = String(value.dropFirst(prefix.count))
            if suffix.utf8.count == 64,
               suffix.utf8.allSatisfy({ byte in
                   (48...57).contains(byte) || (97...102).contains(byte)
               }) {
                return suffix
            }
        }
        return hash(value)
    }

    private static func sourceRecord(
        _ source: SystemActionSourceReference
    ) -> SystemActionJSONValue {
        let kind: String
        switch source.kind {
        case .shareInbox: kind = "system_entry"
        default: kind = source.kind.rawValue
        }
        return .object(["kind": .string(kind), "id": .string(source.identifier)])
    }

    private static func backendCreator(_ source: SystemActionCreatorSource) -> String {
        switch source {
        case .user: return "native"
        case .localAgent: return "local_inference"
        case .cloudMCP: return "mcp"
        case .systemEntry: return "shortcut"
        }
    }

    private static func backendRedaction(_ level: SystemActionRedactionLevel) -> String {
        switch level {
        case .privateOnLockScreen: return "private"
        case .titleOnly: return "sensitive"
        case .boundedSummary: return "summary"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        SystemActionCanonicalJSON.timestamp(date)
    }

    private static func optionalTimestamp(_ date: Date?) -> SystemActionJSONValue {
        date.map { .string(timestamp($0)) } ?? .null
    }

    private static func requireObject(
        _ value: SystemActionJSONValue
    ) throws -> [String: SystemActionJSONValue] {
        guard case .object(let object) = value else {
            throw SystemActionRemoteContractError.invalidRecord("object")
        }
        return object
    }

    private static func require(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> SystemActionJSONValue {
        guard let value = object[key] else { throw SystemActionRemoteContractError.invalidRecord(key) }
        return value
    }

    private static func requireString(_ value: SystemActionJSONValue) throws -> String {
        guard case .string(let string) = value else {
            throw SystemActionRemoteContractError.invalidRecord("string")
        }
        return string
    }

    private static func requireString(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> String {
        try requireString(require(object, key))
    }

    private static func optionalString(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> String? {
        switch try require(object, key) {
        case .null: return nil
        case .string(let value): return value
        default: throw SystemActionRemoteContractError.invalidRecord(key)
        }
    }

    private static func optionalStringIfPresent(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> String? {
        guard object[key] != nil else { return nil }
        return try optionalString(object, key)
    }

    private static func requireInteger(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> Int64 {
        switch try require(object, key) {
        case .integer(let value): return value
        case .number(let value) where value.rounded() == value: return Int64(value)
        default: throw SystemActionRemoteContractError.invalidRecord(key)
        }
    }

    private static func requireNumber(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> Double {
        switch try require(object, key) {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: throw SystemActionRemoteContractError.invalidRecord(key)
        }
    }

    private static func optionalNumber(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> Double? {
        guard object[key] != nil else { return nil }
        switch try require(object, key) {
        case .null: return nil
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: throw SystemActionRemoteContractError.invalidRecord(key)
        }
    }

    private static func requireBool(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> Bool {
        guard case .boolean(let value) = try require(object, key) else {
            throw SystemActionRemoteContractError.invalidRecord(key)
        }
        return value
    }

    private static func requireArray(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> [SystemActionJSONValue] {
        guard case .array(let value) = try require(object, key) else {
            throw SystemActionRemoteContractError.invalidRecord(key)
        }
        return value
    }

    private static func requireUUID(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> UUID {
        guard let value = UUID(uuidString: try requireString(object, key)) else {
            throw SystemActionRemoteContractError.invalidRecord(key)
        }
        return value
    }

    private static func optionalUUID(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> UUID? {
        guard let value = try optionalString(object, key) else { return nil }
        guard let uuid = UUID(uuidString: value) else {
            throw SystemActionRemoteContractError.invalidRecord(key)
        }
        return uuid
    }

    private static func requireDate(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> Date {
        try parseDate(requireString(object, key), key: key)
    }

    private static func optionalDate(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> Date? {
        guard let value = try optionalString(object, key) else { return nil }
        return try parseDate(value, key: key)
    }

    private static func parseDate(_ value: String, key: String) throws -> Date {
        guard let date = SystemActionCanonicalJSON.date(fromCanonicalTimestamp: value) else {
            throw SystemActionRemoteContractError.invalidRecord(key)
        }
        return date
    }

    private static func requirePhase(
        _ object: [String: SystemActionJSONValue],
        _ key: String
    ) throws -> SystemActionExecutionPhase {
        guard let phase = SystemActionExecutionPhase(rawValue: try requireString(object, key)) else {
            throw SystemActionRemoteContractError.invalidRecord(key)
        }
        return phase
    }
}
