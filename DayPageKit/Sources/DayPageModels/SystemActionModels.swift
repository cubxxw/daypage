import CryptoKit
import Foundation

public extension String {
    /// Returns the longest scalar-safe prefix whose UTF-8 representation fits
    /// the contract byte limit. This never splits a Unicode scalar or leaves
    /// an invalid UTF-8 sequence at App Intent/deep-link boundaries.
    func systemActionPrefixUTF8Bytes(_ limit: Int) -> String {
        guard limit > 0 else { return "" }
        var result = ""
        result.reserveCapacity(Swift.min(utf8.count, limit))
        for scalar in unicodeScalars {
            let value = String(scalar)
            guard result.utf8.count + value.utf8.count <= limit else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

// MARK: - Canonical encoding

/// Canonical encoder used by the system-action trust boundary.
///
/// Keys are sorted, dates are integer milliseconds since 1970, and `/` is not
/// escaped. The format is versioned by `SystemActionProposal.schemaVersion`;
/// changing these rules therefore requires a new proposal schema version.
public enum SystemActionCanonicalJSON {
    public static let maximumPayloadBytes = 32 * 1_024
    public static let coordinateScale: Double = 1_000_000

    /// Frozen v1 timestamp spelling used inside hash-bound cloud payloads.
    /// Accepting multiple ISO-8601 spellings would let equal instants hash to
    /// different bytes in Swift and JavaScript.
    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date.systemActionMillisecondPrecision)
    }

    public static func date(fromCanonicalTimestamp value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        guard let date = formatter.date(from: value), timestamp(date) == value else { return nil }
        return date
    }

    public static func data<Value: Encodable>(for value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded())
            try container.encode(milliseconds)
        }
        return try encoder.encode(value)
    }

    /// Contract-v1 canonical bytes for JSON values. Executable v1 payloads use
    /// only integers plus coordinates on a six-decimal grid. Serializing that
    /// grid explicitly avoids Foundation (`1e-06`), JavaScript (`0.000001`),
    /// and PostgreSQL numeric spelling differences at the approval boundary.
    public static func data(for value: SystemActionJSONValue) throws -> Data {
        Data(try canonicalString(for: value).utf8)
    }

    public static func isCanonicalCoordinate(_ value: Double) -> Bool {
        guard value.isFinite else { return false }
        let scaled = value * coordinateScale
        return scaled.isFinite
            && abs(scaled) <= Double(Int64.max)
            && abs(scaled - scaled.rounded()) <= 0.000_000_1
    }

    private static func canonicalString(for value: SystemActionJSONValue) throws -> String {
        switch value {
        case .object(let object):
            return try "{" + object.keys.sorted().map { key in
                try canonicalJSONString(key) + ":" + canonicalString(for: object[key]!)
            }.joined(separator: ",") + "}"
        case .array(let values):
            return try "[" + values.map(canonicalString).joined(separator: ",") + "]"
        case .string(let value):
            return try canonicalJSONString(value)
        case .integer(let value):
            return String(value)
        case .number(let value):
            guard isCanonicalCoordinate(value) else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: [], debugDescription: "Contract-v1 numbers require at most six decimal places")
                )
            }
            let scaled = Int64((value * coordinateScale).rounded())
            guard scaled != 0 else { return "0" }
            let sign = scaled < 0 ? "-" : ""
            let magnitude = scaled.magnitude
            let whole = magnitude / 1_000_000
            let remainder = magnitude % 1_000_000
            guard remainder != 0 else { return sign + String(whole) }
            let fraction = String(format: "%06llu", remainder)
                .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            return sign + String(whole) + "." + fraction
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    private static func canonicalJSONString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func sha256<Value: Encodable>(of value: Value) throws -> String {
        SHA256.hash(data: try data(for: value))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Forward-compatible JSON

/// A bounded, Sendable JSON value used only to preserve fields from a future
/// action kind. Unknown actions remain reviewable and syncable, but Kit never
/// treats them as executable.
public enum SystemActionJSONValue: Codable, Equatable, Sendable {
    case object([String: SystemActionJSONValue])
    case array([SystemActionJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case boolean(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "System action JSON numbers must be finite"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SystemActionJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SystemActionJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported system action JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    .init(codingPath: encoder.codingPath, debugDescription: "Number must be finite")
                )
            }
            try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Stable enums

public enum SystemActionKind: Hashable, Sendable {
    case calendarEvent
    case reminder
    case contactDraft
    case notification
    case route
    case capture
    case focusSession
    case moment
    case localContextAttachment
    case unsupported(String)

    public var rawValue: String {
        switch self {
        case .calendarEvent: return "calendar_event"
        case .reminder: return "reminder"
        case .contactDraft: return "contact_draft"
        case .notification: return "notification"
        case .route: return "route"
        case .capture: return "capture"
        case .focusSession: return "focus_session"
        case .moment: return "moment"
        case .localContextAttachment: return "local_context_attachment"
        case .unsupported(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "calendar_event": self = .calendarEvent
        case "reminder": self = .reminder
        case "contact_draft": self = .contactDraft
        case "notification": self = .notification
        case "route": self = .route
        case "capture": self = .capture
        case "focus_session": self = .focusSession
        case "moment": self = .moment
        case "local_context_attachment": self = .localContextAttachment
        default: self = .unsupported(rawValue)
        }
    }

    public var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

extension SystemActionKind: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SystemActionLifecycleState: String, Codable, Sendable {
    case pendingReview = "pending_review"
    case approved
    case rejected
    case executing
    case succeeded
    case failed
    case needsReview = "needs_review"
    case cancelled
    case undoPending = "undo_pending"
    case undone
    case expired
    case unsupported
}

public enum SystemActionExecutionPhase: String, Codable, Sendable {
    case execute
    case undo
}

public enum SystemActionDecisionOutcome: String, Codable, Sendable {
    case approved
    case rejected
    case replacementProposed = "replacement_proposed"
}

public enum SystemActionReceiptOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case ambiguous
    case unsupported
}

public enum SystemActionReceiptExecutionMode: String, Codable, Sendable {
    case onlineLease = "online_lease"
    case offlineOwner = "offline_owner"
}

public enum SystemActionReconciliationState: String, Codable, Sendable {
    case notNeeded = "not_needed"
    case pending
    case reconciled
    case ambiguous
    case needsReview = "needs_review"
}

public enum SystemActionRollbackCapability: String, Codable, Sendable {
    case reversible
    case compensating
    case manual
    case none
}

public enum SystemActionRedactionLevel: String, Codable, Sendable {
    case privateOnLockScreen = "private_on_lock_screen"
    case titleOnly = "title_only"
    case boundedSummary = "bounded_summary"
}

public enum SystemActionCreatorSource: String, Codable, Sendable {
    case user
    case localAgent = "local_agent"
    case cloudMCP = "cloud_mcp"
    case systemEntry = "system_entry"
}

public enum SystemActionSourceKind: String, Codable, Sendable {
    case memo
    case dailyPage = "daily_page"
    case entity
    case place
    case shareInbox = "share_inbox"
    case systemEntry = "system_entry"
}

public enum SystemActionDisclosureLevel: String, Codable, Sendable {
    case disabled
    case privateDeviceOnly = "private_device_only"
    case redactedSync = "redacted_sync"
    case fullProposal = "full_proposal"
}

public enum SystemActionCapability: Hashable, Sendable {
    case calendar, reminders, contacts, notifications, location, routes
    case photos, capture, focus, spotlight, healthContext, weatherContext
    case unsupported(String)

    public var rawValue: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "reminders"
        case .contacts: return "contacts"
        case .notifications: return "notifications"
        case .location: return "location"
        case .routes: return "routes"
        case .photos: return "photos"
        case .capture: return "capture"
        case .focus: return "focus"
        case .spotlight: return "spotlight"
        case .healthContext: return "health_context"
        case .weatherContext: return "weather_context"
        case .unsupported(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "calendar": self = .calendar
        case "reminders": self = .reminders
        case "contacts": self = .contacts
        case "notifications": self = .notifications
        case "location": self = .location
        case "routes": self = .routes
        case "photos": self = .photos
        case "capture": self = .capture
        case "focus": self = .focus
        case "spotlight": self = .spotlight
        case "health_context": self = .healthContext
        case "weather_context": self = .weatherContext
        default: self = .unsupported(rawValue)
        }
    }

    public init(actionKind: SystemActionKind) {
        switch actionKind {
        case .calendarEvent: self = .calendar
        case .reminder: self = .reminders
        case .contactDraft: self = .contacts
        case .notification: self = .notifications
        case .route: self = .routes
        case .capture: self = .capture
        case .focusSession: self = .focus
        case .moment: self = .location
        // The top-level kind is insufficient: local context can be backed by
        // WeatherKit, HealthKit, location, Photos, or Contacts. Callers that
        // have a payload must use `payload.requiredCapabilities`.
        case .localContextAttachment: self = .unsupported(actionKind.rawValue)
        case .unsupported(let value): self = .unsupported(value)
        }
    }
}

extension SystemActionCapability: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SystemActionAuthorizationState: Hashable, Sendable {
    case notApplicable
    case notDetermined
    case denied
    case restricted
    case limited
    case writeOnly
    case full
    case unsupported(String)

    public var rawValue: String {
        switch self {
        case .notApplicable: return "not_applicable"
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .limited: return "limited"
        case .writeOnly: return "write_only"
        case .full: return "full"
        case .unsupported(let value): return value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "not_applicable": self = .notApplicable
        case "not_determined": self = .notDetermined
        case "denied": self = .denied
        case "restricted": self = .restricted
        case "limited": self = .limited
        case "write_only": self = .writeOnly
        case "full": self = .full
        default: self = .unsupported(rawValue)
        }
    }
}

extension SystemActionAuthorizationState: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SystemActionAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case requiresPermission = "requires_permission"
    case unsupported
}

// MARK: - Payload DTOs

public struct SystemActionLocation: Codable, Equatable, Sendable {
    public let label: String?
    public let latitude: Double?
    public let longitude: Double?
    public let address: String?

    public init(label: String? = nil, latitude: Double? = nil, longitude: Double? = nil, address: String? = nil) {
        self.label = label
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }
}

public struct SystemActionCalendarEventPayload: Codable, Equatable, Sendable {
    public let title: String
    public let notes: String?
    public let startAt: Date
    public let endAt: Date
    public let isAllDay: Bool
    public let timeZoneIdentifier: String?
    public let location: SystemActionLocation?
    public let calendarHint: String?

    public init(
        title: String,
        notes: String? = nil,
        startAt: Date,
        endAt: Date,
        isAllDay: Bool = false,
        timeZoneIdentifier: String? = nil,
        location: SystemActionLocation? = nil,
        calendarHint: String? = nil
    ) {
        self.title = title
        self.notes = notes
        self.startAt = startAt.systemActionMillisecondPrecision
        self.endAt = endAt.systemActionMillisecondPrecision
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier ?? TimeZone.current.identifier
        self.location = location
        self.calendarHint = calendarHint
    }
}

public struct SystemActionReminderPayload: Codable, Equatable, Sendable {
    public let title: String
    public let notes: String?
    public let dueAt: Date?
    public let timeZoneIdentifier: String?
    public let listHint: String?
    public let priority: Int?

    public init(
        title: String,
        notes: String? = nil,
        dueAt: Date? = nil,
        timeZoneIdentifier: String? = nil,
        listHint: String? = nil,
        priority: Int? = nil
    ) {
        self.title = title
        self.notes = notes
        self.dueAt = dueAt?.systemActionMillisecondPrecision
        self.timeZoneIdentifier = dueAt == nil
            ? timeZoneIdentifier
            : (timeZoneIdentifier ?? TimeZone.current.identifier)
        self.listHint = listHint
        // EventKit defines zero as "no priority". Normalize the two spellings
        // so local equality and the v1 wire representation cannot diverge.
        self.priority = priority == 0 ? nil : priority
    }
}

public struct SystemActionContactField: Codable, Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct SystemActionContactDraftPayload: Codable, Equatable, Sendable {
    public let givenName: String
    public let familyName: String
    public let organization: String?
    public let phoneNumbers: [SystemActionContactField]
    public let emailAddresses: [SystemActionContactField]

    public init(
        givenName: String,
        familyName: String,
        organization: String? = nil,
        phoneNumbers: [SystemActionContactField] = [],
        emailAddresses: [SystemActionContactField] = []
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        // Contract v1 intentionally carries values but not custom Contacts
        // labels. Fixed labels keep every externally written field inside the
        // approved payload hash instead of executing unsynchronized UI text.
        self.phoneNumbers = phoneNumbers.map { .init(label: "phone", value: $0.value) }
        self.emailAddresses = emailAddresses.map { .init(label: "email", value: $0.value) }
    }
}

public enum SystemActionNotificationInterruption: String, Codable, Sendable {
    case passive
    case active
    case timeSensitive = "time_sensitive"
}

public struct SystemActionNotificationPayload: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let fireAt: Date
    public let timeZoneIdentifier: String?
    public let threadIdentifier: String?
    public let interruption: SystemActionNotificationInterruption
    public let playsSound: Bool

    public init(
        title: String,
        body: String,
        fireAt: Date,
        timeZoneIdentifier: String? = nil,
        threadIdentifier: String? = nil,
        interruption: SystemActionNotificationInterruption = .active,
        playsSound: Bool = true
    ) {
        self.title = title
        self.body = body
        self.fireAt = fireAt.systemActionMillisecondPrecision
        self.timeZoneIdentifier = timeZoneIdentifier ?? TimeZone.current.identifier
        self.threadIdentifier = threadIdentifier
        self.interruption = interruption
        self.playsSound = playsSound
    }
}

public enum SystemActionRouteMode: String, Codable, Sendable {
    case any
    case driving
    case walking
    case transit
    case cycling
}

public struct SystemActionRoutePayload: Codable, Equatable, Sendable {
    public let destination: SystemActionLocation
    public let mode: SystemActionRouteMode
    public let opensImmediately: Bool

    public init(destination: SystemActionLocation, mode: SystemActionRouteMode = .driving, opensImmediately: Bool = true) {
        self.destination = destination
        self.mode = mode
        self.opensImmediately = opensImmediately
    }
}

public enum SystemActionCaptureKind: String, Codable, Sendable {
    case text
    case photo
    case camera
    case document
    case textScan = "text_scan"
    case ink
    case file
    case voice
}

public struct SystemActionCapturePayload: Codable, Equatable, Sendable {
    public let captureKind: SystemActionCaptureKind
    public let suggestedTitle: String?
    public let attachesToSource: Bool

    public init(captureKind: SystemActionCaptureKind, suggestedTitle: String? = nil, attachesToSource: Bool = true) {
        self.captureKind = captureKind
        self.suggestedTitle = suggestedTitle
        self.attachesToSource = attachesToSource
    }
}

public struct SystemActionFocusSessionPayload: Codable, Equatable, Sendable {
    public let title: String
    public let durationSeconds: Int
    public let schedulesEndAlert: Bool
    public let allowsLiveActivity: Bool

    public init(
        title: String,
        durationSeconds: Int,
        schedulesEndAlert: Bool = true,
        allowsLiveActivity: Bool = true
    ) {
        self.title = title
        self.durationSeconds = durationSeconds
        self.schedulesEndAlert = schedulesEndAlert
        self.allowsLiveActivity = allowsLiveActivity
    }
}

public struct SystemActionMomentPayload: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let title: String?
    public let location: SystemActionLocation?
    public let selectedContactReferenceHashes: [String]

    public init(
        occurredAt: Date,
        title: String? = nil,
        location: SystemActionLocation? = nil,
        selectedContactReferenceHashes: [String] = []
    ) {
        self.occurredAt = occurredAt.systemActionMillisecondPrecision
        self.title = title
        self.location = location
        self.selectedContactReferenceHashes = selectedContactReferenceHashes
    }
}

