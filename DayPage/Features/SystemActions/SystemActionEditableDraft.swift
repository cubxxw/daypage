import Foundation
import DayPageModels

enum SystemActionRouteDestinationMode: String, CaseIterable {
    case address
    case coordinates
}

enum SystemActionDraftValidationError: LocalizedError, Equatable {
    case titleRequired
    case calendarInterval
    case contactFieldLimit(kind: String)
    case contactValueTooLong(kind: String)
    case contactEmailInvalid
    case routeAddressRequired
    case routeAddressTooLong
    case routeCoordinatePairRequired
    case routeCoordinateInvalid
    case routeLabelTooLong
    case calendarLocationTooLong
    case momentPlaceLabelRequired
    case momentPlaceLabelTooLong

    var errorDescription: String? {
        switch self {
        case .titleRequired:
            return NSLocalizedString("system_action.error.title_required", value: "标题不能为空。", comment: "")
        case .calendarInterval:
            return NSLocalizedString("system_action.error.calendar_interval", value: "结束时间必须晚于开始时间。", comment: "")
        case .contactFieldLimit(let kind):
            let format = NSLocalizedString("system_action.error.contact_limit", value: "%@ 最多可填写 5 条。", comment: "")
            return String(format: format, kind)
        case .contactValueTooLong(let kind):
            let format = NSLocalizedString("system_action.error.contact_too_long", value: "%@ 中有一项超过长度限制。", comment: "")
            return String(format: format, kind)
        case .contactEmailInvalid:
            return NSLocalizedString("system_action.error.contact_email", value: "请检查邮箱地址，每行填写一个有效值。", comment: "")
        case .routeAddressRequired:
            return NSLocalizedString("system_action.error.route_address", value: "选择“地址”时必须填写目的地地址。", comment: "")
        case .routeAddressTooLong:
            return NSLocalizedString("system_action.error.route_address_too_long", value: "目的地地址不能超过 500 个字节。", comment: "")
        case .routeCoordinatePairRequired:
            return NSLocalizedString("system_action.error.route_coordinate_pair", value: "选择“坐标”时必须同时填写纬度和经度。", comment: "")
        case .routeCoordinateInvalid:
            return NSLocalizedString("system_action.error.route_coordinate", value: "纬度必须在 -90…90，经度必须在 -180…180。", comment: "")
        case .routeLabelTooLong:
            return NSLocalizedString("system_action.error.route_label", value: "地点名称不能超过 240 个字节。", comment: "")
        case .calendarLocationTooLong:
            return NSLocalizedString("system_action.error.calendar_location", value: "日历地点不能超过 240 个字节。", comment: "")
        case .momentPlaceLabelRequired:
            return NSLocalizedString("system_action.error.moment_place", value: "启用一次性定位时，请填写地点名称。", comment: "")
        case .momentPlaceLabelTooLong:
            return NSLocalizedString("system_action.error.moment_place_too_long", value: "Moment 地点不能超过 240 个字节。", comment: "")
        }
    }
}

/// Mutable review state used by both new proposals and revision editing. It is
/// intentionally an app/UI type; only `SystemActionProposal` crosses into the
/// durable ledger.
struct SystemActionEditableDraft {
    let original: SystemActionProposal

    var title: String
    var rationale: String
    var notes = ""
    var primaryText = ""
    var secondaryText = ""
    var startAt = Date()
    var endAt = Date().addingTimeInterval(3_600)
    var optionalDateEnabled = false
    var optionalDate = Date().addingTimeInterval(900)
    var isAllDay = false
    var boolOption = true
    var secondaryBoolOption = true
    var integerOption = 0
    var mode = ""
    var latitude = ""
    var longitude = ""
    var phoneLines = ""
    var emailLines = ""
    var selectedContactReferenceHashes: [String] = []
    var routeDestinationMode: SystemActionRouteDestinationMode = .address

