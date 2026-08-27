import EventKit
import Foundation

protocol AppleEventStore: AnyObject {
    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus
    func requestLegacyAccess(to entityType: EKEntityType) async throws -> Bool
    @available(iOS 17.0, *)
    func requestWriteOnlyEventAccess() async throws -> Bool
    @available(iOS 17.0, *)
    func requestFullEventAccess() async throws -> Bool
    @available(iOS 17.0, *)
    func requestFullReminderAccess() async throws -> Bool
    var defaultCalendarForNewEvents: EKCalendar? { get }
    func defaultCalendarForNewReminders() -> EKCalendar?
    func calendars(for entityType: EKEntityType) -> [EKCalendar]
    func save(event: EKEvent, span: EKSpan) throws
    func save(reminder: EKReminder, commit: Bool) throws
    func event(withIdentifier identifier: String) -> EKEvent?
    func predicateForEvents(withStart startDate: Date, end endDate: Date) -> NSPredicate
    func events(matching predicate: NSPredicate) -> [EKEvent]
    func calendarItem(withIdentifier identifier: String) -> EKCalendarItem?
    func remove(event: EKEvent, span: EKSpan) throws
    func remove(reminder: EKReminder, commit: Bool) throws
}

extension EKEventStore: AppleEventStore {
    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus {
        Self.authorizationStatus(for: entityType)
    }

    func requestLegacyAccess(to entityType: EKEntityType) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            requestAccess(to: entityType) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    @available(iOS 17.0, *)
    func requestWriteOnlyEventAccess() async throws -> Bool {
        try await requestWriteOnlyAccessToEvents()
    }

    @available(iOS 17.0, *)
    func requestFullEventAccess() async throws -> Bool {
        try await requestFullAccessToEvents()
    }

    @available(iOS 17.0, *)
    func requestFullReminderAccess() async throws -> Bool {
        try await requestFullAccessToReminders()
    }

    func save(event: EKEvent, span: EKSpan) throws {
        try save(event, span: span, commit: true)
    }

    func save(reminder: EKReminder, commit: Bool) throws {
        try save(reminder, commit: commit)
    }

    func remove(event: EKEvent, span: EKSpan) throws {
        try remove(event, span: span, commit: true)
    }

    func remove(reminder: EKReminder, commit: Bool) throws {
        try remove(reminder, commit: commit)
    }

    func predicateForEvents(withStart startDate: Date, end endDate: Date) -> NSPredicate {
        predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
    }
}

@MainActor
final class AppleCalendarClient {
    private let store: AppleEventStore
    private let now: @Sendable () -> Date