public enum SystemActionLocalContextKind: String, Codable, Sendable {
    case weatherSummary = "weather_summary"
    case healthSummary = "health_summary"
    case placeSummary = "place_summary"
    case photo
    case contactSelection = "contact_selection"
}

public struct SystemActionLocalContextAttachmentPayload: Codable, Equatable, Sendable {
    public let contextKind: SystemActionLocalContextKind
    public let summaryCode: String
    public let observedAt: Date

    public init(contextKind: SystemActionLocalContextKind, summaryCode: String, observedAt: Date) {
        self.contextKind = contextKind
        self.summaryCode = summaryCode
        self.observedAt = observedAt.systemActionMillisecondPrecision
    }
}

public enum SystemActionPayload: Codable, Equatable, Sendable {
    case calendarEvent(SystemActionCalendarEventPayload)
    case reminder(SystemActionReminderPayload)
    case contactDraft(SystemActionContactDraftPayload)
    case notification(SystemActionNotificationPayload)
    case route(SystemActionRoutePayload)
    case capture(SystemActionCapturePayload)
    case focusSession(SystemActionFocusSessionPayload)
    case moment(SystemActionMomentPayload)
    case localContextAttachment(SystemActionLocalContextAttachmentPayload)
    case unsupported(kind: String, value: SystemActionJSONValue)

