import Foundation
import UserNotifications
import DayPageModels
import DayPageServices

extension AppleSystemActionAdapterError: SystemActionCodedError {
    var systemActionErrorCode: String {
        switch self {
        case .unavailable(let capability): return "\(capability.rawValue)_unavailable"
        case .unsupported(let capability): return "\(capability.rawValue)_unsupported"
        case .authorizationDenied(let capability): return "\(capability.rawValue)_authorization_denied"
        case .authorizationRestricted(let capability): return "\(capability.rawValue)_authorization_restricted"
        case .invalidPayload(let field):
            return "invalid_\(AppleAdapterPrivacy.boundedPublicText(field, limit: 72))"
        case .requiresUserInterface(let capability): return "\(capability.rawValue)_ui_required"
        case .presentationInProgress(let capability): return "\(capability.rawValue)_ui_busy"
        case .userCancelled(let capability): return "\(capability.rawValue)_cancelled"
        case .ambiguousOutcome(let capability): return "\(capability.rawValue)_ambiguous"
        case .frameworkFailure(let capability, let code):
            return "\(capability.rawValue)_\(AppleAdapterPrivacy.boundedPublicText(code, limit: 64))"
        }
    }
}

final class AppleCalendarSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .calendarEvent
    let rollbackCapability: SystemActionRollbackCapability = .reversible
    private let client: AppleCalendarClient

    @MainActor init(client: AppleCalendarClient? = nil) {
        self.client = client ?? AppleCalendarClient()
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        await snapshot(kind: kind, state: client.authorizationState())
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .calendarEvent(let payload) = proposal.payload else { throw kindMismatch() }
        let reference = try await client.createEvent(
            title: payload.title,
            start: payload.startAt,
            end: payload.endAt,
            notes: payload.notes,
            isAllDay: payload.isAllDay,
            timeZoneIdentifier: payload.timeZoneIdentifier,
            location: payload.location?.address ?? payload.location?.label,
            actionID: proposal.id
        )
        return successfulResult(code: "calendar_created", reference: reference)
    }

    func reconcile(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionReconciliationResult {
        guard case .calendarEvent(let payload) = proposal.payload else { throw kindMismatch() }
        let identifier: String?
        if let materialIdentifier = material?.externalIdentifier {
            identifier = materialIdentifier
        } else {
            identifier = await client.identifier(
                actionID: proposal.id,
                start: payload.startAt,
                end: payload.endAt
            )
        }
        guard let identifier else { return needsReview("calendar_identifier_missing") }
        if await client.contains(identifier: identifier) {
            return confirmedResult(code: "calendar_reconciled", identifier: identifier)
        }
        // Missing can mean deletion, write-only visibility, or an identifier
        // change. Retrying without proof could create a duplicate event.
        return needsReview("calendar_event_missing_or_unreadable")
    }

    func undo(
        proposal: SystemActionProposal,
        originalReceipt: SystemActionReceipt,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionAdapterResult {
        guard let identifier = material?.externalIdentifier else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.calendar)
        }
        guard case .calendarEvent = proposal.payload,
              try await client.removeIfUnchanged(
                identifier: identifier,
                expectedSnapshot: material?.beforeSnapshot
              ) else {
            return externallyModifiedUndoResult("calendar_externally_modified")
        }
        return SystemActionAdapterResult(
            outcome: .succeeded,
            boundedResult: .init(summaryCode: "calendar_removed", externalIdentifierHash: identifierHash(identifier)),
            reconciliationState: .notNeeded
        )
    }

}

