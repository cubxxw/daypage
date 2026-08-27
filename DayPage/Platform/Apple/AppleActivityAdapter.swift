import ActivityKit
import Foundation
import UIKit
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
#endif

@available(iOS 16.1, *)
struct DayPageFocusActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let endsAt: Date
        let isPaused: Bool
        let remainingSeconds: Int?

        init(endsAt: Date, isPaused: Bool, remainingSeconds: Int? = nil) {
            self.endsAt = endsAt
            self.isPaused = isPaused
            self.remainingSeconds = remainingSeconds
        }
    }

    /// Privacy-minimized correlation ID. No memo text or account identity.
    let actionID: UUID
    let boundedTitle: String
    let schedulesEndAlert: Bool?
}

@available(iOS 16.1, *)
protocol AppleFocusActivityServing: Sendable {
    func capabilityState() -> AppleAuthorizationState
    func start(
        actionID: UUID,
        title: String,
        endsAt: Date,
        schedulesEndAlert: Bool
    ) throws -> AppleExternalReference
    func identifier(actionID: UUID) -> String?
    func reconcile(identifier: String) -> Bool
    func scheduleEnd(identifier: String, at date: Date)
    func update(identifier: String, endsAt: Date, isPaused: Bool) async throws
    func end(identifier: String) async throws
}

@available(iOS 16.1, *)
final class AppleFocusActivityClient: @unchecked Sendable, AppleFocusActivityServing {
    private let now: @Sendable () -> Date
    private var foregroundObserver: NSObjectProtocol?

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        recoverScheduledEnds()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.endElapsedActivities()
        }
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    func capabilityState() -> AppleAuthorizationState {
        ActivityAuthorizationInfo().areActivitiesEnabled ? .authorized : .denied
    }

    func start(
        actionID: UUID,
        title: String,
        endsAt: Date,
        schedulesEndAlert: Bool
    ) throws -> AppleExternalReference {
        guard endsAt > Date() else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "endsAt")
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw AppleSystemActionAdapterError.authorizationDenied(.liveActivity)
        }
        let attributes = DayPageFocusActivityAttributes(
            actionID: actionID,
            boundedTitle: AppleAdapterPrivacy.boundedPublicText(title, limit: 48),
            schedulesEndAlert: schedulesEndAlert
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                contentState: .init(endsAt: endsAt, isPaused: false),
                pushType: nil
            )
            return AppleExternalReference(identifier: activity.id, createdAt: Date())
        } catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .liveActivity,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }

    func reconcile(identifier: String) -> Bool {
        Activity<DayPageFocusActivityAttributes>.activities.contains { $0.id == identifier }
    }

    func identifier(actionID: UUID) -> String? {
        Activity<DayPageFocusActivityAttributes>.activities.first {
            $0.attributes.actionID == actionID
        }?.id
    }

    func scheduleEnd(identifier: String, at date: Date) {
        let delay = max(0, date.timeIntervalSince(now()))
        Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self,
                  let activity = Activity<DayPageFocusActivityAttributes>.activities.first(where: { $0.id == identifier }) else {
                return
            }
            if activity.contentState.isPaused { return }
            if activity.contentState.endsAt > self.now() {
                self.scheduleEnd(identifier: identifier, at: activity.contentState.endsAt)
            } else {
                try? await self.end(identifier: identifier)
            }
        }
    }

    func update(identifier: String, endsAt: Date, isPaused: Bool) async throws {
        guard let activity = Activity<DayPageFocusActivityAttributes>.activities.first(where: { $0.id == identifier }) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.liveActivity)
        }
        let remaining = isPaused ? max(0, Int(endsAt.timeIntervalSince(now()).rounded(.up))) : nil
        await activity.update(using: .init(
            endsAt: endsAt,
            isPaused: isPaused,
            remainingSeconds: remaining
        ))
        if !isPaused { scheduleEnd(identifier: identifier, at: endsAt) }
    }

    func end(identifier: String) async throws {
        guard let activity = Activity<DayPageFocusActivityAttributes>.activities.first(where: { $0.id == identifier }) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.liveActivity)
        }
        await activity.end(dismissalPolicy: .immediate)
    }

    private func recoverScheduledEnds() {
        for activity in Activity<DayPageFocusActivityAttributes>.activities {
            scheduleEnd(identifier: activity.id, at: activity.contentState.endsAt)
        }
    }

    /// Suspension can delay an in-process timer. Foregrounding deterministically
    /// reconciles every elapsed DayPage activity even when no coordinator retry
    /// occurs, while future activities retain their original scheduled task.
    private func endElapsedActivities() {
        let cutoff = now()
        let elapsed = Activity<DayPageFocusActivityAttributes>.activities.filter {
            !$0.contentState.isPaused && $0.contentState.endsAt <= cutoff
        }
        for activity in elapsed {
            Task { [weak self] in
                try? await self?.end(identifier: activity.id)
            }
        }
    }
}

protocol AppleFocusAlarmServing: Sendable {
    /// Returns nil when AlarmKit is unavailable or the user declines its JIT
    /// authorization, allowing the caller to visibly fall back to a local
    /// notification without creating two end alerts.
    func schedule(actionID: UUID, title: String, fireDate: Date) async -> AppleExternalReference?
    func reconcile(actionID: UUID) async -> Bool
    func cancel(actionID: UUID) async throws
}