    init(proposal: SystemActionProposal) {
        self.original = proposal
        self.title = proposal.title
        self.rationale = proposal.rationale

        switch proposal.payload {
        case .calendarEvent(let value):
            notes = value.notes ?? ""
            startAt = value.startAt
            endAt = value.endAt
            isAllDay = value.isAllDay
            // Contract v1 has one bounded `location_label`; precise location
            // fields are neither displayed nor carried through review.
            primaryText = value.location?.address ?? value.location?.label ?? ""
        case .reminder(let value):
            notes = value.notes ?? ""
            optionalDateEnabled = value.dueAt != nil
            optionalDate = value.dueAt ?? Date().addingTimeInterval(900)
            integerOption = value.priority ?? 0
        case .contactDraft(let value):
            primaryText = value.givenName
            secondaryText = value.familyName
            notes = value.organization ?? ""
            phoneLines = Self.lines(value.phoneNumbers)
            emailLines = Self.lines(value.emailAddresses)
        case .notification(let value):
            notes = value.body
            optionalDateEnabled = true
            optionalDate = value.fireAt
            mode = value.interruption.rawValue
        case .route(let value):
            primaryText = value.destination.label ?? ""
            secondaryText = value.destination.address ?? ""
            latitude = Self.decimal(value.destination.latitude)
            longitude = Self.decimal(value.destination.longitude)
            routeDestinationMode = value.destination.latitude != nil ? .coordinates : .address
            mode = value.mode.rawValue
        case .capture(let value):
            mode = value.captureKind.rawValue
            primaryText = value.suggestedTitle ?? ""
            boolOption = value.attachesToSource
        case .focusSession(let value):
            integerOption = max(1, value.durationSeconds / 60)
            boolOption = value.schedulesEndAlert
            secondaryBoolOption = value.allowsLiveActivity
        case .moment(let value):
            startAt = value.occurredAt
            primaryText = value.location?.label ?? ""
            boolOption = value.location != nil
            selectedContactReferenceHashes = value.selectedContactReferenceHashes
        case .localContextAttachment(let value):
            mode = value.contextKind.rawValue
            primaryText = value.summaryCode
            startAt = value.observedAt
        case .unsupported:
            break
        }
    }

    var hasChanges: Bool {
        guard let payload = try? makePayload() else { return true }
        return title != original.title || rationale != original.rationale || payload != original.payload
    }

    func makeRevised(now: Date = Date()) throws -> SystemActionProposal {
        var normalized = self
        normalized.title = Self.utf8Prefix(
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumBytes: 160
        )
        normalized.rationale = Self.utf8Prefix(rationale, maximumBytes: 500)
        guard !normalized.title.isEmpty else { throw SystemActionDraftValidationError.titleRequired }
        return try original.revised(
            payload: normalized.makePayload(),
            title: normalized.title,
            rationale: normalized.rationale,
            expiresAt: original.expiresAt,
            now: now
        )
    }