final class AppleReminderSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .reminder
    let rollbackCapability: SystemActionRollbackCapability = .reversible
    private let client: AppleRemindersClient

    @MainActor init(client: AppleRemindersClient? = nil) {
        self.client = client ?? AppleRemindersClient()
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        await snapshot(kind: kind, state: client.authorizationState())
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .reminder(let payload) = proposal.payload else { throw kindMismatch() }
        let reference = try await client.createReminder(
            title: payload.title,
            notes: payload.notes,
            dueDate: payload.dueAt,
            timeZoneIdentifier: payload.timeZoneIdentifier,
            listHint: payload.listHint,
            priority: payload.priority
        )
        return successfulResult(code: "reminder_created", reference: reference)
    }

    func reconcile(proposal: SystemActionProposal, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionReconciliationResult {
        guard let identifier = material?.externalIdentifier else { return needsReview("reminder_identifier_missing") }
        if await client.contains(identifier: identifier) {
            return confirmedResult(code: "reminder_reconciled", identifier: identifier)
        }
        return needsReview("reminder_missing_or_deleted")
    }

    func undo(proposal: SystemActionProposal, originalReceipt: SystemActionReceipt, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionAdapterResult {
        guard let identifier = material?.externalIdentifier else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.reminders)
        }
        guard case .reminder = proposal.payload,
              try await client.removeIfUnchanged(
                identifier: identifier,
                expectedSnapshot: material?.beforeSnapshot
              ) else {
            return externallyModifiedUndoResult("reminder_externally_modified")
        }
        return .init(
            outcome: .succeeded,
            boundedResult: .init(summaryCode: "reminder_removed", externalIdentifierHash: identifierHash(identifier))
        )
    }
}

final class AppleContactSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .contactDraft
    let rollbackCapability: SystemActionRollbackCapability = .reversible
    private let client: AppleContactsClient

    @MainActor init(client: AppleContactsClient? = nil) {
        self.client = client ?? AppleContactsClient()
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        await snapshot(kind: kind, state: client.authorizationState())
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .contactDraft(let payload) = proposal.payload else { throw kindMismatch() }
        let reference = try await client.createContact(
            givenName: payload.givenName,
            familyName: payload.familyName,
            organization: payload.organization,
            phoneNumbers: payload.phoneNumbers.map { ($0.label, $0.value) },
            emailAddresses: payload.emailAddresses.map { ($0.label, $0.value) }
        )
        return successfulResult(code: "contact_created", reference: reference)
    }

    func reconcile(proposal: SystemActionProposal, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionReconciliationResult {
        guard let identifier = material?.externalIdentifier else { return needsReview("contact_identifier_missing") }
        if await client.contains(identifier: identifier) {
            return confirmedResult(code: "contact_reconciled", identifier: identifier)
        }
        return needsReview("contact_missing_or_identifier_changed")
    }

    func undo(proposal: SystemActionProposal, originalReceipt: SystemActionReceipt, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionAdapterResult {
        guard let identifier = material?.externalIdentifier else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.contacts)
        }
        guard case .contactDraft = proposal.payload,
              try await client.deleteIfUnchanged(
                identifier: identifier,
                expectedSnapshot: material?.beforeSnapshot
              ) else {
            return externallyModifiedUndoResult("contact_externally_modified")
        }
        return .init(
            outcome: .succeeded,
            boundedResult: .init(summaryCode: "contact_removed", externalIdentifierHash: identifierHash(identifier))
        )
    }

}