    public var kind: SystemActionKind {
        switch self {
        case .calendarEvent: return .calendarEvent
        case .reminder: return .reminder
        case .contactDraft: return .contactDraft
        case .notification: return .notification
        case .route: return .route
        case .capture: return .capture
        case .focusSession: return .focusSession
        case .moment: return .moment
        case .localContextAttachment: return .localContextAttachment
        case .unsupported(let kind, _): return .unsupported(kind)
        }
    }

    /// Product capabilities that must remain offered for this payload to
    /// create or undo an external effect. This is payload-specific because a
    /// local-context attachment may consume WeatherKit, HealthKit, location,
    /// Photos, or Contacts without changing its top-level action kind.
    public var requiredCapabilities: [SystemActionCapability] {
        switch self {
        case .calendarEvent: return [.calendar]
        case .reminder: return [.reminders]
        case .contactDraft: return [.contacts]
        case .notification: return [.notifications]
        case .route: return [.routes]
        case .capture: return [.capture]
        case .focusSession: return [.focus]
        case .moment(let value): return value.location == nil ? [] : [.location]
        case .localContextAttachment(let value):
            switch value.contextKind {
            case .weatherSummary: return [.weatherContext]
            case .healthSummary: return [.healthContext]
            case .placeSummary: return [.location]
            case .photo: return [.photos]
            case .contactSelection: return [.contacts]
            }
        case .unsupported(let kind, _): return [.unsupported(kind)]
        }
    }

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try container.decode(String.self, forKey: .type)
        switch SystemActionKind(rawValue: rawKind) {
        case .calendarEvent: self = .calendarEvent(try container.decode(SystemActionCalendarEventPayload.self, forKey: .value))
        case .reminder: self = .reminder(try container.decode(SystemActionReminderPayload.self, forKey: .value))
        case .contactDraft: self = .contactDraft(try container.decode(SystemActionContactDraftPayload.self, forKey: .value))
        case .notification: self = .notification(try container.decode(SystemActionNotificationPayload.self, forKey: .value))
        case .route: self = .route(try container.decode(SystemActionRoutePayload.self, forKey: .value))
        case .capture: self = .capture(try container.decode(SystemActionCapturePayload.self, forKey: .value))
        case .focusSession: self = .focusSession(try container.decode(SystemActionFocusSessionPayload.self, forKey: .value))
        case .moment: self = .moment(try container.decode(SystemActionMomentPayload.self, forKey: .value))
        case .localContextAttachment:
            self = .localContextAttachment(try container.decode(SystemActionLocalContextAttachmentPayload.self, forKey: .value))
        case .unsupported:
            self = .unsupported(kind: rawKind, value: try container.decode(SystemActionJSONValue.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .calendarEvent(let value): try container.encode(value, forKey: .value)
        case .reminder(let value): try container.encode(value, forKey: .value)
        case .contactDraft(let value): try container.encode(value, forKey: .value)
        case .notification(let value): try container.encode(value, forKey: .value)
        case .route(let value): try container.encode(value, forKey: .value)
        case .capture(let value): try container.encode(value, forKey: .value)
        case .focusSession(let value): try container.encode(value, forKey: .value)
        case .moment(let value): try container.encode(value, forKey: .value)
        case .localContextAttachment(let value): try container.encode(value, forKey: .value)
        case .unsupported(_, let value): try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - Proposal and immutable evidence

public struct SystemActionSourceReference: Codable, Equatable, Sendable {
    public let kind: SystemActionSourceKind
    public let identifier: String

    public init(kind: SystemActionSourceKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public enum SystemActionTargetDevice: Codable, Equatable, Sendable {
    case creatingDevice
    case anyOwnedOnline
    case specific(String)

    private enum CodingKeys: String, CodingKey { case mode, deviceID }
    private enum Mode: String, Codable { case creatingDevice = "creating_device", anyOwnedOnline = "any_owned_online", specific }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .creatingDevice: self = .creatingDevice
        case .anyOwnedOnline: self = .anyOwnedOnline
        case .specific: self = .specific(try container.decode(String.self, forKey: .deviceID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .creatingDevice: try container.encode(Mode.creatingDevice, forKey: .mode)
        case .anyOwnedOnline: try container.encode(Mode.anyOwnedOnline, forKey: .mode)
        case .specific(let deviceID):
            try container.encode(Mode.specific, forKey: .mode)
            try container.encode(deviceID, forKey: .deviceID)
        }
    }
}

public enum SystemActionValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidRevision
    case invalidField(String)
    case tooManySources
    case payloadTooLarge(Int)
    case payloadHashMismatch
    case kindPayloadMismatch
    case unsupportedActionKind(String)
    case exactBindingMismatch
}

public struct SystemActionProposal: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1
    public static let maximumSourceReferences = 20

    public let id: UUID
    public let schemaVersion: Int
    public let revision: Int64
    public let kind: SystemActionKind
    public let payload: SystemActionPayload
    public let payloadHash: String
    public let title: String
    public let rationale: String
    public let sourceReferences: [SystemActionSourceReference]
    public let creatorSource: SystemActionCreatorSource
    public let creatorDeviceID: String
    public let redactionLevel: SystemActionRedactionLevel
    public let targetDevice: SystemActionTargetDevice
    public let createdAt: Date
    public let expiresAt: Date?
    public let lifecycleState: SystemActionLifecycleState
    public let deletedAt: Date?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = currentSchemaVersion,
        revision: Int64 = 1,
        payload: SystemActionPayload,
        payloadHash: String? = nil,
        title: String,
        rationale: String,
        sourceReferences: [SystemActionSourceReference] = [],
        creatorSource: SystemActionCreatorSource,
        creatorDeviceID: String,
        redactionLevel: SystemActionRedactionLevel = .privateOnLockScreen,
        targetDevice: SystemActionTargetDevice = .creatingDevice,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        lifecycleState: SystemActionLifecycleState = .pendingReview,
        deletedAt: Date? = nil
    ) throws {
        let canonical = try SystemActionCanonicalJSON.data(for: payload.canonicalCloudValue())
        let calculatedHash = SystemActionCanonicalJSON.sha256(of: canonical)
        if let payloadHash, payloadHash != calculatedHash {
            throw SystemActionValidationError.payloadHashMismatch
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.kind = payload.kind
        self.payload = payload
        self.payloadHash = calculatedHash
        self.title = title
        self.rationale = rationale
        self.sourceReferences = sourceReferences
        self.creatorSource = creatorSource
        self.creatorDeviceID = creatorDeviceID
        self.redactionLevel = redactionLevel
        self.targetDevice = targetDevice
        self.createdAt = createdAt.systemActionMillisecondPrecision
        self.expiresAt = expiresAt?.systemActionMillisecondPrecision
        self.lifecycleState = lifecycleState
        self.deletedAt = deletedAt?.systemActionMillisecondPrecision
        try validate(canonicalPayload: canonical)
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, revision, kind, payload, payloadHash, title, rationale
        case sourceReferences, creatorSource, creatorDeviceID, redactionLevel, targetDevice
        case createdAt, expiresAt, lifecycleState
        case deletedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKind = try container.decode(SystemActionKind.self, forKey: .kind)
        let decodedPayload = try container.decode(SystemActionPayload.self, forKey: .payload)
        guard decodedKind == decodedPayload.kind else { throw SystemActionValidationError.kindPayloadMismatch }
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            revision: container.decode(Int64.self, forKey: .revision),
            payload: decodedPayload,
            payloadHash: container.decode(String.self, forKey: .payloadHash),
            title: container.decode(String.self, forKey: .title),
            rationale: container.decode(String.self, forKey: .rationale),
            sourceReferences: container.decode([SystemActionSourceReference].self, forKey: .sourceReferences),
            creatorSource: container.decode(SystemActionCreatorSource.self, forKey: .creatorSource),
            creatorDeviceID: container.decode(String.self, forKey: .creatorDeviceID),
            redactionLevel: container.decode(SystemActionRedactionLevel.self, forKey: .redactionLevel),
            targetDevice: container.decode(SystemActionTargetDevice.self, forKey: .targetDevice),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            expiresAt: container.decodeIfPresent(Date.self, forKey: .expiresAt),
            lifecycleState: container.decode(SystemActionLifecycleState.self, forKey: .lifecycleState),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(kind, forKey: .kind)
        try container.encode(payload, forKey: .payload)
        try container.encode(payloadHash, forKey: .payloadHash)
        try container.encode(title, forKey: .title)
        try container.encode(rationale, forKey: .rationale)
        try container.encode(sourceReferences, forKey: .sourceReferences)
        try container.encode(creatorSource, forKey: .creatorSource)
        try container.encode(creatorDeviceID, forKey: .creatorDeviceID)
        try container.encode(redactionLevel, forKey: .redactionLevel)
        try container.encode(targetDevice, forKey: .targetDevice)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encode(lifecycleState, forKey: .lifecycleState)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
    }

    public func revised(
        payload: SystemActionPayload,
        title: String,
        rationale: String,
        expiresAt: Date? = nil,
        now _: Date = Date()
    ) throws -> SystemActionProposal {
        try SystemActionProposal(
            id: id,
            schemaVersion: schemaVersion,
            revision: revision + 1,
            payload: payload,
            title: title,
            rationale: rationale,
            sourceReferences: sourceReferences,
            creatorSource: creatorSource,
            creatorDeviceID: creatorDeviceID,
            redactionLevel: redactionLevel,
            targetDevice: targetDevice,
            // `created_at` identifies the proposal aggregate and is immutable
            // across revisions in the remote contract. A replacement gets a
            // new revision/hash, but it is not a newly-created proposal.
            createdAt: createdAt,
            expiresAt: expiresAt,
            lifecycleState: .pendingReview,
            deletedAt: nil
        )
    }

    public func withLifecycleState(_ state: SystemActionLifecycleState) throws -> SystemActionProposal {
        try SystemActionProposal(
            id: id,
            schemaVersion: schemaVersion,
            revision: revision,
            payload: payload,
            payloadHash: payloadHash,
            title: title,
            rationale: rationale,
            sourceReferences: sourceReferences,
            creatorSource: creatorSource,
            creatorDeviceID: creatorDeviceID,
            redactionLevel: redactionLevel,
            targetDevice: targetDevice,
            createdAt: createdAt,
            expiresAt: expiresAt,
            lifecycleState: state,
            deletedAt: deletedAt
        )
    }

    public func isExpired(at date: Date) -> Bool {
        deletedAt != nil || (expiresAt.map { $0 <= date } ?? false)
    }

    private func validate(canonicalPayload: Data) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SystemActionValidationError.unsupportedSchema(schemaVersion)
        }
        guard revision > 0 else { throw SystemActionValidationError.invalidRevision }
        guard canonicalPayload.count <= SystemActionCanonicalJSON.maximumPayloadBytes else {
            throw SystemActionValidationError.payloadTooLarge(canonicalPayload.count)
        }
        guard title.utf8.count <= 160,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SystemActionValidationError.invalidField("title")
        }
        guard rationale.utf8.count <= 500 else { throw SystemActionValidationError.invalidField("rationale") }
        guard !creatorDeviceID.isEmpty, creatorDeviceID.utf8.count <= 128 else {
            throw SystemActionValidationError.invalidField("creator_device_id")
        }
        if case .specific(let deviceID) = targetDevice,
           deviceID.isEmpty || deviceID.utf8.count > 128 {
            throw SystemActionValidationError.invalidField("target_device_id")
        }
        guard sourceReferences.count <= Self.maximumSourceReferences else {
            throw SystemActionValidationError.tooManySources
        }
        var uniqueSourceReferences = Set<String>()
        for source in sourceReferences where source.identifier.isEmpty || source.identifier.utf8.count > 160 {
            throw SystemActionValidationError.invalidField("source_reference")
        }
        for source in sourceReferences {
            guard uniqueSourceReferences.insert("\(source.kind.rawValue)\u{0}\(source.identifier)").inserted else {
                throw SystemActionValidationError.invalidField("source_reference_duplicate")
            }
        }
        try payload.validate()
    }
}

public struct SystemActionDecision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let schemaVersion: Int
    public let proposalID: UUID
    public let phase: SystemActionExecutionPhase
    public let proposalRevision: Int64
    public let payloadHash: String
    public let outcome: SystemActionDecisionOutcome
    public let decidedAt: Date
    public let deviceID: String
    public let replacementProposalID: UUID?
    public let replacementProposal: SystemActionProposal?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = SystemActionProposal.currentSchemaVersion,
        proposalID: UUID,
        phase: SystemActionExecutionPhase = .execute,
        proposalRevision: Int64,
        payloadHash: String,
        outcome: SystemActionDecisionOutcome,
        decidedAt: Date = Date(),
        deviceID: String,
        replacementProposalID: UUID? = nil,
        replacementProposal: SystemActionProposal? = nil
    ) throws {
        guard schemaVersion == SystemActionProposal.currentSchemaVersion else {
            throw SystemActionValidationError.unsupportedSchema(schemaVersion)
        }
        guard proposalRevision > 0,
              payloadHash.isSystemActionSHA256,
              !deviceID.isEmpty,
              deviceID.utf8.count <= 128 else {
            throw SystemActionValidationError.invalidField("decision_binding")
        }
        let resolvedReplacementID = replacementProposal?.id ?? replacementProposalID
        if outcome == .replacementProposed {
            guard resolvedReplacementID == proposalID,
                  replacementProposal == nil || (replacementProposal?.revision ?? 0) > proposalRevision else {
                throw SystemActionValidationError.exactBindingMismatch
            }
        } else if resolvedReplacementID != nil {
            throw SystemActionValidationError.invalidField("replacement_proposal")
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.proposalID = proposalID
        self.phase = phase
        self.proposalRevision = proposalRevision
        self.payloadHash = payloadHash
        self.outcome = outcome
        self.decidedAt = decidedAt.systemActionMillisecondPrecision
        self.deviceID = deviceID
        self.replacementProposalID = resolvedReplacementID
        self.replacementProposal = replacementProposal
    }
}