final class AppleFocusAlarmClient: @unchecked Sendable, AppleFocusAlarmServing {
    func schedule(actionID: UUID, title: String, fireDate: Date) async -> AppleExternalReference? {
        guard fireDate > Date() else { return nil }
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return await scheduleAlarm(actionID: actionID, title: title, fireDate: fireDate)
        }
        #endif
        return nil
    }

    func reconcile(actionID: UUID) async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            return ((try? AlarmManager.shared.alarms) ?? []).contains { $0.id == actionID }
        }
        #endif
        return false
    }

    func cancel(actionID: UUID) async throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                try AlarmManager.shared.cancel(id: actionID)
            } catch {
                throw AppleSystemActionAdapterError.ambiguousOutcome(.notifications)
            }
        }
        #endif
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private struct FocusAlarmMetadata: AlarmMetadata {
        let actionID: String
    }

    @available(iOS 26.0, *)
    private func scheduleAlarm(
        actionID: UUID,
        title: String,
        fireDate: Date
    ) async -> AppleExternalReference? {
        let manager = AlarmManager.shared
        let state: AlarmManager.AuthorizationState
        switch manager.authorizationState {
        case .authorized:
            state = .authorized
        case .notDetermined:
            state = (try? await manager.requestAuthorization()) ?? .denied
        case .denied:
            state = .denied
        @unknown default:
            state = .denied
        }
        guard state == .authorized else { return nil }

        let boundedTitle = AppleAdapterPrivacy.boundedPublicText(title, limit: 48)
        let stop = AlarmButton(
            text: LocalizedStringResource(stringLiteral: "结束"),
            textColor: .white,
            systemImageName: "stop.fill"
        )
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: boundedTitle)
            )
        } else {
            alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: boundedTitle),
                stopButton: stop
            )
        }
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: FocusAlarmMetadata(actionID: actionID.uuidString.lowercased()),
            tintColor: Color.orange
        )
        let configuration = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: .fixed(fireDate),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )
        do {
            _ = try await manager.schedule(id: actionID, configuration: configuration)
            return AppleExternalReference(
                identifier: "alarmkit:\(actionID.uuidString.lowercased())",
                createdAt: Date()
            )
        } catch {
            return nil
        }
    }
    #endif
}

/// The main app owns all end-alert side effects. Live Activity intents write a
/// one-shot App Group request and open the app; this service then keeps the
/// activity, notification and AlarmKit timer on the same paused/resumed clock.
@available(iOS 16.1, *)
enum AppleFocusSessionControlService {
    static func apply(_ request: SystemActionSharedSummaryStore.FocusControlRequest) async throws {
        guard let activity = Activity<DayPageFocusActivityAttributes>.activities.first(where: {
            $0.attributes.actionID == request.actionID
        }) else {
            // End is idempotent when the extension already dismissed the Live
            // Activity; still clear every possible alert surface.
            if request.operation == .end {
                try await cancelAlerts(actionID: request.actionID)
                return
            }
            throw AppleSystemActionAdapterError.ambiguousOutcome(.liveActivity)
        }

        let activityClient = AppleFocusActivityClient()
        switch request.operation {
        case .pause:
            let remaining = max(
                0,
                request.remainingSeconds
                    ?? activity.contentState.remainingSeconds
                    ?? Int(activity.contentState.endsAt.timeIntervalSinceNow.rounded(.up))
            )
            try await activityClient.update(
                identifier: activity.id,
                endsAt: Date().addingTimeInterval(TimeInterval(remaining)),
                isPaused: true
            )
            try await cancelAlerts(actionID: request.actionID)
        case .resume:
            let remaining = max(
                1,
                request.remainingSeconds ?? activity.contentState.remainingSeconds ?? 1
            )
            let endsAt = Date().addingTimeInterval(TimeInterval(remaining))
            try await applyResumeTransaction(
                schedule: {
                    guard activity.attributes.schedulesEndAlert == true else { return }
                    try await scheduleAlert(
                        actionID: request.actionID,
                        title: activity.attributes.boundedTitle,
                        fireDate: endsAt
                    )
                },
                update: {
                    try await activityClient.update(
                        identifier: activity.id,
                        endsAt: endsAt,
                        isPaused: false
                    )
                },
                cancel: { try await cancelAlerts(actionID: request.actionID) }
            )
        case .end:
            if Activity<DayPageFocusActivityAttributes>.activities.contains(where: { $0.id == activity.id }) {
                try await activityClient.end(identifier: activity.id)
            }
            try await cancelAlerts(actionID: request.actionID)
        }
    }

    /// Scheduling an end alert before the activity update avoids a resumed
    /// countdown with no alert. If the second step fails, compensate by
    /// cancelling the deterministic AlarmKit/notification identifiers so a
    /// still-paused session cannot fire a stale completion alert.
    static func applyResumeTransaction(
        schedule: () async throws -> Void,
        update: () async throws -> Void,
        cancel: () async throws -> Void
    ) async throws {
        try await schedule()
        do {
            try await update()
        } catch {
            try await cancel()
            throw error
        }
    }

    private static func scheduleAlert(actionID: UUID, title: String, fireDate: Date) async throws {
        let alarmClient = AppleFocusAlarmClient()
        if await alarmClient.schedule(actionID: actionID, title: title, fireDate: fireDate) != nil {
            return
        }
        _ = try await AppleNotificationClient().schedule(
            actionID: actionID,
            title: title,
            body: NSLocalizedString(
                "system_action.focus.notification.complete",
                value: "Focus session complete",
                comment: "Focus completion notification body"
            ),
            fireDate: fireDate,
            threadIdentifier: nil,
            interruption: .active,
            playsSound: true
        )
    }

    private static func cancelAlerts(actionID: UUID) async throws {
        AppleNotificationClient().cancel(actionID: actionID)
        try await AppleFocusAlarmClient().cancel(actionID: actionID)
    }
}