final class AppleNotificationSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .notification
    let rollbackCapability: SystemActionRollbackCapability = .reversible
    private let client: AppleNotificationClient

    init(client: AppleNotificationClient = AppleNotificationClient()) { self.client = client }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        snapshot(kind: kind, state: await client.authorizationState())
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .notification(let payload) = proposal.payload else { throw kindMismatch() }
        let publicContent = Self.publicContent(for: payload, redactionLevel: proposal.redactionLevel)
        let interruption: UNNotificationInterruptionLevel
        switch payload.interruption {
        case .passive: interruption = .passive
        case .active: interruption = .active
        case .timeSensitive: interruption = .timeSensitive
        }
        let effectiveInterruption = await client.resolvedInterruptionLevel(interruption)
        let reference = try await client.schedule(
            actionID: proposal.id,
            title: publicContent.title,
            body: publicContent.body,
            fireDate: payload.fireAt,
            threadIdentifier: publicContent.threadIdentifier,
            interruption: effectiveInterruption,
            playsSound: payload.playsSound
        )
        return successfulResult(
            code: effectiveInterruption == interruption
                ? "notification_scheduled"
                : "notification_scheduled_downgraded",
            reference: reference
        )
    }

    static func publicContent(
        for payload: SystemActionNotificationPayload,
        redactionLevel: SystemActionRedactionLevel
    ) -> (title: String, body: String, threadIdentifier: String?) {
        let privateTitle = NSLocalizedString(
            "system_action.notification.private_title",
            value: "DayPage Notification",
            comment: "Generic notification title that contains no proposal content"
        )
        let privateBody = NSLocalizedString(
            "system_action.notification.private_body",
            value: "Open DayPage to view notification details.",
            comment: "Generic notification body that contains no proposal content"
        )
        switch redactionLevel {
        case .privateOnLockScreen:
            return (privateTitle, privateBody, nil)
        case .titleOnly:
            return (payload.title, privateBody, nil)
        case .boundedSummary:
            // Thread identifiers are grouping metadata shown outside the app.
            // They are never required to schedule or reconcile a DayPage
            // action, so keep them off every lock-screen-visible request.
            return (payload.title, payload.body, nil)
        }
    }

    func reconcile(proposal: SystemActionProposal, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionReconciliationResult {
        if await client.reconcile(actionID: proposal.id) {
            let identifier = AppleNotificationClient.requestIdentifier(actionID: proposal.id)
            return confirmedResult(code: "notification_reconciled", identifier: identifier)
        }
        // The request may already have fired. Absence from pending requests is
        // not proof that scheduling never occurred, so never duplicate it.
        return needsReview("notification_missing_or_delivered")
    }

    func undo(proposal: SystemActionProposal, originalReceipt: SystemActionReceipt, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionAdapterResult {
        guard await client.reconcile(actionID: proposal.id) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.notifications)
        }
        client.cancel(actionID: proposal.id)
        guard !(await client.reconcile(actionID: proposal.id)) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.notifications)
        }
        return .init(outcome: .succeeded, boundedResult: .init(summaryCode: "notification_cancelled"))
    }
}

final class AppleRouteSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .route
    let rollbackCapability: SystemActionRollbackCapability = .manual
    private let client: AppleMapClient

    @MainActor init(client: AppleMapClient? = nil) {
        self.client = client ?? AppleMapClient()
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        snapshot(kind: kind, state: .authorized)
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .route(let payload) = proposal.payload, payload.opensImmediately else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "route.opens_immediately")
        }
        let mode: AppleMapClient.RouteMode
        switch payload.mode {
        case .any: mode = .any
        case .driving: mode = .driving
        case .walking: mode = .walking
        case .transit: mode = .transit
        case .cycling: mode = .cycling
        }
        do {
            try await client.openRoute(
                latitude: payload.destination.latitude,
                longitude: payload.destination.longitude,
                address: payload.destination.address,
                label: payload.destination.label ?? payload.destination.address,
                mode: mode
            )
            return .init(outcome: .succeeded, boundedResult: .init(summaryCode: "route_opened"))
        } catch AppleSystemActionAdapterError.userCancelled(.maps) {
            return .init(outcome: .cancelled, errorCode: "maps_cancelled")
        }
    }
}

@available(iOS 16.1, *)
protocol AppleFocusEndAlertServing: Sendable {
    func schedule(
        actionID: UUID,
        title: String,
        body: String,
        fireDate: Date,
        threadIdentifier: String?,
        interruption: UNNotificationInterruptionLevel,
        playsSound: Bool
    ) async throws -> AppleExternalReference
    func reconcile(actionID: UUID) async -> Bool
    func cancel(actionID: UUID)
}

extension AppleNotificationClient: AppleFocusEndAlertServing {}