public struct SystemActionBoundedResult: Codable, Equatable, Sendable {
    public let summaryCode: String
    public let externalIdentifierHash: String?
    public let metadata: [String: String]

    public init(summaryCode: String, externalIdentifierHash: String? = nil, metadata: [String: String] = [:]) {
        self.summaryCode = summaryCode
        self.externalIdentifierHash = externalIdentifierHash
        self.metadata = metadata
    }
}

public struct SystemActionReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let schemaVersion: Int
    public let operationID: UUID
    public let proposalID: UUID
    public let phase: SystemActionExecutionPhase
    public let proposalRevision: Int64
    public let payloadHash: String
    public let attempt: Int
    public let outcome: SystemActionReceiptOutcome
    public let deviceID: String
    public let executionMode: SystemActionReceiptExecutionMode
    public let leaseID: UUID?
    public let boundedResult: SystemActionBoundedResult?
    public let errorCode: String?
    public let reconciliationState: SystemActionReconciliationState
    public let rollbackCapability: SystemActionRollbackCapability
    public let startedAt: Date
    public let completedAt: Date

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = SystemActionProposal.currentSchemaVersion,
        operationID: UUID,
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        proposalRevision: Int64,
        payloadHash: String,
        attempt: Int,
        outcome: SystemActionReceiptOutcome,
        deviceID: String,
        executionMode: SystemActionReceiptExecutionMode = .offlineOwner,
        leaseID: UUID? = nil,
        boundedResult: SystemActionBoundedResult? = nil,
        errorCode: String? = nil,
        reconciliationState: SystemActionReconciliationState,
        rollbackCapability: SystemActionRollbackCapability,
        startedAt: Date,
        completedAt: Date = Date()
    ) throws {
        guard schemaVersion == SystemActionProposal.currentSchemaVersion else {
            throw SystemActionValidationError.unsupportedSchema(schemaVersion)
        }
        guard proposalRevision > 0, payloadHash.isSystemActionSHA256, attempt > 0 else {
            throw SystemActionValidationError.invalidField("receipt_binding")
        }
        guard !deviceID.isEmpty, deviceID.utf8.count <= 128 else {
            throw SystemActionValidationError.invalidField("device_id")
        }
        guard completedAt >= startedAt else { throw SystemActionValidationError.invalidField("completed_at") }
        if let errorCode, !errorCode.isSystemActionErrorCode {
            throw SystemActionValidationError.invalidField("error_code")
        }
        if outcome == .succeeded, errorCode != nil {
            throw SystemActionValidationError.invalidField("successful_receipt_error_code")
        }
        guard (executionMode == .onlineLease && leaseID != nil)
                || (executionMode == .offlineOwner && leaseID == nil) else {
            throw SystemActionValidationError.invalidField("receipt_execution_mode")
        }
        if let result = boundedResult {
            guard !result.summaryCode.isEmpty, result.summaryCode.utf8.count <= 96, result.metadata.count <= 12 else {
                throw SystemActionValidationError.invalidField("bounded_result")
            }
            if let hash = result.externalIdentifierHash, !hash.isSystemActionSHA256 {
                throw SystemActionValidationError.invalidField("external_identifier_hash")
            }
            for (key, value) in result.metadata where key.utf8.count > 64 || value.utf8.count > 256 {
                throw SystemActionValidationError.invalidField("bounded_result_metadata")
            }
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.operationID = operationID
        self.proposalID = proposalID
        self.phase = phase
        self.proposalRevision = proposalRevision
        self.payloadHash = payloadHash
        self.attempt = attempt
        self.outcome = outcome
        self.deviceID = deviceID
        self.executionMode = executionMode
        self.leaseID = leaseID
        self.boundedResult = boundedResult
        self.errorCode = errorCode
        self.reconciliationState = reconciliationState
        self.rollbackCapability = rollbackCapability
        self.startedAt = startedAt.systemActionMillisecondPrecision
        self.completedAt = completedAt.systemActionMillisecondPrecision
    }
}

