import Foundation
import DayPageModels
import DayPageServices
import DayPageStorage

enum SystemActionAccountBoundaryError: LocalizedError, Equatable {
    case authenticationRequired
    case invalidAccountIdentifier

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return NSLocalizedString(
                "system_action.error.sign_in_required",
                value: "请先登录 DayPage，再使用系统动作。",
                comment: ""
            )
        case .invalidAccountIdentifier:
            return NSLocalizedString(
                "system_action.error.invalid_account",
                value: "当前账号标识无效。请重新登录后再试。",
                comment: ""
            )
        }
    }
}

private enum SystemActionAccountBoundaryCleanupError: Error {
    case externalSurfaceCleanupFailed
}

/// Keeps the singleton action ledger bound to exactly one local or remote
/// identity. A transition first enters a durable quarantine, atomically clears
/// the ledger/outbox and external summaries, then publishes the new binding.
/// If any cleanup fails, later execution and sync remain fail-closed and retry
/// the cleanup before using the ledger.
@MainActor
final class SystemActionAccountBoundary {
    typealias AccountIDProvider = @Sendable () async -> String?
    typealias ExternalSurfaceClearer = @Sendable () async throws -> Void
    typealias TransitionBarrier = @Sendable () async -> Void

    static let bindingKey = "system-actions.account-binding-hash.v1"
    static let quarantineKey = "system-actions.account-transition-quarantine.v1"

    private let ledger: SystemActionLedger
    private let defaults: UserDefaults
    private let accountIDProvider: AccountIDProvider
    private let clearExternalSurfaces: ExternalSurfaceClearer
    private var transitionTask: Task<Void, Error>?
    private var beginTransitionBarrier: TransitionBarrier = {}
    private var endTransitionBarrier: TransitionBarrier = {}
    private var signOutBarrierActive = false

    init(
        ledger: SystemActionLedger,
        defaults: UserDefaults = .standard,
        accountIDProvider: @escaping AccountIDProvider,
        clearExternalSurfaces: @escaping ExternalSurfaceClearer
    ) {
        self.ledger = ledger
        self.defaults = defaults
        self.accountIDProvider = accountIDProvider
        self.clearExternalSurfaces = clearExternalSurfaces
    }

    func prepare() async throws {
        let bound = defaults.string(forKey: Self.bindingKey)
        let quarantined = defaults.bool(forKey: Self.quarantineKey)
        guard let accountID = await accountIDProvider() else {
            // A persisted binding proves this ledger belonged to a prior
            // authenticated session. Clear it before reporting signed-out so
            // an app restart after an interrupted sign-out cannot leave old
            // widget/Spotlight data or a reusable outbox behind.
            if bound != nil || quarantined {
                try await transition(to: nil)
            }
            throw SystemActionAccountBoundaryError.authenticationRequired
        }
        guard !accountID.isEmpty, accountID.utf8.count <= 128 else {
            throw SystemActionAccountBoundaryError.invalidAccountIdentifier
        }
        guard bound != accountID || quarantined else { return }
        try await transition(to: accountID)
    }

    func isAuthenticatedAndPrepared() async -> Bool {
        do {
            try await prepare()
            return true
        } catch {
            return false
        }
    }

    /// A side-effect path uses this non-mutating check after `prepare()` has
    /// established the boundary. Calling `prepare()` from inside a coordinator
    /// critical section could otherwise deadlock against the transition
    /// barrier when authentication changes during an awaited claim.
    func isReadyForCurrentIdentity() async -> Bool {
        guard !defaults.bool(forKey: Self.quarantineKey),
              let accountID = await accountIDProvider(),
              !accountID.isEmpty,
              accountID.utf8.count <= 128 else {
            return false
        }
        return defaults.string(forKey: Self.bindingKey) == accountID
    }

    func installTransitionBarrier(
        begin: @escaping TransitionBarrier,
        end: @escaping TransitionBarrier
    ) {
        beginTransitionBarrier = begin
        endTransitionBarrier = end
    }

