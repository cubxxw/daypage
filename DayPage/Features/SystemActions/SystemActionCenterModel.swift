import Foundation
import WidgetKit
import DayPageModels
import DayPageStorage

/// App-layer command facade. The concrete composition root binds these closures
/// to `SystemActionCoordinator`; views never call EventKit, Contacts, Photos,
/// HealthKit or any other native framework directly.
struct SystemActionCenterCommands: Sendable {
    let save: @Sendable (SystemActionProposal) async throws -> Void
    let replace: @Sendable (SystemActionProposal, SystemActionProposal) async throws -> Void
    let approve: @Sendable (SystemActionProposal, Bool) async throws -> Void
    let reject: @Sendable (SystemActionProposal) async throws -> Void
    let execute: @Sendable (UUID) async throws -> Void
    let undo: @Sendable (UUID) async throws -> Void
    let capabilitySnapshots: @Sendable () async -> [SystemActionCapabilitySnapshot]
    let setCapabilityPolicy: @Sendable (SystemActionCapabilityPolicy) async throws -> Void
    let sync: @Sendable () async throws -> Void
    let prepareAccountBoundary: @Sendable () async throws -> Void
    let publishSystemSummaries: @Sendable ([SystemActionPublishedSummary]) async -> Void
}

struct SystemActionPublishedSummary: Sendable, Equatable {
    let id: UUID
    let title: String
    let kind: String
    let state: String
    let privacySensitive: Bool
}

enum SystemActionSystemSurfacePrivacy {
    static var genericTitle: String {
        NSLocalizedString("system_action.privacy.generic_title", comment: "Generic system-surface title before exact approval")
    }
    static let genericKind = "system_action"

    static func summary(
        for proposal: SystemActionProposal,
        decisions: [SystemActionDecision]
    ) -> SystemActionPublishedSummary {
        let hasExactApproval = decisions.contains { decision in
            decision.proposalID == proposal.id
                && decision.phase == .execute
                && decision.proposalRevision == proposal.revision
                && decision.payloadHash == proposal.payloadHash
                && decision.outcome == .approved
        }
        let mayDisclose = hasExactApproval
            && proposal.redactionLevel != .privateOnLockScreen
        return .init(
            id: proposal.id,
            title: mayDisclose ? String(proposal.title.prefix(120)) : genericTitle,
            kind: mayDisclose ? proposal.kind.rawValue : genericKind,
            state: proposal.lifecycleState.rawValue,
            privacySensitive: !mayDisclose
        )
    }
}

@MainActor
final class SystemActionCenterModel: ObservableObject {
    @Published private(set) var snapshot: SystemActionLedgerSnapshot?
    @Published private(set) var capabilities: [SystemActionCapabilitySnapshot] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeOperationID: UUID?
    @Published private(set) var activePolicyCapability: SystemActionCapability?
    @Published var errorMessage: String?

    let deviceID: String
    private let ledger: SystemActionLedger
    private let commands: SystemActionCenterCommands

    init(ledger: SystemActionLedger, deviceID: String, commands: SystemActionCenterCommands) {
        self.ledger = ledger
        self.deviceID = deviceID
        self.commands = commands
    }

    var proposals: [SystemActionProposal] { snapshot?.proposals ?? [] }
    var receipts: [SystemActionReceipt] { snapshot?.receipts ?? [] }
    var policies: [SystemActionCapabilityPolicy] { snapshot?.capabilityPolicies ?? [] }
    var pendingCount: Int { pendingProposals.count }

    var reviewableProposals: [SystemActionProposal] {
        pendingProposals.filter {
            $0.lifecycleState == .pendingReview || $0.lifecycleState == .needsReview
        }
    }

    var pendingProposals: [SystemActionProposal] {
        proposals.filter { proposal in
            switch proposal.lifecycleState {
            case .pendingReview, .approved, .needsReview, .executing, .undoPending:
                return true
            default:
                return false
            }
        }
    }

    var completedProposals: [SystemActionProposal] {
        proposals.filter { !pendingProposals.contains($0) }
    }