// MARK: - Capability, lease, and device-local material

public struct SystemActionCapabilityPolicy: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let schemaVersion: Int
    public let revision: Int64
    public let capability: SystemActionCapability
    public let isOffered: Bool
    public let isSynchronized: Bool
    public let disclosureLevel: SystemActionDisclosureLevel
    public let updatedAt: Date
    public let deletedAt: Date?

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = SystemActionProposal.currentSchemaVersion,
        revision: Int64 = 1,
        capability: SystemActionCapability,
        isOffered: Bool,
        isSynchronized: Bool,
        disclosureLevel: SystemActionDisclosureLevel,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) throws {
        guard schemaVersion == SystemActionProposal.currentSchemaVersion else {
            throw SystemActionValidationError.unsupportedSchema(schemaVersion)
        }
        guard revision > 0 else { throw SystemActionValidationError.invalidRevision }
        let validDisclosure: Bool
        if !isOffered {
            validDisclosure = !isSynchronized && disclosureLevel == .disabled
        } else if isSynchronized {
            validDisclosure = disclosureLevel == .redactedSync || disclosureLevel == .fullProposal
        } else {
            validDisclosure = disclosureLevel == .privateDeviceOnly
        }
        guard validDisclosure else {
            throw SystemActionValidationError.invalidField("capability_policy_disclosure")
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.capability = capability
        self.isOffered = isOffered
        self.isSynchronized = isSynchronized
        self.disclosureLevel = disclosureLevel
        self.updatedAt = updatedAt.systemActionMillisecondPrecision
        self.deletedAt = deletedAt?.systemActionMillisecondPrecision
    }

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = SystemActionProposal.currentSchemaVersion,
        revision: Int64 = 1,
        kind: SystemActionKind,
        isOffered: Bool,
        isSynchronized: Bool,
        disclosureLevel: SystemActionDisclosureLevel,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) throws {
        try self.init(
            id: id,
            schemaVersion: schemaVersion,
            revision: revision,
            capability: SystemActionCapability(actionKind: kind),
            isOffered: isOffered,
            isSynchronized: isSynchronized,
            disclosureLevel: disclosureLevel,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

public struct SystemActionCapabilitySnapshot: Codable, Equatable, Sendable {
    public let kind: SystemActionKind
    public let availability: SystemActionAvailability
    public let authorization: SystemActionAuthorizationState
    public let reasonCode: String?
    public let observedAt: Date

    public init(
        kind: SystemActionKind,
        availability: SystemActionAvailability,
        authorization: SystemActionAuthorizationState,
        reasonCode: String? = nil,
        observedAt: Date = Date()
    ) {
        self.kind = kind
        self.availability = availability
        self.authorization = authorization
        self.reasonCode = reasonCode
        self.observedAt = observedAt
    }
}

public struct SystemActionExecutionLease: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let proposalID: UUID
    public let phase: SystemActionExecutionPhase
    public let proposalRevision: Int64
    public let payloadHash: String
    public let deviceID: String
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        id: UUID,
        proposalID: UUID,
        phase: SystemActionExecutionPhase,
        proposalRevision: Int64,
        payloadHash: String,
        deviceID: String,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.proposalID = proposalID
        self.phase = phase
        self.proposalRevision = proposalRevision
        self.payloadHash = payloadHash
        self.deviceID = deviceID
        self.issuedAt = issuedAt.systemActionMillisecondPrecision
        self.expiresAt = expiresAt.systemActionMillisecondPrecision
    }

    public func exactlyMatches(
        proposal: SystemActionProposal,
        phase: SystemActionExecutionPhase,
        deviceID: String
    ) -> Bool {
        proposalID == proposal.id
            && self.phase == phase
            && proposalRevision == proposal.revision
            && payloadHash == proposal.payloadHash
            && self.deviceID == deviceID
            && expiresAt > issuedAt
    }
}