    func clearForSignOut() async throws {
        if signOutBarrierActive {
            return try await finishSignOutTransition()
        }
        if defaults.string(forKey: Self.bindingKey) == nil,
           !defaults.bool(forKey: Self.quarantineKey) {
            return
        }
        try await transition(to: nil)
    }

    /// Closes the coordinator barrier while the old Supabase identity is still
    /// valid. Sign-out must not revoke that identity until every in-flight
    /// claim/native attempt has persisted its receipt and the ledger proves it
    /// can be reset without abandoning a server lease.
    func beginSignOutTransition() async throws {
        if signOutBarrierActive { return }
        if let transitionTask {
            try await transitionTask.value
            return try await beginSignOutTransition()
        }
        await beginTransitionBarrier()
        do {
            try await ledger.assertAccountTransitionReady()
            defaults.set(true, forKey: Self.quarantineKey)
            signOutBarrierActive = true
        } catch {
            await endTransitionBarrier()
            throw error
        }
    }

    func finishSignOutTransition() async throws {
        guard signOutBarrierActive else {
            if defaults.string(forKey: Self.bindingKey) == nil,
               !defaults.bool(forKey: Self.quarantineKey) {
                return
            }
            return try await transition(to: nil)
        }
        do {
            try await ledger.resetForAccountTransition()
            try await clearExternalSurfaces()
            defaults.removeObject(forKey: Self.bindingKey)
            defaults.set(false, forKey: Self.quarantineKey)
            signOutBarrierActive = false
            await endTransitionBarrier()
        } catch {
            signOutBarrierActive = false
            await endTransitionBarrier()
            throw error
        }
    }

    func cancelSignOutTransition() async {
        guard signOutBarrierActive else { return }
        signOutBarrierActive = false
        defaults.set(false, forKey: Self.quarantineKey)
        await endTransitionBarrier()
    }

    private func transition(to accountID: String?) async throws {
        if let transitionTask {
            try await transitionTask.value
            return try await transition(to: accountID)
        }
        let task = Task { @MainActor [self] in
            defer { transitionTask = nil }
            try await performTransition(to: accountID)
        }
        transitionTask = task
        try await task.value
    }

    private func performTransition(to accountID: String?) async throws {
        await beginTransitionBarrier()
        defaults.set(true, forKey: Self.quarantineKey)
        do {
            let bound = defaults.string(forKey: Self.bindingKey)
            let recoveringSameIdentity = accountID != nil && bound == accountID
            if !recoveringSameIdentity {
                try await ledger.resetForAccountTransition()
            }
            try await clearExternalSurfaces()
            if let accountID {
                defaults.set(accountID, forKey: Self.bindingKey)
            } else {
                defaults.removeObject(forKey: Self.bindingKey)
            }
            defaults.set(false, forKey: Self.quarantineKey)
            await endTransitionBarrier()
        } catch {
            await endTransitionBarrier()
            throw error
        }
    }
}

/// App composition root for Apple System Actions. Framework adapters are
/// constructed once, while the Kit coordinator owns serialization, durability,
/// exact approvals, remote leases and receipt creation.
@MainActor
final class SystemActionRuntime {
    static let shared = SystemActionRuntime()

    let ledger: SystemActionLedger
    let coordinator: SystemActionCoordinator
    let model: SystemActionCenterModel
    private let accountBoundary: SystemActionAccountBoundary