    init(store: AppleEventStore = EKEventStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    func authorizationState() -> AppleAuthorizationState {
        Self.map(store.authorizationStatus(for: .event))
    }

    /// Writes the exact values already approved in DayPage. Presenting an
    /// editable EventKitUI controller here would let the system sheet mutate
    /// fields outside the proposal hash before the receipt is recorded.
    func createEvent(
        title: String,
        start: Date,
        end: Date,
        notes: String?,
        isAllDay: Bool,
        timeZoneIdentifier: String?,
        location: String?,
        actionID: UUID
    ) async throws -> AppleExternalReference {
        guard end > start else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "end")
        }
        let state = authorizationState()
        if state == .notDetermined {
            do {
                let granted: Bool
                if #available(iOS 17.0, *) {
                    granted = try await store.requestWriteOnlyEventAccess()
                } else {
                    granted = try await store.requestLegacyAccess(to: .event)
                }
                guard granted else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.calendar)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .calendar,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if state == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.calendar)
        } else if state == .restricted {
            throw AppleSystemActionAdapterError.authorizationRestricted(.calendar)
        }

        guard let calendar = store.defaultCalendarForNewEvents else {
            throw AppleSystemActionAdapterError.unavailable(.calendar)
        }
        let event = EKEvent(eventStore: store as? EKEventStore ?? EKEventStore())
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = isAllDay
        event.timeZone = try resolvedTimeZone(timeZoneIdentifier)
        event.location = location
        event.notes = notes
        event.url = URL(string: "daypage://system-action/\(actionID.uuidString.lowercased())")
        do {
            try store.save(event: event, span: .thisEvent)
        } catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .calendar,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
        guard let identifier = event.eventIdentifier, !identifier.isEmpty else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.calendar)
        }
        return AppleExternalReference(
            identifier: identifier,
            createdAt: now(),
            snapshot: try Self.snapshotData(for: event)
        )
    }

    /// Deletes only while all DayPage-created fields still match the exact
    /// device-local snapshot. A user edit turns undo into reconciliation
    /// instead of destructive blind deletion.
    func removeIfUnchanged(identifier: String, expectedSnapshot: Data?) async throws -> Bool {
        let initialState = authorizationState()
        if initialState == .notDetermined || initialState == .writeOnly {
            do {
                let granted: Bool
                if #available(iOS 17.0, *) {
                    granted = try await store.requestFullEventAccess()
                } else {
                    granted = try await store.requestLegacyAccess(to: .event)
                }
                guard granted else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.calendar)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .calendar,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if initialState == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.calendar)
        } else if initialState == .restricted {
            throw AppleSystemActionAdapterError.authorizationRestricted(.calendar)
        }
        guard let event = store.event(withIdentifier: identifier) else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.calendar)
        }
        guard let expectedSnapshot,
              try Self.snapshotData(for: event) == expectedSnapshot else {
            return false
        }
        do { try store.remove(event: event, span: .thisEvent) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .calendar,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
        return true
    }

    func contains(identifier: String) -> Bool {
        store.event(withIdentifier: identifier) != nil
    }

    /// Full-access reconciliation only: the action marker and approved time
    /// window provide a narrow lookup after a crash before local material was
    /// committed. Write-only authorization deliberately does not escalate.
    func identifier(actionID: UUID, start: Date, end: Date) -> String? {
        guard authorizationState() == .authorized else { return nil }
        let lower = min(start, end).addingTimeInterval(-60)
        let upper = max(start, end).addingTimeInterval(60)
        let predicate = store.predicateForEvents(withStart: lower, end: upper)
        let marker = "daypage://system-action/\(actionID.uuidString.lowercased())"
        return store.events(matching: predicate).first {
            $0.url?.absoluteString.lowercased() == marker
        }?.eventIdentifier
    }

    private static func map(_ status: EKAuthorizationStatus) -> AppleAuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .writeOnly: return .writeOnly
        case .authorized, .fullAccess: return .authorized
        @unknown default: return .unavailable
        }
    }

    private func resolvedTimeZone(_ identifier: String?) throws -> TimeZone {
        guard let identifier else {
            return TimeZone(secondsFromGMT: 0) ?? .gmt
        }
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "timeZone")
        }
        return timeZone
    }

    private struct Snapshot: Codable {
        let title: String?
        let start: Double
        let end: Double
        let notes: String?
        let isAllDay: Bool
        let timeZoneIdentifier: String?
        let location: String?
        let url: String?
        let calendarIdentifier: String?
    }

    static func snapshotData(for event: EKEvent) throws -> Data {
        let snapshot = Snapshot(
            title: event.title,
            start: event.startDate.timeIntervalSince1970,
            end: event.endDate.timeIntervalSince1970,
            notes: event.notes,
            isAllDay: event.isAllDay,
            timeZoneIdentifier: event.timeZone?.identifier,
            location: event.location,
            url: event.url?.absoluteString,
            calendarIdentifier: event.calendar?.calendarIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}

@MainActor
final class AppleRemindersClient {
    private let store: AppleEventStore
    private let now: @Sendable () -> Date

    init(store: AppleEventStore = EKEventStore(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    func authorizationState() -> AppleAuthorizationState {
        switch store.authorizationStatus(for: .reminder) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized, .fullAccess, .writeOnly: return .authorized
        @unknown default: return .unavailable
        }
    }

    func createReminder(
        title: String,
        notes: String?,
        dueDate: Date?,
        timeZoneIdentifier: String?,
        listHint: String?,
        priority: Int?
    ) async throws -> AppleExternalReference {
        let state = authorizationState()
        if state == .notDetermined {
            do {
                let granted: Bool
                if #available(iOS 17.0, *) {
                    granted = try await store.requestFullReminderAccess()
                } else {
                    granted = try await store.requestLegacyAccess(to: .reminder)
                }
                guard granted else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.reminders)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .reminders,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if state == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.reminders)
        } else if state == .restricted {
            throw AppleSystemActionAdapterError.authorizationRestricted(.reminders)
        }
        let hintedCalendar = listHint.flatMap { hint in
            store.calendars(for: .reminder).first { $0.title.localizedCaseInsensitiveCompare(hint) == .orderedSame }
        }
        guard let calendar = hintedCalendar ?? store.defaultCalendarForNewReminders() else {
            throw AppleSystemActionAdapterError.unavailable(.reminders)
        }
        let reminder = EKReminder(eventStore: store as? EKEventStore ?? EKEventStore())
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        if let priority { reminder.priority = min(9, max(0, priority)) }
        if let dueDate {
            var calendar = Calendar(identifier: .gregorian)
            if let timeZoneIdentifier {
                guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                    throw AppleSystemActionAdapterError.invalidPayload(field: "timeZone")
                }
                calendar.timeZone = timeZone
            } else {
                calendar.timeZone = .autoupdatingCurrent
            }
            reminder.dueDateComponents = calendar.dateComponents(
                [.calendar, .timeZone, .era, .year, .month, .day, .hour, .minute, .second, .nanosecond],
                from: dueDate
            )
        }
        do { try store.save(reminder: reminder, commit: true) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .reminders,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
        let identifier = reminder.calendarItemIdentifier
        guard !identifier.isEmpty else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.reminders)
        }
        return AppleExternalReference(
            identifier: identifier,
            createdAt: now(),
            snapshot: try Self.snapshotData(for: reminder)
        )
    }

    func removeIfUnchanged(identifier: String, expectedSnapshot: Data?) async throws -> Bool {
        let initialState = authorizationState()
        if initialState == .notDetermined {
            do {
                let granted: Bool
                if #available(iOS 17.0, *) {
                    granted = try await store.requestFullReminderAccess()
                } else {
                    granted = try await store.requestLegacyAccess(to: .reminder)
                }
                guard granted else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.reminders)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .reminders,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if initialState == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.reminders)
        } else if initialState == .restricted {
            throw AppleSystemActionAdapterError.authorizationRestricted(.reminders)
        }
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.reminders)
        }
        guard let expectedSnapshot,
              try Self.snapshotData(for: reminder) == expectedSnapshot else {
            return false
        }
        do { try store.remove(reminder: reminder, commit: true) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .reminders,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
        return true
    }

    func contains(identifier: String) -> Bool {
        store.calendarItem(withIdentifier: identifier) is EKReminder
    }

    private struct Snapshot: Codable {
        let title: String?
        let notes: String?
        let priority: Int
        let calendarIdentifier: String?
        let due: DueSnapshot?
    }

    private struct DueSnapshot: Codable {
        let calendarIdentifier: String?
        let timeZoneIdentifier: String?
        let era: Int?
        let year: Int?
        let month: Int?
        let day: Int?
        let hour: Int?
        let minute: Int?
        let second: Int?
        let nanosecond: Int?
    }

    private static func snapshotData(for reminder: EKReminder) throws -> Data {
        let due = reminder.dueDateComponents.map { components in
            DueSnapshot(
                calendarIdentifier: components.calendar?.identifier.debugDescription,
                timeZoneIdentifier: components.timeZone?.identifier,
                era: components.era,
                year: components.year,
                month: components.month,
                day: components.day,
                hour: components.hour,
                minute: components.minute,
                second: components.second,
                nanosecond: components.nanosecond
            )
        }
        let snapshot = Snapshot(
            title: reminder.title,
            notes: reminder.notes,
            priority: reminder.priority,
            calendarIdentifier: reminder.calendar?.calendarIdentifier,
            due: due
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}