@available(iOS 16.1, *)
final class AppleFocusSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .focusSession
    let rollbackCapability: SystemActionRollbackCapability = .reversible
    private let activityClient: any AppleFocusActivityServing
    private let alertClient: any AppleFocusEndAlertServing
    private let alarmClient: any AppleFocusAlarmServing
    private let now: @Sendable () -> Date

    init(
        activityClient: any AppleFocusActivityServing = AppleFocusActivityClient(),
        alertClient: any AppleFocusEndAlertServing = AppleNotificationClient(),
        alarmClient: any AppleFocusAlarmServing = AppleFocusAlarmClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.activityClient = activityClient
        self.alertClient = alertClient
        self.alarmClient = alarmClient
        self.now = now
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        // Focus remains usable for an end alert even when Live Activities are
        // disabled, and also supports a local session with both surfaces off.
        .init(kind: kind, availability: .available, authorization: .notApplicable)
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .focusSession(let payload) = proposal.payload,
              payload.durationSeconds > 0 else { throw kindMismatch() }
        // The lease timestamp remains receipt evidence, but the user-approved
        // duration begins when this native session attempt actually starts.
        // Network and claim latency must not consume the focus window.
        let nativeStartedAt = now()
        let endsAt = nativeStartedAt.addingTimeInterval(TimeInterval(payload.durationSeconds))
        let displayTitle = proposal.redactionLevel == .privateOnLockScreen
            ? NSLocalizedString(
                "system_action.focus.private_title",
                value: "DayPage Focus",
                comment: "Redacted focus title"
            )
            : payload.title
        var activityReference: AppleExternalReference?
        var alertReference: AppleExternalReference?
        var alertSurface: String?
        do {
            if payload.schedulesEndAlert {
                let alertTitle = proposal.redactionLevel == .privateOnLockScreen ? "DayPage" : displayTitle
                if let alarmReference = await alarmClient.schedule(
                    actionID: proposal.id,
                    title: alertTitle,
                    fireDate: endsAt
                ) {
                    alertReference = alarmReference
                    alertSurface = "alarmkit"
                } else {
                    alertReference = try await alertClient.schedule(
                        actionID: proposal.id,
                        title: alertTitle,
                        body: NSLocalizedString(
                            "system_action.focus.notification.complete",
                            value: "Focus session complete",
                            comment: "Focus completion notification body"
                        ),
                        fireDate: endsAt,
                        threadIdentifier: nil,
                        interruption: .active,
                        playsSound: true
                    )
                    alertSurface = "notification"
                }
            }
            if payload.allowsLiveActivity {
                activityReference = try activityClient.start(
                    actionID: proposal.id,
                    title: displayTitle,
                    endsAt: endsAt,
                    schedulesEndAlert: payload.schedulesEndAlert
                )
                if let identifier = activityReference?.identifier {
                    activityClient.scheduleEnd(identifier: identifier, at: endsAt)
                }
            }
        } catch {
            if alertReference != nil { alertClient.cancel(actionID: proposal.id) }
            var compensationError: Error?
            do {
                try await alarmClient.cancel(actionID: proposal.id)
            } catch {
                compensationError = error
            }
            if let identifier = activityReference?.identifier { try? await activityClient.end(identifier: identifier) }
            if let compensationError { throw compensationError }
            throw error
        }
        var metadata: [String: String] = [:]
        metadata["focus_started_at"] = SystemActionCanonicalJSON.timestamp(nativeStartedAt)
        metadata["focus_ends_at"] = SystemActionCanonicalJSON.timestamp(endsAt)
        if let identifier = activityReference?.identifier { metadata["live_activity_id"] = identifier }
        if let identifier = alertReference?.identifier { metadata["end_alert_id"] = identifier }
        if let alertSurface { metadata["end_alert_surface"] = alertSurface }
        return .init(
            outcome: .succeeded,
            boundedResult: .init(
                summaryCode: "focus_started",
                metadata: [
                    "scheduled_at": SystemActionCanonicalJSON.timestamp(endsAt),
                    "end_alert_surface": alertSurface ?? "none"
                ]
            ),
            localMaterial: metadata.isEmpty ? nil : .init(
                externalIdentifier: activityReference?.identifier ?? alertReference?.identifier,
                metadata: metadata
            )
        )
    }

    func reconcile(proposal: SystemActionProposal, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionReconciliationResult {
        guard case .focusSession(let payload) = proposal.payload else { throw kindMismatch() }
        let activityID = material?.metadata["live_activity_id"]
            ?? activityClient.identifier(actionID: proposal.id)
        let activityPresent = !payload.allowsLiveActivity
            || activityID.map(activityClient.reconcile(identifier:)) == true
        let alertPresent: Bool
        if payload.schedulesEndAlert {
            switch material?.metadata["end_alert_surface"] {
            case "alarmkit":
                alertPresent = await alarmClient.reconcile(actionID: proposal.id)
            case "notification":
                alertPresent = await alertClient.reconcile(actionID: proposal.id)
            default:
                // Crash before local material commit: either one proves that
                // the exact action ID was durably scheduled; never duplicate.
                let alarmPresent = await alarmClient.reconcile(actionID: proposal.id)
                let notificationPresent = await alertClient.reconcile(actionID: proposal.id)
                alertPresent = alarmPresent || notificationPresent
            }
        } else {
            alertPresent = true
        }
        let expectedCount = (payload.allowsLiveActivity ? 1 : 0) + (payload.schedulesEndAlert ? 1 : 0)
        let presentCount = (payload.allowsLiveActivity && activityPresent ? 1 : 0)
            + (payload.schedulesEndAlert && alertPresent ? 1 : 0)
        let endsAt = material?.metadata["focus_ends_at"]
            .flatMap(SystemActionCanonicalJSON.date(fromCanonicalTimestamp:))
            ?? context.startedAt.addingTimeInterval(TimeInterval(payload.durationSeconds))
        if endsAt <= now() {
            if let activityID, activityPresent { try? await activityClient.end(identifier: activityID) }
            if alertPresent && payload.schedulesEndAlert {
                alertClient.cancel(actionID: proposal.id)
                try await alarmClient.cancel(actionID: proposal.id)
            }
            // Once the approved window elapsed, absence of both effects no
            // longer proves they were never created. Never start a duplicate.
            return needsReview("focus_window_elapsed")
        }
        if presentCount == expectedCount {
            var recoveredMetadata = material?.metadata ?? [:]
            if let activityID { recoveredMetadata["live_activity_id"] = activityID }
            if payload.schedulesEndAlert {
                if await alarmClient.reconcile(actionID: proposal.id) {
                    recoveredMetadata["end_alert_id"] = "alarmkit:\(proposal.id.uuidString.lowercased())"
                    recoveredMetadata["end_alert_surface"] = "alarmkit"
                } else {
                    recoveredMetadata["end_alert_id"] = AppleNotificationClient.requestIdentifier(actionID: proposal.id)
                    recoveredMetadata["end_alert_surface"] = "notification"
                }
            }
            return .init(
                disposition: .confirmed,
                confirmedResult: .init(
                    outcome: .succeeded,
                    boundedResult: .init(summaryCode: "focus_reconciled"),
                    localMaterial: recoveredMetadata.isEmpty ? nil : .init(
                        externalIdentifier: activityID ?? recoveredMetadata["end_alert_id"],
                        metadata: recoveredMetadata
                    ),
                    reconciliationState: .reconciled
                )
            )
        }
        if presentCount == 0 {
            return .init(disposition: .safeToRetry, errorCode: "focus_effects_missing")
        }
        return needsReview("focus_partial_effects")
    }

    func undo(proposal: SystemActionProposal, originalReceipt: SystemActionReceipt, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionAdapterResult {
        guard case .focusSession(let payload) = proposal.payload else { throw kindMismatch() }
        if payload.schedulesEndAlert {
            alertClient.cancel(actionID: proposal.id)
            try await alarmClient.cancel(actionID: proposal.id)
            let notificationPresent = await alertClient.reconcile(actionID: proposal.id)
            let alarmPresent = await alarmClient.reconcile(actionID: proposal.id)
            if notificationPresent || alarmPresent {
                throw AppleSystemActionAdapterError.ambiguousOutcome(.notifications)
            }
        }
        if payload.allowsLiveActivity {
            guard let identifier = material?.metadata["live_activity_id"]
                    ?? activityClient.identifier(actionID: proposal.id) else {
                throw AppleSystemActionAdapterError.ambiguousOutcome(.liveActivity)
            }
            try await activityClient.end(identifier: identifier)
        }
        return .init(outcome: .succeeded, boundedResult: .init(summaryCode: "focus_ended"))
    }
}

final class AppleMomentSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .moment
    let rollbackCapability: SystemActionRollbackCapability = .none
    private let locationClient: any AppleOneShotLocationServing
    private let momentStore: any AppleMomentPersisting

    @MainActor init(
        locationClient: (any AppleOneShotLocationServing)? = nil,
        momentStore: any AppleMomentPersisting = AppleMomentStore.shared
    ) {
        self.locationClient = locationClient ?? AppleOneShotLocationClient()
        self.momentStore = momentStore
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        await snapshot(kind: kind, state: locationClient.authorizationState())
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .moment(let payload) = proposal.payload else { throw kindMismatch() }
        guard let locationRequest = payload.location else {
            let recordID = try await momentStore.complete(proposal: proposal, coordinate: nil)
            return .init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "moment_captured"),
                localMaterial: .init(metadata: ["moment_record_id": recordID.uuidString.lowercased()])
            )
        }

        // The approved v1 contract binds only the intent to obtain one fresh,
        // owner-device sample. Coordinates supplied by the proposal are never
        // trusted or used as executable inputs.
        guard locationRequest.latitude == nil, locationRequest.longitude == nil else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "moment.location.coordinate")
        }
        do {
            let sample = try await locationClient.requestCurrentLocation()
            let recordID = try await momentStore.complete(
                proposal: proposal,
                coordinate: .init(latitude: sample.latitude, longitude: sample.longitude)
            )
            var metadata = [
                "latitude": String(format: "%.6f", sample.latitude),
                "longitude": String(format: "%.6f", sample.longitude),
                "moment_record_id": recordID.uuidString.lowercased(),
            ]
            metadata["horizontal_accuracy"] = String(format: "%.1f", sample.horizontalAccuracy)
            return .init(
                outcome: .succeeded,
                boundedResult: .init(summaryCode: "moment_location_captured"),
                localMaterial: .init(metadata: metadata)
            )
        } catch AppleSystemActionAdapterError.userCancelled(.location) {
            return .init(outcome: .cancelled, errorCode: "location_cancelled")
        }
    }

    func reconcile(proposal: SystemActionProposal, context: SystemActionExecutionContext, material: SystemActionLocalMaterial?) async throws -> SystemActionReconciliationResult {
        guard case .moment(let payload) = proposal.payload else { throw kindMismatch() }
        guard let recordValue = material?.metadata["moment_record_id"],
              let recordID = UUID(uuidString: recordValue),
              await momentStore.isCompleted(id: recordID, proposalID: proposal.id) else {
            return needsReview("moment_record_missing")
        }
        guard payload.location != nil else {
            return .init(
                disposition: .confirmed,
                confirmedResult: .init(
                    outcome: .succeeded,
                    boundedResult: .init(summaryCode: "moment_reconciled")
                )
            )
        }
        guard material?.metadata["latitude"] != nil, material?.metadata["longitude"] != nil else {
            return .init(disposition: .safeToRetry, errorCode: "moment_location_missing")
        }
        return .init(
            disposition: .confirmed,
            confirmedResult: .init(outcome: .succeeded, boundedResult: .init(summaryCode: "moment_reconciled"))
        )
    }
}

