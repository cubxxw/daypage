import Contacts
import Foundation

protocol AppleContactStore: AnyObject {
    func authorizationStatus() -> CNAuthorizationStatus
    func requestAccess() async throws -> Bool
    func execute(_ request: CNSaveRequest) throws
    func unifiedContact(identifier: String, keys: [CNKeyDescriptor]) throws -> CNContact
}

extension CNContactStore: AppleContactStore {
    func authorizationStatus() -> CNAuthorizationStatus {
        Self.authorizationStatus(for: .contacts)
    }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            requestAccess(for: .contacts) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func unifiedContact(identifier: String, keys: [CNKeyDescriptor]) throws -> CNContact {
        try unifiedContact(withIdentifier: identifier, keysToFetch: keys)
    }
}

@MainActor
final class AppleContactsClient {
    private let store: AppleContactStore

    init(store: AppleContactStore = CNContactStore()) {
        self.store = store
    }

    func authorizationState() -> AppleAuthorizationState {
        switch store.authorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .unavailable
        }
    }

    /// Saves the exact contact fields approved in DayPage. A mutable
    /// CNContactViewController is intentionally not used for execution because
    /// edited system-sheet values would no longer match the approved hash.
    func createContact(
        givenName: String,
        familyName: String,
        organization: String?,
        phoneNumbers: [(label: String, value: String)],
        emailAddresses: [(label: String, value: String)]
    ) async throws -> AppleExternalReference {
        let state = authorizationState()
        if state == .notDetermined {
            do {
                guard try await store.requestAccess() else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.contacts)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .contacts,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if state == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.contacts)
        } else if state == .restricted {
            throw AppleSystemActionAdapterError.authorizationRestricted(.contacts)
        } else if state == .unavailable {
            throw AppleSystemActionAdapterError.unavailable(.contacts)
        }

        let contact = makeContact(
            givenName: givenName,
            familyName: familyName,
            organization: organization,
            phoneNumbers: phoneNumbers,
            emailAddresses: emailAddresses
        )
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
        } catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .contacts,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
        guard !contact.identifier.isEmpty else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.contacts)
        }
        return AppleExternalReference(
            identifier: contact.identifier,
            createdAt: Date(),
            snapshot: try Self.snapshotData(for: contact)
        )
    }

    /// Contact identifiers are device-local material. An unresolvable ID is
    /// ambiguous and must never be interpreted as a successful undo.
    func deleteIfUnchanged(identifier: String, expectedSnapshot: Data?) async throws -> Bool {
        let state = authorizationState()
        if state == .notDetermined {
            do {
                guard try await store.requestAccess() else {
                    throw AppleSystemActionAdapterError.authorizationDenied(.contacts)
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .contacts,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        } else if state == .denied {
            throw AppleSystemActionAdapterError.authorizationDenied(.contacts)
        } else if state == .restricted {
            throw AppleSystemActionAdapterError.authorizationRestricted(.contacts)
        }
        do {
            let contact = try store.unifiedContact(identifier: identifier, keys: Self.snapshotKeys)
            guard let expectedSnapshot,
                  try Self.snapshotData(for: contact) == expectedSnapshot else {
                return false
            }
            let mutable = contact.mutableCopy() as? CNMutableContact
            guard let mutable else {
                throw AppleSystemActionAdapterError.ambiguousOutcome(.contacts)
            }
            let request = CNSaveRequest()
            request.delete(mutable)
            try store.execute(request)
            return true
        } catch let error as AppleSystemActionAdapterError {
            throw error
        } catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .contacts,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }

    func contains(identifier: String) -> Bool {
        (try? store.unifiedContact(identifier: identifier, keys: [CNContactIdentifierKey as CNKeyDescriptor])) != nil
    }

    private func makeContact(
        givenName: String,
        familyName: String,
        organization: String?,
        phoneNumbers: [(label: String, value: String)],
        emailAddresses: [(label: String, value: String)]
    ) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = familyName
        contact.organizationName = organization ?? ""
        // Contract v1 binds the values but not arbitrary Contacts labels into
        // the approval hash. Use deterministic labels so execution never
        // consumes an unbound payload field.
        contact.phoneNumbers = phoneNumbers.prefix(8).compactMap { field in
            let value = field.value
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CNLabeledValue(
                label: CNLabelPhoneNumberMain,
                value: CNPhoneNumber(stringValue: value)
            )
        }
        contact.emailAddresses = emailAddresses.prefix(8).compactMap { field in
            let value = field.value
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CNLabeledValue(
                label: CNLabelHome,
                value: value as NSString
            )
        }
        return contact
    }

    private struct Snapshot: Codable {
        struct Field: Codable {
            let label: String?
            let value: String
        }

        let givenName: String
        let familyName: String
        let organizationName: String
        let phoneNumbers: [Field]
        let emailAddresses: [Field]
    }

    private static let snapshotKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    static func snapshotData(for contact: CNContact) throws -> Data {
        let snapshot = Snapshot(
            givenName: contact.givenName,
            familyName: contact.familyName,
            organizationName: contact.organizationName,
            phoneNumbers: contact.phoneNumbers.map {
                Snapshot.Field(label: $0.label, value: $0.value.stringValue)
            },
            emailAddresses: contact.emailAddresses.map {
                Snapshot.Field(label: $0.label, value: $0.value as String)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }
}