    private init() {
        let deviceID = Self.deviceID()
        let ledger = SystemActionLedger(
            // The action ledger is device-local even when the user's raw Vault
            // later switches to iCloud. It must never become another writer of
            // raw/YYYY-MM-DD.md.
            vaultRootURL: LocalVaultLocator().vaultURL,
            deviceID: deviceID
        )
        let spotlightIndexer = AppleSpotlightIndexer()
        let accountBoundary = SystemActionAccountBoundary(
            ledger: ledger,
            accountIDProvider: {
                await MainActor.run {
                    if let userID = AuthService.shared.session?.user.id.uuidString {
                        return "remote:\(SystemActionRemoteContractMapper.hash(userID))"
                    }
                    // Native actions are useful without a DayPage account.
                    // Keep their ledger in a stable device-local namespace;
                    // switching between signed-in and local identities still
                    // performs the same fail-closed quarantine and cleanup.
                    return "local:\(SystemActionRemoteContractMapper.hash(deviceID))"
                }
            },
            clearExternalSurfaces: {
                var cleanupFailed = false
                do {
                    try await SystemActionLocalContextStore.shared.clearAll()
                } catch {
                    cleanupFailed = true
                }
                do {
                    try await AppleMomentStore.shared.clearAll()
                } catch {
                    cleanupFailed = true
                }
                do {
                    try await SystemActionCaptureStore.shared.clearAll()
                } catch {
                    cleanupFailed = true
                }
                do {
                    try await MainActor.run {
                        try PassiveLocationService.shared.resetForAccountTransition()
                    }
                } catch {
                    cleanupFailed = true
                }
                await MainActor.run {
                    SystemActionSharedSummaryStore.clear()
                    DayPageReadOnlyEntitySnapshotStore.clear()
                }
                do {
                    try await spotlightIndexer.clear(
                        domainIdentifier: SystemActionSharedSummaryStore.spotlightDomainIdentifier
                    )
                } catch {
                    cleanupFailed = true
                }
                do {
                    try await spotlightIndexer.clear(
                        domainIdentifier: DayPageReadOnlyEntitySnapshotStore.spotlightDomainIdentifier
                    )
                } catch {
                    cleanupFailed = true
                }
                if cleanupFailed {
                    throw SystemActionAccountBoundaryCleanupError.externalSurfaceCleanupFailed
                }
            }
        )
        let coordinator = SystemActionCoordinator(
            ledger: ledger,
            adapters: Self.makeAdapters(),
            remoteClient: Self.makeRemoteClient(),
            deviceID: deviceID,
            authenticationVerifier: {
                await accountBoundary.isReadyForCurrentIdentity()
            }
        )
        accountBoundary.installTransitionBarrier(
            begin: { await coordinator.beginAccountTransition() },
            end: { await coordinator.endAccountTransition() }
        )
        self.ledger = ledger
        self.coordinator = coordinator
        self.accountBoundary = accountBoundary
        Task {
            do {
                try await AppleMomentStore.shared.retryPendingCleanup {
                    proposalID,
                    proposalRevision,
                    payloadHash in
                    try await ledger.decisions(proposalID: proposalID).contains { decision in
                        decision.phase == .execute
                            && decision.proposalRevision == proposalRevision
                            && decision.payloadHash == payloadHash
                            && decision.outcome == .rejected
                    }
                }
            } catch {
                DayPageLogger.log(
                    level: "ERROR",
                    message: "Moment cleanup obligation retained: \(error.localizedDescription)"
                )
            }
        }

        let commands = SystemActionCenterCommands(
            save: { proposal in
                try await accountBoundary.prepare()
                try await coordinator.saveProposal(proposal)
            },
            replace: { original, revised in
                try await accountBoundary.prepare()
                let decision = try SystemActionDecision(
                    proposalID: original.id,
                    proposalRevision: original.revision,
                    payloadHash: original.payloadHash,
                    outcome: .replacementProposed,
                    deviceID: deviceID,
                    replacementProposal: revised
                )
                try await coordinator.decide(decision)
            },
            approve: { proposal, executeImmediately in
                try await accountBoundary.prepare()
                let decision = try SystemActionDecision(
                    proposalID: proposal.id,
                    proposalRevision: proposal.revision,
                    payloadHash: proposal.payloadHash,
                    outcome: .approved,
                    deviceID: deviceID
                )
                try await coordinator.decide(decision)
                if executeImmediately {
                    _ = try await coordinator.execute(
                        proposalID: proposal.id,
                        mode: await Self.executionMode(for: proposal, ledger: ledger)
                    )
                }
            },
            reject: { proposal in
                try await accountBoundary.prepare()
                let decision = try SystemActionDecision(
                    proposalID: proposal.id,
                    proposalRevision: proposal.revision,
                    payloadHash: proposal.payloadHash,
                    outcome: .rejected,
                    deviceID: deviceID
                )
                let momentDraftID: UUID?
                if case .moment = proposal.payload {
                    momentDraftID = Self.momentDraftID(for: proposal)
                } else {
                    momentDraftID = nil
                }
                if let momentDraftID {
                    try await AppleMomentStore.shared.prepareDiscard(
                        id: momentDraftID,
                        proposalID: proposal.id,
                        proposalRevision: proposal.revision,
                        payloadHash: proposal.payloadHash
                    )
                }
                do {
                    try await coordinator.decide(decision)
                } catch {
                    if let momentDraftID {
                        try? await AppleMomentStore.shared.cancelPreparedDiscard(id: momentDraftID)
                    }
                    throw error
                }
                // The intent predates the immutable rejection, closing the
                // cross-store crash window. Cleanup may fail, but the marker
                // remains and startup verifies the exact rejection before retry.
                if let momentDraftID {
                    try await AppleMomentStore.shared.commitPreparedDiscard(id: momentDraftID)
                }
            },
            execute: { proposalID in
                try await accountBoundary.prepare()
                guard let proposal = try await ledger.proposal(id: proposalID) else {
                    throw SystemActionLedgerError.proposalNotFound
                }
                _ = try await coordinator.execute(
                    proposalID: proposalID,
                    mode: await Self.executionMode(for: proposal, ledger: ledger)
                )
            },
            undo: { proposalID in
                try await accountBoundary.prepare()
                guard let proposal = try await ledger.proposal(id: proposalID) else {
                    throw SystemActionLedgerError.proposalNotFound
                }
                let decision = try SystemActionDecision(
                    proposalID: proposal.id,
                    phase: .undo,
                    proposalRevision: proposal.revision,
                    payloadHash: proposal.payloadHash,
                    outcome: .approved,
                    deviceID: deviceID
                )
                try await coordinator.decide(decision)
                _ = try await coordinator.undo(
                    proposalID: proposalID,
                    mode: await Self.executionMode(for: proposal, ledger: ledger)
                )
            },
            capabilitySnapshots: {
                await coordinator.capabilitySnapshots()
            },
            setCapabilityPolicy: { policy in
                try await accountBoundary.prepare()
                try await coordinator.setCapabilityPolicy(policy)
                guard policy.capability == .spotlight else { return }
                if policy.isOffered {
                    await DayPageReadOnlyEntitySnapshotPublisher.refresh(spotlightEnabled: true)
                } else {
                    try? await spotlightIndexer.clear(
                        domainIdentifier: DayPageReadOnlyEntitySnapshotStore.spotlightDomainIdentifier
                    )
                }
            },
            sync: {
                try await accountBoundary.prepare()
                let hasRemoteSession = await MainActor.run {
                    guard let token = AuthService.shared.session?.accessToken else { return false }
                    return !token.isEmpty
                }
                guard hasRemoteSession else { return }
                _ = try await coordinator.sync()
            },
            prepareAccountBoundary: {
                try await accountBoundary.prepare()
            },
            publishSystemSummaries: { summaries in
                let domain = SystemActionSharedSummaryStore.spotlightDomainIdentifier
                let records = summaries.prefix(100).map { summary in
                    var components = URLComponents()
                    components.scheme = "daypage"
                    components.host = "actions"
                    components.queryItems = [
                        URLQueryItem(name: "proposal", value: summary.id.uuidString)
                    ]
                    return AppleSpotlightRecord(
                        identifier: "system-action:\(summary.id.uuidString)",
                        domainIdentifier: domain,
                        title: summary.title,
                        summary: summary.privacySensitive ? nil : "\(summary.kind) · \(summary.state)",
                        keywords: summary.privacySensitive ? [] : ["DayPage", summary.kind],
                        expirationDate: Calendar.current.date(byAdding: .day, value: 30, to: Date()),
                        contentURL: components.url,
                        privacySensitive: summary.privacySensitive
                    )
                }
                do {
                    try await spotlightIndexer.clear(domainIdentifier: domain)
                    if !records.isEmpty { try await spotlightIndexer.upsert(records) }
                } catch {
                    // Spotlight is a derived index. The local ledger remains
                    // authoritative and a later refresh safely retries it.
                }
            }
        )
        self.model = SystemActionCenterModel(ledger: ledger, deviceID: deviceID, commands: commands)
    }