    func makePayload() throws -> SystemActionPayload {
        switch original.payload {
        case .calendarEvent(let value):
            guard endAt > startAt else { throw SystemActionDraftValidationError.calendarInterval }
            let locationLabel = Self.nilIfEmpty(primaryText)
            if let locationLabel, locationLabel.utf8.count > 240 {
                throw SystemActionDraftValidationError.calendarLocationTooLong
            }
            return .calendarEvent(.init(
                title: title,
                notes: Self.nilIfEmpty(notes),
                startAt: startAt,
                endAt: endAt,
                isAllDay: isAllDay,
                timeZoneIdentifier: value.timeZoneIdentifier,
                location: locationLabel.map { .init(label: $0) },
                calendarHint: nil
            ))
        case .reminder:
            return .reminder(.init(
                title: title,
                notes: Self.nilIfEmpty(notes),
                dueAt: optionalDateEnabled ? optionalDate : nil,
                listHint: nil,
                priority: integerOption
            ))
        case .contactDraft:
            return .contactDraft(.init(
                givenName: primaryText,
                familyName: secondaryText,
                organization: Self.nilIfEmpty(notes),
                phoneNumbers: try Self.fields(phoneLines, label: "phone", maximumBytes: 40),
                emailAddresses: try Self.fields(emailLines, label: "email", maximumBytes: 254, validatesEmail: true)
            ))
        case .notification:
            return .notification(.init(
                title: title,
                body: notes,
                fireAt: optionalDate,
                threadIdentifier: nil,
                interruption: SystemActionNotificationInterruption(rawValue: mode) ?? .active,
                playsSound: true
            ))
        case .route:
            return .route(.init(
                destination: try routeDestination(),
                mode: SystemActionRouteMode(rawValue: mode) ?? .driving,
                opensImmediately: true
            ))
        case .capture:
            return .capture(.init(
                captureKind: SystemActionCaptureKind(rawValue: mode) ?? .document,
                suggestedTitle: Self.nilIfEmpty(primaryText),
                attachesToSource: boolOption
            ))
        case .focusSession:
            return .focusSession(.init(
                title: title,
                durationSeconds: min(max(integerOption, 1), 1_440) * 60,
                schedulesEndAlert: boolOption,
                allowsLiveActivity: secondaryBoolOption
            ))
        case .moment:
            let momentLocation: SystemActionLocation?
            if boolOption {
                guard let label = Self.nilIfEmpty(primaryText) else {
                    throw SystemActionDraftValidationError.momentPlaceLabelRequired
                }
                guard label.utf8.count <= 240 else {
                    throw SystemActionDraftValidationError.momentPlaceLabelTooLong
                }
                momentLocation = .init(label: label)
            } else {
                momentLocation = nil
            }
            return .moment(.init(
                occurredAt: startAt,
                title: Self.nilIfEmpty(title),
                location: momentLocation,
                selectedContactReferenceHashes: selectedContactReferenceHashes
            ))
        case .localContextAttachment(let value):
            return .localContextAttachment(.init(
                contextKind: value.contextKind,
                summaryCode: value.summaryCode,
                observedAt: value.observedAt
            ))
        case .unsupported(let kind, let value):
            return .unsupported(kind: kind, value: value)
        }
    }

    private func routeDestination() throws -> SystemActionLocation {
        let cleanLabel = Self.nilIfEmpty(primaryText)
        if let cleanLabel, cleanLabel.utf8.count > 240 {
            throw SystemActionDraftValidationError.routeLabelTooLong
        }

        switch routeDestinationMode {
        case .address:
            guard let address = Self.nilIfEmpty(secondaryText) else {
                throw SystemActionDraftValidationError.routeAddressRequired
            }
            guard address.utf8.count <= 500 else {
                throw SystemActionDraftValidationError.routeAddressTooLong
            }
            return .init(label: cleanLabel, address: address)
        case .coordinates:
        let latitudeText = latitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let longitudeText = longitude.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latitudeText.isEmpty, !longitudeText.isEmpty else {
                throw SystemActionDraftValidationError.routeCoordinatePairRequired
            }
            guard let lat = Double(latitudeText), let lon = Double(longitudeText),
                  lat.isFinite, lon.isFinite,
                  (-90...90).contains(lat), (-180...180).contains(lon) else {
                throw SystemActionDraftValidationError.routeCoordinateInvalid
            }
            return .init(label: cleanLabel, latitude: lat, longitude: lon)
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decimal(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? ""
    }

    private static func lines(_ fields: [SystemActionContactField]) -> String {
        fields.map(\.value).joined(separator: "\n")
    }

    private static func fields(
        _ value: String,
        label: String,
        maximumBytes: Int,
        validatesEmail: Bool = false
    ) throws -> [SystemActionContactField] {
        let values = value.split(whereSeparator: \.isNewline).compactMap { rawLine -> String? in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        let localizedKind = label == "phone"
            ? NSLocalizedString("system_action.contact.phone", value: "电话号码", comment: "")
            : NSLocalizedString("system_action.contact.email", value: "邮箱", comment: "")
        guard values.count <= 5 else {
            throw SystemActionDraftValidationError.contactFieldLimit(kind: localizedKind)
        }
        guard values.allSatisfy({ $0.utf8.count <= maximumBytes }) else {
            throw SystemActionDraftValidationError.contactValueTooLong(kind: localizedKind)
        }
        if validatesEmail, values.contains(where: { $0.utf8.count < 3 }) {
            throw SystemActionDraftValidationError.contactEmailInvalid
        }
        return values.map { SystemActionContactField(label: label, value: $0) }
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var result = ""
        result.reserveCapacity(min(value.count, maximumBytes))
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumBytes else { break }
            result = candidate
        }
        return result
    }
}