/// Never included in a cloud receipt. Adapters may persist an external system
/// identifier and an opaque, bounded before-snapshot here for device-only undo.
public struct SystemActionLocalMaterial: Codable, Equatable, Sendable {
    public let externalIdentifier: String?
    public let beforeSnapshot: Data?
    public let metadata: [String: String]

    public init(externalIdentifier: String? = nil, beforeSnapshot: Data? = nil, metadata: [String: String] = [:]) {
        self.externalIdentifier = externalIdentifier
        self.beforeSnapshot = beforeSnapshot
        self.metadata = metadata
    }
}

public struct SystemActionExecutionContext: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let phase: SystemActionExecutionPhase
    public let attempt: Int
    public let deviceID: String
    public let startedAt: Date
    public let lease: SystemActionExecutionLease?

    public init(
        operationID: UUID,
        phase: SystemActionExecutionPhase,
        attempt: Int,
        deviceID: String,
        startedAt: Date,
        lease: SystemActionExecutionLease?
    ) {
        self.operationID = operationID
        self.phase = phase
        self.attempt = attempt
        self.deviceID = deviceID
        self.startedAt = startedAt
        self.lease = lease
    }
}

public struct SystemActionAdapterResult: Codable, Equatable, Sendable {
    public let outcome: SystemActionReceiptOutcome
    public let boundedResult: SystemActionBoundedResult?
    public let localMaterial: SystemActionLocalMaterial?
    public let errorCode: String?
    public let reconciliationState: SystemActionReconciliationState