    private nonisolated static func momentDraftID(for proposal: SystemActionProposal) -> UUID? {
        proposal.sourceReferences.lazy.compactMap { reference -> UUID? in
            guard reference.kind == .entity,
                  reference.identifier.hasPrefix("moment:") else { return nil }
            return UUID(uuidString: String(reference.identifier.dropFirst("moment:".count)))
        }.first
    }

    func clearForSignOut() async throws {
        model.clearAccountScopedState()
        try await accountBoundary.clearForSignOut()
    }

    func beginSignOutTransition() async throws {
        try await accountBoundary.beginSignOutTransition()
    }

    func finishSignOutTransition() async throws {
        model.clearAccountScopedState()
        try await accountBoundary.finishSignOutTransition()
    }

    func cancelSignOutTransition() async {
        await accountBoundary.cancelSignOutTransition()
    }

    /// Establishes the authenticated account boundary before another
    /// account-scoped app surface publishes derived data.
    func prepareAccountBoundary() async throws {
        try await accountBoundary.prepare()
    }

    private static func makeAdapters() -> [any SystemActionNativeAdapter] {
        var adapters: [any SystemActionNativeAdapter] = [
            AppleCalendarSystemActionAdapter(),
            AppleReminderSystemActionAdapter(),
            AppleContactSystemActionAdapter(),
            AppleNotificationSystemActionAdapter(),
            AppleRouteSystemActionAdapter(),
            AppleCaptureSystemActionAdapter(),
            AppleMomentSystemActionAdapter(),
            AppleLocalContextSystemActionAdapter()
        ]
        if #available(iOS 16.1, *) {
            adapters.append(AppleFocusSystemActionAdapter())
        }
        return adapters
    }

    private static func makeRemoteClient() -> (any SystemActionRemoteClientProtocol)? {
        guard let url = URL(string: Secrets.supabaseURL),
              !Secrets.supabasePublishableKey.isEmpty else { return nil }
        return SupabaseSystemActionRemoteClient(
            supabaseURL: url,
            anonKey: Secrets.supabasePublishableKey,
            accessTokenProvider: {
                try await MainActor.run {
                    guard let token = AuthService.shared.session?.accessToken,
                          !token.isEmpty else {
                        throw SystemActionRemoteError.unauthorized
                    }
                    return token
                }
            }
        )
    }

    private nonisolated static func executionMode(
        for proposal: SystemActionProposal,
        ledger: SystemActionLedger
    ) async -> SystemActionCoordinatorExecutionMode {
        let remoteState = await MainActor.run {
            let token = AuthService.shared.session?.accessToken
            return (
                isAuthenticated: token?.isEmpty == false,
                isNetworkUnavailable: AuthService.shared.isNetworkUnavailable
            )
        }
        let isProposalCloudEligible = (try? await ledger.isCloudEligible(proposal)) ?? false
        return executionMode(
            isNetworkUnavailable: remoteState.isNetworkUnavailable,
            isRemoteAuthenticated: remoteState.isAuthenticated,
            isProposalCloudEligible: isProposalCloudEligible
        )
    }

    nonisolated static func executionMode(
        isNetworkUnavailable: Bool,
        isRemoteAuthenticated: Bool,
        isProposalCloudEligible: Bool
    ) -> SystemActionCoordinatorExecutionMode {
        guard !isNetworkUnavailable,
              isRemoteAuthenticated,
              isProposalCloudEligible else {
            return .offline
        }
        return .onlineRequired
    }

    private static func deviceID() -> String {
        if let value = try? SyncOutboxStore.deviceID(), !value.isEmpty { return value }
        let key = "system-actions.device-id.v1"
        if let value = UserDefaults.standard.string(forKey: key), UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