final class AppleCaptureSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .capture
    let rollbackCapability: SystemActionRollbackCapability = .none
    private let uiBroker: SystemActionUIBroker

    @MainActor init(uiBroker: SystemActionUIBroker? = nil) {
        self.uiBroker = uiBroker ?? .shared
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        // The kind also includes PhotosPicker, file importer, PencilKit, and
        // text entry. Concrete hardware is checked by the presenting UI.
        .init(kind: kind, availability: .available, authorization: .notApplicable)
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .capture(let payload) = proposal.payload else { throw kindMismatch() }
        let sourceMemoID = proposal.sourceReferences.first(where: { $0.kind == .memo })
            .flatMap { UUID(uuidString: $0.identifier) }
        do {
            let artifact = try await uiBroker.presentCapture(
                actionID: proposal.id,
                kind: payload.captureKind,
                suggestedTitle: payload.suggestedTitle,
                attachesToSource: payload.attachesToSource,
                sourceMemoID: sourceMemoID
            )
            guard artifact.kind == payload.captureKind else {
                throw AppleSystemActionAdapterError.invalidPayload(field: "capture.kind")
            }
            return .init(
                outcome: .succeeded,
                boundedResult: .init(
                    summaryCode: "capture_completed",
                    metadata: artifact.boundedReceiptMetadata
                ),
                localMaterial: .init(metadata: artifact.localReceiptMetadata)
            )
        } catch AppleSystemActionAdapterError.userCancelled(.capture) {
            return .init(outcome: .cancelled, errorCode: "capture_cancelled")
        }
    }
}