    public init(
        outcome: SystemActionReceiptOutcome,
        boundedResult: SystemActionBoundedResult? = nil,
        localMaterial: SystemActionLocalMaterial? = nil,
        errorCode: String? = nil,
        reconciliationState: SystemActionReconciliationState = .notNeeded
    ) {
        self.outcome = outcome
        self.boundedResult = boundedResult
        self.localMaterial = localMaterial
        self.errorCode = errorCode
        self.reconciliationState = reconciliationState
    }
}

public enum SystemActionReconciliationDisposition: String, Codable, Sendable {
    case confirmed
    case safeToRetry = "safe_to_retry"
    case ambiguous
    case needsReview = "needs_review"
}

public struct SystemActionReconciliationResult: Codable, Equatable, Sendable {
    public let disposition: SystemActionReconciliationDisposition
    public let confirmedResult: SystemActionAdapterResult?
    public let errorCode: String?

    public init(
        disposition: SystemActionReconciliationDisposition,
        confirmedResult: SystemActionAdapterResult? = nil,
        errorCode: String? = nil
    ) {
        self.disposition = disposition
        self.confirmedResult = confirmedResult
        self.errorCode = errorCode
    }
}

// MARK: - Validation helpers

private extension SystemActionPayload {
    func validate() throws {
        switch self {
        case .calendarEvent(let value):
            try validateText(value.title, field: "calendar.title", maximum: 160, required: true)
            if let notes = value.notes { try validateText(notes, field: "calendar.notes", maximum: 2_000, required: false) }
            if let timeZone = value.timeZoneIdentifier {
                try validateText(timeZone, field: "calendar.time_zone", maximum: 64, required: true)
            }
            guard value.endAt > value.startAt else { throw SystemActionValidationError.invalidField("calendar.interval") }
            try value.location?.validate()
            if let locationText = value.location?.address ?? value.location?.label,
               locationText.utf8.count > 240 {
                throw SystemActionValidationError.invalidField("calendar.location")
            }
            guard value.calendarHint == nil else {
                throw SystemActionValidationError.invalidField("calendar.calendar_hint_v1")
            }
        case .reminder(let value):
            try validateText(value.title, field: "reminder.title", maximum: 160, required: true)
            if let notes = value.notes { try validateText(notes, field: "reminder.notes", maximum: 2_000, required: false) }
            if let timeZone = value.timeZoneIdentifier {
                try validateText(timeZone, field: "reminder.time_zone", maximum: 64, required: true)
            }
            if let priority = value.priority, !(0...9).contains(priority) {
                throw SystemActionValidationError.invalidField("reminder.priority")
            }
            guard value.listHint == nil else {
                throw SystemActionValidationError.invalidField("reminder.list_hint_v1")
            }
        case .contactDraft(let value):
            let hasName = !value.givenName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !value.familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !(value.organization ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasName,
                  value.givenName.utf8.count <= 100,
                  value.familyName.utf8.count <= 100,
                  (value.organization?.utf8.count ?? 0) <= 160,
                  value.phoneNumbers.count <= 5,
                  value.emailAddresses.count <= 5 else {
                throw SystemActionValidationError.invalidField("contact")
            }
            for field in value.phoneNumbers {
                guard field.label == "phone" else {
                    throw SystemActionValidationError.invalidField("contact.phone_label")
                }
                try validateText(field.value, field: "contact.phone", maximum: 40, required: true)
            }
            for field in value.emailAddresses {
                guard field.label == "email", field.value.utf8.count >= 3 else {
                    throw SystemActionValidationError.invalidField("contact.email")
                }
                try validateText(field.value, field: "contact.email", maximum: 254, required: true)
            }
        case .notification(let value):
            try validateText(value.title, field: "notification.title", maximum: 160, required: true)
            try validateText(value.body, field: "notification.body", maximum: 500, required: false)
            if let timeZone = value.timeZoneIdentifier {
                try validateText(timeZone, field: "notification.time_zone", maximum: 64, required: true)
            }
            guard value.threadIdentifier == nil, value.playsSound else {
                throw SystemActionValidationError.invalidField("notification.unsupported_v1_option")
            }
        case .route(let value):
            try value.destination.validate()
            let hasCoordinates = value.destination.latitude != nil && value.destination.longitude != nil
            let hasAddress = !(value.destination.address ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasCoordinates != hasAddress, value.opensImmediately else {
                throw SystemActionValidationError.invalidField("route.destination")
            }
        case .capture(let value):
            if let title = value.suggestedTitle { try validateText(title, field: "capture.title", maximum: 200, required: false) }
        case .focusSession(let value):
            try validateText(value.title, field: "focus.title", maximum: 160, required: true)
            guard (60...86_400).contains(value.durationSeconds) else {
                throw SystemActionValidationError.invalidField("focus.duration_seconds")
            }
        case .moment(let value):
            try value.location?.validate()
            if let title = value.title {
                try validateText(title, field: "moment.title", maximum: 160, required: false)
            }
            // Precise coordinates are deliberately absent from the cloud v1
            // proposal. Accepting pre-filled coordinates here would let an
            // executable value escape the exact approval hash. A confirmed
            // moment instead obtains a one-shot location on the owner device.
            guard value.location?.latitude == nil,
                  value.location?.longitude == nil,
                  value.location == nil
                    || !(value.location?.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.selectedContactReferenceHashes.count <= 20,
                  value.selectedContactReferenceHashes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 }) else {
                throw SystemActionValidationError.invalidField("moment.contact_reference_hashes")
            }
        case .localContextAttachment(let value):
            guard UUID(uuidString: value.summaryCode) != nil else {
                throw SystemActionValidationError.invalidField("context.local_reference")
            }
        case .unsupported(let kind, _):
            guard !kind.isEmpty, kind.utf8.count <= 96 else {
                throw SystemActionValidationError.invalidField("unsupported_kind")
            }
        }
    }

    func validateText(_ value: String, field: String, maximum: Int, required: Bool) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if required && trimmed.isEmpty { throw SystemActionValidationError.invalidField(field) }
        if value.utf8.count > maximum { throw SystemActionValidationError.invalidField(field) }
    }
}