    func proposals(on day: Date = Date(), calendar: Calendar = .current) -> [SystemActionProposal] {
        proposals.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
    }

    func receipts(on day: Date = Date(), calendar: Calendar = .current) -> [SystemActionReceipt] {
        receipts.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }
    }

    func disclosureSummary(for proposal: SystemActionProposal) -> String {
        let levels = proposal.payload.requiredCapabilities.map(disclosureLevel(for:))
        if levels.isEmpty || levels.contains(.privateDeviceOnly) || levels.contains(.disabled) {
            return NSLocalizedString(
                "system_action.privacy.device_only",
                value: "提案与执行结果仅保存在本机；Apple 数据不会进入云端账本。",
                comment: ""
            )
        }
        if levels.allSatisfy({ $0 == .fullProposal }) {
            return NSLocalizedString(
                "system_action.privacy.full_sync",
                value: "已允许同步完整提案；系统返回值仍只保留有限摘要和不可逆哈希。",
                comment: ""
            )
        }
        return NSLocalizedString(
            "system_action.privacy.policy_only",
            value: "仅同步能力策略摘要；可执行字段和 Apple 数据留在本机。",
            comment: ""
        )
    }

    func refresh(syncRemote: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await commands.prepareAccountBoundary()
            if syncRemote { try await commands.sync() }
            async let ledgerSnapshot = ledger.snapshot()
            async let capabilityValues = commands.capabilitySnapshots()
            snapshot = try await ledgerSnapshot
            capabilities = await capabilityValues.sorted { $0.kind.rawValue < $1.kind.rawValue }
            let summaries = pendingProposals.map {
                SystemActionSystemSurfacePrivacy.summary(for: $0, decisions: snapshot?.decisions ?? [])
            }
            writeRedactedSystemSnapshot(summaries)
            await commands.publishSystemSummaries(isCapabilityOffered(.spotlight) ? summaries : [])
            errorMessage = nil
        } catch {
            if error is SystemActionAccountBoundaryError {
                clearAccountScopedState()
            }
            errorMessage = Self.boundedMessage(for: error)
        }
    }

    func clearAccountScopedState() {
        snapshot = nil
        capabilities = []
        activeOperationID = nil
        activePolicyCapability = nil
    }

    func save(_ proposal: SystemActionProposal) async -> Bool {
        await perform(proposalID: proposal.id) {
            try await commands.save(proposal)
        }
    }

    func saveReplacement(original: SystemActionProposal, revised: SystemActionProposal) async -> Bool {
        await perform(proposalID: original.id) {
            try await commands.replace(original, revised)
        }
    }

    func approve(_ proposal: SystemActionProposal, executeImmediately: Bool) async -> Bool {
        await perform(proposalID: proposal.id) {
            try await commands.approve(proposal, executeImmediately)
        }
    }

    func reject(_ proposal: SystemActionProposal) async -> Bool {
        await perform(proposalID: proposal.id) {
            try await commands.reject(proposal)
        }
    }

    func execute(_ proposal: SystemActionProposal) async -> Bool {
        await perform(proposalID: proposal.id) {
            try await commands.execute(proposal.id)
        }
    }

    func undo(_ proposal: SystemActionProposal) async -> Bool {
        await perform(proposalID: proposal.id) {
            try await commands.undo(proposal.id)
        }
    }

    func latestReceipt(for proposal: SystemActionProposal) -> SystemActionReceipt? {
        receipts
            .filter { $0.proposalID == proposal.id }
            .max { $0.completedAt < $1.completedAt }
    }

    func makeSeedProposal(_ seed: SystemActionDraftSeed, now: Date = Date()) throws -> SystemActionProposal {
        let title = Self.nonempty(seed.title, fallback: Self.defaultTitle(for: seed.kind))
        let notes = seed.notes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                .systemActionPrefixUTF8Bytes(500)
        }
        let payload: SystemActionPayload
        switch SystemActionKind(rawValue: seed.kind) {
        case .calendarEvent:
            let start = Calendar.current.date(bySetting: .minute, value: 0, of: now.addingTimeInterval(3_600)) ?? now.addingTimeInterval(3_600)
            payload = .calendarEvent(.init(title: title, notes: notes, startAt: start, endAt: start.addingTimeInterval(3_600)))
        case .reminder:
            payload = .reminder(.init(title: title, notes: notes))
        case .contactDraft:
            payload = .contactDraft(.init(
                givenName: title.systemActionPrefixUTF8Bytes(100),
                familyName: "",
                organization: notes.map { $0.systemActionPrefixUTF8Bytes(160) }
            ))
        case .notification:
            payload = .notification(.init(title: title, body: notes ?? title, fireAt: now.addingTimeInterval(900)))
        case .route:
            payload = .route(.init(destination: .init(label: title, address: title)))
        case .capture:
            // A generic system entry has no verifiable source memo. Keep the
            // destination honest until a source-bound surface supplies one.
            payload = .capture(.init(
                captureKind: .document,
                suggestedTitle: title,
                attachesToSource: false
            ))
        case .focusSession:
            payload = .focusSession(.init(title: title, durationSeconds: 25 * 60))
        case .moment:
            payload = .moment(.init(occurredAt: now, title: title))
        case .localContextAttachment:
            throw SystemActionValidationError.unsupportedActionKind("local_context_attachment_requires_local_reference")
        case .unsupported(let kind):
            throw SystemActionValidationError.unsupportedActionKind(kind)
        }
        return try SystemActionProposal(
            payload: payload,
            title: title,
            rationale: notes ?? Self.localized("system_action.seed.rationale"),
            creatorSource: .systemEntry,
            creatorDeviceID: deviceID
        )
    }

    func makeFocusProposal(_ seed: SystemActionFocusSeed) throws -> SystemActionProposal {
        try SystemActionProposal(
            payload: .focusSession(.init(
                title: Self.nonempty(seed.title, fallback: Self.localized("system_action.seed.default.focus_session")),
                durationSeconds: min(max(seed.durationSeconds, 60), 86_400)
            )),
            title: Self.nonempty(seed.title, fallback: Self.localized("system_action.seed.default.focus_session")),
            rationale: Self.localized("system_action.focus.rationale"),
            creatorSource: .systemEntry,
            creatorDeviceID: deviceID
        )
    }

    func makeLocalContextProposal(_ record: SystemActionLocalContextRecord) throws -> SystemActionProposal {
        let title: String
        switch record.kind {
        case .weatherSummary: title = Self.localized("system_action.local_context.title.weather")
        case .healthSummary: title = Self.localized("system_action.local_context.title.health")
        case .placeSummary: title = Self.localized("system_action.local_context.title.place")
        case .photo: title = Self.localized("system_action.local_context.title.photo")
        case .contactSelection: title = Self.localized("system_action.local_context.title.contact")
        }
        return try SystemActionProposal(
            payload: .localContextAttachment(.init(
                contextKind: record.kind,
                summaryCode: record.id.uuidString.lowercased(),
                observedAt: record.observedAt
            )),
            title: title,
            rationale: Self.localized("system_action.local_context.rationale"),
            creatorSource: .user,
            creatorDeviceID: deviceID,
            redactionLevel: .privateOnLockScreen,
            targetDevice: .creatingDevice,
            expiresAt: record.retentionExpiresAt()
        )
    }

    func isCapabilityOffered(_ capability: SystemActionCapability) -> Bool {
        policies.first(where: { $0.capability == capability && $0.deletedAt == nil })?.isOffered ?? true
    }

    func disclosureLevel(for capability: SystemActionCapability) -> SystemActionDisclosureLevel {
        policies.first(where: { $0.capability == capability && $0.deletedAt == nil })?.disclosureLevel
            ?? .privateDeviceOnly
    }

    func setCapability(_ capability: SystemActionCapability, offered: Bool) async {
        guard activePolicyCapability == nil else { return }
        activePolicyCapability = capability
        defer { activePolicyCapability = nil }
        do {
            let existing = policies.first { $0.capability == capability && $0.deletedAt == nil }
            let disclosure: SystemActionDisclosureLevel
            if offered {
                disclosure = existing?.disclosureLevel == .disabled
                    ? .privateDeviceOnly
                    : (existing?.disclosureLevel ?? .privateDeviceOnly)
            } else {
                disclosure = .disabled
            }
            let policy = try SystemActionCapabilityPolicy(
                id: existing?.id ?? UUID(),
                revision: (existing?.revision ?? 0) + 1,
                capability: capability,
                isOffered: offered,
                isSynchronized: offered && (disclosure == .redactedSync || disclosure == .fullProposal),
                disclosureLevel: disclosure
            )
            try await commands.setCapabilityPolicy(policy)
            await refresh()
        } catch {
            errorMessage = Self.boundedMessage(for: error)
        }
    }

    func setDisclosure(_ disclosure: SystemActionDisclosureLevel, for capability: SystemActionCapability) async {
        guard activePolicyCapability == nil else { return }
        activePolicyCapability = capability
        defer { activePolicyCapability = nil }
        do {
            let existing = policies.first { $0.capability == capability && $0.deletedAt == nil }
            let offered = disclosure != .disabled && (existing?.isOffered ?? true)
            let policy = try SystemActionCapabilityPolicy(
                id: existing?.id ?? UUID(),
                revision: (existing?.revision ?? 0) + 1,
                capability: capability,
                isOffered: offered,
                isSynchronized: disclosure == .redactedSync || disclosure == .fullProposal,
                disclosureLevel: disclosure
            )
            try await commands.setCapabilityPolicy(policy)
            await refresh()
        } catch {
            errorMessage = Self.boundedMessage(for: error)
        }
    }

    private func perform(proposalID: UUID, operation: () async throws -> Void) async -> Bool {
        guard activeOperationID == nil else { return false }
        activeOperationID = proposalID
        defer { activeOperationID = nil }
        do {
            try await operation()
            await refresh()
            return true
        } catch {
            errorMessage = Self.boundedMessage(for: error)
            await refresh()
            return false
        }
    }

    /// Before exact approval, system surfaces receive only a generic countable
    /// item. User-vetted titles remain subject to the lock-screen redaction
    /// policy after approval.
    private func writeRedactedSystemSnapshot(_ summaries: [SystemActionPublishedSummary]) {
        guard let defaults = UserDefaults(suiteName: SystemActionSharedSummaryStore.appGroupIdentifier) else { return }
        let values = summaries.prefix(32).map { summary in
            SystemActionSharedSummaryStore.Summary(
                id: summary.id.uuidString,
                redactedTitle: summary.title,
                kind: summary.kind,
                state: summary.state
            )
        }
        let value = SystemActionSharedSummaryStore.Snapshot(
            schemaVersion: 1,
            generatedAt: Date(),
            proposals: values
        )
        guard let data = try? JSONEncoder().encode(value),
              data.count <= SystemActionSharedSummaryStore.maximumSnapshotBytes else { return }
        defaults.set(data, forKey: SystemActionSharedSummaryStore.snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: SystemActionSharedSummaryStore.widgetKind)
    }

    private static func defaultTitle(for kind: String) -> String {
        switch SystemActionKind(rawValue: kind) {
        case .calendarEvent: return localized("system_action.seed.default.calendar_event")
        case .reminder: return localized("system_action.seed.default.reminder")
        case .contactDraft: return localized("system_action.seed.default.contact")
        case .notification: return localized("system_action.seed.default.notification")
        case .route: return localized("system_action.seed.default.route")
        case .capture: return localized("system_action.seed.default.capture")
        case .focusSession: return localized("system_action.seed.default.focus_session")
        case .moment: return localized("system_action.seed.default.moment")
        case .localContextAttachment: return localized("system_action.seed.default.local_context")
        case .unsupported: return localized("system_action.seed.default.system_action")
        }
    }

    private static func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private static func nonempty(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed.systemActionPrefixUTF8Bytes(160)
    }

    private static func boundedMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description.systemActionPrefixUTF8Bytes(240)
        }
        return localized("system_action.error.operation_generic")
    }
}
