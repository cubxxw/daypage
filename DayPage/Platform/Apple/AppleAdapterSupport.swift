import Foundation
import DayPageServices

enum AppleCapability: String, Sendable, CaseIterable {
    case calendar
    case reminders
    case contacts
    case notifications
    case location
    case maps
    case photos
    case capture
    case vision
    case pencil
    case liveActivity
    case spotlight
    case health
    case weather
    case localContext
}

enum AppleAuthorizationState: String, Sendable, Equatable {
    case notDetermined
    case authorized
    case writeOnly
    case limited
    case denied
    case restricted
    case unavailable
}

enum AppleSystemActionAdapterError: Error, Sendable, Equatable, SystemActionAmbiguousError {
    case unavailable(AppleCapability)
    case unsupported(AppleCapability)
    case authorizationDenied(AppleCapability)
    case authorizationRestricted(AppleCapability)
    case invalidPayload(field: String)
    case requiresUserInterface(AppleCapability)
    case presentationInProgress(AppleCapability)
    case userCancelled(AppleCapability)
    case ambiguousOutcome(AppleCapability)
    case frameworkFailure(capability: AppleCapability, code: String)

    var isSystemActionAmbiguous: Bool {
        if case .ambiguousOutcome = self { return true }
        return false
    }
}

struct AppleExternalReference: Sendable, Equatable {
    let identifier: String
    let createdAt: Date
    /// Device-local exact snapshot of the fields DayPage created. Undo compares
    /// the current system object against this snapshot before deleting it.
    let snapshot: Data?

    init(identifier: String, createdAt: Date, snapshot: Data? = nil) {
        self.identifier = identifier
        self.createdAt = createdAt
        self.snapshot = snapshot
    }
}

enum AppleAdapterPrivacy {
    /// Produces a bounded operational code without including localized error
    /// text, proposal content, coordinates, contact values, or raw identifiers.
    static func failureCode(_ error: Error) -> String {
        let nsError = error as NSError
        let raw = "\(nsError.domain).\(nsError.code)"
        let filtered = raw.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 97...122, 45, 46, 95:
                return Character(scalar)
            default:
                return "_"
            }
        }
        return String(filtered).prefixUTF8Bytes(64)
    }

    static func boundedPublicText(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.prefixUTF8Bytes(max(0, limit))
    }
}

private extension String {
    func prefixUTF8Bytes(_ limit: Int) -> String {
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