public extension SystemActionPayload {
    /// Contract-v1 JSON used for cross-platform hashes and backend records.
    /// Device-only values are represented only by the bounded fields admitted
    /// by the canonical schema; schema-v1 validation rejects executable options
    /// that the contract cannot bind.
    func canonicalCloudValue() throws -> SystemActionJSONValue {
        func timestamp(_ date: Date) -> SystemActionJSONValue {
            .string(SystemActionCanonicalJSON.timestamp(date))
        }
        func optionalString(_ value: String?) -> SystemActionJSONValue {
            value.map(SystemActionJSONValue.string) ?? .null
        }
        func optionalTimestamp(_ value: Date?) -> SystemActionJSONValue {
            value.map(timestamp) ?? .null
        }

        switch self {
        case .calendarEvent(let value):
            return .object([
                "kind": .string(kind.rawValue),
                "title": .string(value.title),
                "start_at": timestamp(value.startAt),
                "end_at": timestamp(value.endAt),
                "all_day": .boolean(value.isAllDay),
                "time_zone": .string(value.timeZoneIdentifier ?? "UTC"),
                "location_label": optionalString(value.location?.address ?? value.location?.label),
                "notes": optionalString(value.notes),
            ])
        case .reminder(let value):
            return .object([
                "kind": .string(kind.rawValue),
                "title": .string(value.title),
                "due_at": optionalTimestamp(value.dueAt),
                "time_zone": optionalString(value.timeZoneIdentifier),
                "priority": .integer(Int64(value.priority ?? 0)),
                "notes": optionalString(value.notes),
            ])
        case .contactDraft(let value):
            return .object([
                "kind": .string(kind.rawValue),
                "given_name": .string(value.givenName),
                "family_name": .string(value.familyName),
                "organization": optionalString(value.organization),
                "phones": .array(value.phoneNumbers.map { .string($0.value) }),
                "emails": .array(value.emailAddresses.map { .string($0.value) }),
            ])
        case .notification(let value):
            return .object([
                "kind": .string(kind.rawValue),
                "title": .string(value.title),
                "body": .string(value.body),
                "fire_at": timestamp(value.fireAt),
                "time_zone": .string(value.timeZoneIdentifier ?? "UTC"),
                "interruption_level": .string(value.interruption.rawValue),
            ])
        case .route(let value):
            let label = value.destination.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            var object: [String: SystemActionJSONValue] = [
                "kind": .string(kind.rawValue),
                "destination_label": .string(
                    label.flatMap { $0.isEmpty ? nil : $0 }
                        ?? value.destination.address
                        ?? "Pinned location"
                ),
                "transport": .string(value.mode.rawValue),
            ]
            if let address = value.destination.address {
                object["destination_address"] = .string(address)
            } else if let latitude = value.destination.latitude,
                      let longitude = value.destination.longitude {
                object["destination_latitude"] = .number(latitude)
                object["destination_longitude"] = .number(longitude)
            } else {
                throw SystemActionValidationError.invalidField("route.destination")
            }
            return .object(object)
        case .capture(let value):
            let mode: String
            switch value.captureKind {
            case .text: mode = "text"
            case .photo: mode = "photo"
            case .camera: mode = "camera"
            case .document: mode = "scan"
            case .textScan: mode = "ocr"
            case .ink: mode = "ink"
            case .file: mode = "file"
            case .voice: mode = "voice"
            }
            return .object([
                "kind": .string(kind.rawValue),
                "mode": .string(mode),
                "destination": .string(value.attachesToSource ? "current_draft" : "new_memo"),
                "suggested_title": optionalString(value.suggestedTitle),
            ])
        case .focusSession(let value):
            return .object([
                "kind": .string(kind.rawValue),
                "title": .string(value.title),
                "duration_seconds": .integer(Int64(value.durationSeconds)),
                "schedule_end_alert": .boolean(value.schedulesEndAlert),
                "allow_live_activity": .boolean(value.allowsLiveActivity),
            ])
        case .moment(let value):
            return .object([
                "kind": .string(kind.rawValue),
                "captured_at": timestamp(value.occurredAt),
                "title": optionalString(value.title),
                "place_label": optionalString(value.location?.label),
                "people_refs": .array(value.selectedContactReferenceHashes.map(SystemActionJSONValue.string)),
                "include_one_shot_location": .boolean(value.location != nil),
            ])
        case .localContextAttachment(let value):
            let contextKind: String
            switch value.contextKind {
            case .weatherSummary: contextKind = "weather_summary"
            case .healthSummary: contextKind = "health_summary"
            case .placeSummary: contextKind = "location_summary"
            case .photo: contextKind = "photo"
            case .contactSelection: contextKind = "contact_selection"
            }
            return .object([
                "kind": .string(kind.rawValue),
                "context_kind": .string(contextKind),
                "local_reference": .string(value.summaryCode),
                "observed_at": timestamp(value.observedAt),
                "disclosure": .string("summary_only"),
            ])
        case .unsupported(let kind, let value):
            guard case .object(var object) = value else {
                return .object(["kind": .string(kind), "value": value])
            }
            object["kind"] = .string(kind)
            return .object(object)
        }
    }
}

private extension SystemActionLocation {
    func validate() throws {
        if let latitude,
           (!latitude.isFinite
            || !(-90...90).contains(latitude)
            || !SystemActionCanonicalJSON.isCanonicalCoordinate(latitude)) {
            throw SystemActionValidationError.invalidField("location.latitude")
        }
        if let longitude,
           (!longitude.isFinite
            || !(-180...180).contains(longitude)
            || !SystemActionCanonicalJSON.isCanonicalCoordinate(longitude)) {
            throw SystemActionValidationError.invalidField("location.longitude")
        }
        guard (latitude == nil) == (longitude == nil) else {
            throw SystemActionValidationError.invalidField("location.coordinates")
        }
        if let label, label.utf8.count > 240 { throw SystemActionValidationError.invalidField("location.label") }
        if let address, address.utf8.count > 500 { throw SystemActionValidationError.invalidField("location.address") }
    }
}

private extension Date {
    var systemActionMillisecondPrecision: Date {
        let milliseconds = (timeIntervalSince1970 * 1_000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

private extension String {
    var isSystemActionSHA256: Bool {
        utf8.count == 64 && utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    var isSystemActionErrorCode: Bool {
        !isEmpty && utf8.count <= 80 && unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 95, 97...122: return true // - . 0-9 _ a-z
            default: return false
            }
        }
    }
}
