import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct AppleSpotlightRecord: Sendable, Equatable {
    let identifier: String
    let domainIdentifier: String
    let title: String
    let summary: String?
    let keywords: [String]
    let expirationDate: Date?
    let contentURL: URL?
    let privacySensitive: Bool
}

protocol AppleSearchableIndex: AnyObject {
    func index(_ items: [CSSearchableItem]) async throws
    func delete(identifiers: [String]) async throws
    func delete(domainIdentifiers: [String]) async throws
}

final class SystemAppleSearchableIndex: AppleSearchableIndex {
    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = .default()) {
        self.index = index
    }

    func index(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func delete(identifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func delete(domainIdentifiers: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }
}

final class AppleSpotlightIndexer: @unchecked Sendable {
    private let index: AppleSearchableIndex

    init(index: AppleSearchableIndex = SystemAppleSearchableIndex()) {
        self.index = index
    }

    func upsert(_ records: [AppleSpotlightRecord]) async throws {
        guard records.count <= 500 else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "spotlightBatch")
        }
        let items = records.map { record -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = record.privacySensitive
                ? NSLocalizedString(
                    "system_action.spotlight.private_title",
                    value: "Private DayPage item",
                    comment: "Redacted private Spotlight item title"
                )
                : AppleAdapterPrivacy.boundedPublicText(record.title, limit: 160)
            attributes.contentDescription = record.privacySensitive
                ? NSLocalizedString(
                    "system_action.spotlight.private_summary",
                    value: "Open DayPage to view this private item.",
                    comment: "Redacted private Spotlight item summary"
                )
                : record.summary.map { AppleAdapterPrivacy.boundedPublicText($0, limit: 240) }
            attributes.keywords = record.privacySensitive
                ? []
                : Array(record.keywords.prefix(20)).map {
                    AppleAdapterPrivacy.boundedPublicText($0, limit: 64)
                }
            attributes.contentURL = record.contentURL
            return CSSearchableItem(
                uniqueIdentifier: record.identifier,
                domainIdentifier: record.domainIdentifier,
                attributeSet: attributes
            ).settingExpiration(record.expirationDate)
        }
        do { try await index.index(items) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .spotlight,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }

    func delete(identifiers: [String]) async throws {
        guard identifiers.count <= 500 else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "spotlightIdentifiers")
        }
        do { try await index.delete(identifiers: identifiers) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .spotlight,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }

    func clear(domainIdentifier: String) async throws {
        do { try await index.delete(domainIdentifiers: [domainIdentifier]) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .spotlight,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }
}

private extension CSSearchableItem {
    func settingExpiration(_ date: Date?) -> CSSearchableItem {
        expirationDate = date
        return self
    }
}