final class AppleLocalContextSystemActionAdapter: @unchecked Sendable, SystemActionNativeAdapter {
    let kind: SystemActionKind = .localContextAttachment
    let rollbackCapability: SystemActionRollbackCapability = .none
    private let verifier: any AppleLocalContextReferenceVerifying

    init(verifier: any AppleLocalContextReferenceVerifying = AppleLocalContextStore.shared) {
        self.verifier = verifier
    }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot {
        snapshot(kind: kind, state: .authorized)
    }

    func execute(proposal: SystemActionProposal, context: SystemActionExecutionContext) async throws -> SystemActionAdapterResult {
        guard case .localContextAttachment(let payload) = proposal.payload else { throw kindMismatch() }
        let referenceID = try AppleLocalContextReference.parse(payload.summaryCode)
        guard await verifier.contains(referenceID: referenceID, kind: payload.contextKind) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.localContext)
        }
        return .init(
            outcome: .succeeded,
            boundedResult: .init(
                summaryCode: "local_context_attached",
                metadata: ["context_kind": payload.contextKind.rawValue]
            ),
            localMaterial: .init(metadata: [
                "context_reference": referenceID.uuidString.lowercased()
            ])
        )
    }

    func reconcile(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionReconciliationResult {
        guard case .localContextAttachment(let payload) = proposal.payload,
              let referenceValue = material?.metadata["context_reference"],
              let referenceID = UUID(uuidString: referenceValue) else {
            return needsReview("local_context_reference_missing")
        }
        guard await verifier.contains(referenceID: referenceID, kind: payload.contextKind) else {
            return needsReview("local_context_record_missing")
        }
        return .init(
            disposition: .confirmed,
            confirmedResult: .init(
                outcome: .succeeded,
                boundedResult: .init(
                    summaryCode: "local_context_reconciled",
                    metadata: ["context_kind": payload.contextKind.rawValue]
                ),
                localMaterial: material,
                reconciliationState: .reconciled
            )
        )
    }
}

