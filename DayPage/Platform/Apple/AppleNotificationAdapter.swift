import Foundation
import UserNotifications

protocol AppleNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func timeSensitiveSetting() async -> UNNotificationSetting
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequestIdentifiers() async -> Set<String>
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: AppleNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    func pendingRequestIdentifiers() async -> Set<String> {
        Set(await pendingNotificationRequests().map(\.identifier))
    }

    func timeSensitiveSetting() async -> UNNotificationSetting {
        await notificationSettings().timeSensitiveSetting
    }
}

final class AppleNotificationClient: @unchecked Sendable {
    private let center: AppleNotificationCenter
    private let now: @Sendable () -> Date

    init(
        center: AppleNotificationCenter = UNUserNotificationCenter.current(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.center = center
        self.now = now
    }

    func authorizationState() async -> AppleAuthorizationState {
        switch await center.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default: return .unavailable
        }
    }

    func resolvedInterruptionLevel(
        _ requested: UNNotificationInterruptionLevel
    ) async -> UNNotificationInterruptionLevel {
        guard requested == .timeSensitive else { return requested }
        return await center.timeSensitiveSetting() == .enabled ? .timeSensitive : .active
    }

    func schedule(
        actionID: UUID,
        title: String,
        body: String,
        fireDate: Date,
        threadIdentifier: String?,
        interruption: UNNotificationInterruptionLevel,
        playsSound: Bool
    ) async throws -> AppleExternalReference {
        guard fireDate > now() else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "fireDate")
        }
        let state = await authorizationState()
        if state == .notDetermined {
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.notifications)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .notifications,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if state == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.notifications)
        }

        let identifier = Self.requestIdentifier(actionID: actionID)
        let content = UNMutableNotificationContent()
        // These strings have already passed the proposal contract and review
        // redaction preview. Do not silently trim, collapse line breaks, or
        // apply a second smaller limit after approval.
        content.title = title
        content.body = body
        content.sound = playsSound ? .default : nil
        content.threadIdentifier = threadIdentifier ?? ""
        if #available(iOS 15.0, *) {
            content.interruptionLevel = await resolvedInterruptionLevel(interruption)
        }
        content.userInfo = ["systemActionID": actionID.uuidString.lowercased()]
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second],
            from: fireDate
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )
        do { try await center.add(request) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .notifications,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
        return AppleExternalReference(identifier: identifier, createdAt: now())
    }

    func reconcile(actionID: UUID) async -> Bool {
        await center.pendingRequestIdentifiers().contains(Self.requestIdentifier(actionID: actionID))
    }

    func cancel(actionID: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier(actionID: actionID)])
    }

    static func requestIdentifier(actionID: UUID) -> String {
        "daypage.system-action.\(actionID.uuidString.lowercased())"
    }
}