private func kindMismatch() -> AppleSystemActionAdapterError {
    .invalidPayload(field: "kind")
}

private func snapshot(kind: SystemActionKind, state: AppleAuthorizationState) -> SystemActionCapabilitySnapshot {
    let authorization: SystemActionAuthorizationState
    let availability: SystemActionAvailability
    switch state {
    case .notDetermined:
        authorization = .notDetermined
        availability = .requiresPermission
    case .authorized:
        authorization = .full
        availability = .available
    case .writeOnly:
        authorization = .writeOnly
        availability = .available
    case .limited:
        authorization = .limited
        availability = .available
    case .denied:
        authorization = .denied
        availability = .requiresPermission
    case .restricted:
        authorization = .restricted
        availability = .unavailable
    case .unavailable:
        authorization = .unsupported("unavailable")
        availability = .unavailable
    }
    return .init(kind: kind, availability: availability, authorization: authorization)
}

private func successfulResult(
    code: String,
    reference: AppleExternalReference,
    reconciliation: SystemActionReconciliationState = .notNeeded
) -> SystemActionAdapterResult {
    .init(
        outcome: .succeeded,
        boundedResult: .init(summaryCode: code, externalIdentifierHash: identifierHash(reference.identifier)),
        localMaterial: .init(
            externalIdentifier: reference.identifier,
            beforeSnapshot: reference.snapshot
        ),
        reconciliationState: reconciliation
    )
}

private func externallyModifiedUndoResult(_ errorCode: String) -> SystemActionAdapterResult {
    .init(
        outcome: .failed,
        errorCode: errorCode,
        reconciliationState: .needsReview
    )
}

private func identifierHash(_ identifier: String) -> String {
    SystemActionCanonicalJSON.sha256(of: Data(identifier.utf8))
}

private func needsReview(_ errorCode: String) -> SystemActionReconciliationResult {
    .init(disposition: .needsReview, errorCode: errorCode)
}

private func confirmedResult(code: String, identifier: String) -> SystemActionReconciliationResult {
    .init(
        disposition: .confirmed,
        confirmedResult: .init(
            outcome: .succeeded,
            boundedResult: .init(summaryCode: code, externalIdentifierHash: identifierHash(identifier)),
            localMaterial: .init(externalIdentifier: identifier),
            reconciliationState: .reconciled
        )
    )
}
