import CoreLocation
import Foundation
import HealthKit
import WeatherKit
import DayPageModels
import DayPageStorage

protocol AppleLocalContextReferenceVerifying: Sendable {
    func contains(referenceID: UUID, kind: SystemActionLocalContextKind) async -> Bool
}

/// Device-only, immutable summaries produced by an explicit foreground
/// Health/Weather/Place flow. Agent payloads can carry only the UUID reference;
/// they cannot trigger framework reads or supply the summary content.
actor AppleLocalContextStore: AppleLocalContextReferenceVerifying {
    static let shared = AppleLocalContextStore()
    static let maximumRecordBytes = 16 * 1_024

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        vaultRootURL: URL = LocalVaultLocator().vaultURL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = vaultRootURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("local-context", isDirectory: true)
        self.fileManager = fileManager
    }

    /// Writes one bounded local summary and returns the only value permitted in
    /// a `local_context_attachment` proposal. IDs are generated internally and
    /// records are never overwritten, so an approved reference stays immutable.
    func persist(
        kind: SystemActionLocalContextKind,
        observedAt: Date,
        boundedValues: [String: String]
    ) throws -> UUID {
        let record = try Record(
            id: UUID(),
            kind: kind,
            observedAt: observedAt,
            boundedValues: boundedValues
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        guard data.count <= Self.maximumRecordBytes else {
            throw AppleLocalContextStoreError.recordTooLarge
        }
        let targetURL = url(for: record.id)
        let stagingURL = directoryURL.appendingPathComponent(
            ".staging-\(UUID().uuidString.lowercased())",
            isDirectory: false
        )
        do {
            try data.write(
                to: stagingURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            // Moving a same-volume staging file is atomic and fails if the
            // immutable UUID target already exists.
            try fileManager.moveItem(at: stagingURL, to: targetURL)
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        return record.id
    }

    func contains(referenceID: UUID, kind: SystemActionLocalContextKind) async -> Bool {
        let fileURL = url(for: referenceID)
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 0,
              fileSize.intValue <= Self.maximumRecordBytes,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let record = try? Self.decodeRecord(data),
              record.id == referenceID,
              record.kind == kind,
              (try? record.validate()) != nil else {
            return false
        }
        return true
    }

    private func url(for referenceID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(referenceID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private static func decodeRecord(_ data: Data) throws -> Record {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Record.self, from: data)
    }

    private struct Record: Codable, Sendable {
        let schemaVersion: Int
        let id: UUID
        let kind: SystemActionLocalContextKind
        let observedAt: Date
        let boundedValues: [String: String]

        init(
            id: UUID,
            kind: SystemActionLocalContextKind,
            observedAt: Date,
            boundedValues: [String: String]
        ) throws {
            self.schemaVersion = 1
            self.id = id
            self.kind = kind
            self.observedAt = observedAt
            self.boundedValues = boundedValues
            try validate()
        }

        func validate() throws {
            guard schemaVersion == 1,
                  observedAt.timeIntervalSince1970.isFinite,
                  boundedValues.count <= 16 else {
                throw AppleLocalContextStoreError.invalidRecord
            }
            let keyCharacters = CharacterSet.lowercaseLetters
                .union(.decimalDigits)
                .union(CharacterSet(charactersIn: "_"))
            for (key, value) in boundedValues {
                guard !key.isEmpty,
                      key.utf8.count <= 64,
                      key.unicodeScalars.allSatisfy(keyCharacters.contains),
                      value.utf8.count <= 256,
                      !value.contains("\n"),
                      !value.contains("\r") else {
                    throw AppleLocalContextStoreError.invalidRecord
                }
            }
        }
    }
}

enum AppleLocalContextStoreError: Error, Sendable, Equatable {
    case invalidRecord
    case recordTooLarge
}

enum AppleLocalContextReference {
    static func parse(_ value: String) throws -> UUID {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let referenceID = UUID(uuidString: value) else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "localContext.reference")
        }
        return referenceID
    }
}

struct AppleHealthContext: Sendable, Equatable {
    let stepCount: Double?
    let windowStart: Date
    let windowEnd: Date
}

final class AppleHealthContextClient: @unchecked Sendable {
    typealias AuthorizationRequester = @Sendable (Set<HKObjectType>) async throws -> Bool
    typealias StepReader = @Sendable (HKQuantityType, Date, Date) async throws -> Double?

    private let requestAuthorization: AuthorizationRequester
    private let readSteps: StepReader

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        requestAuthorization: AuthorizationRequester? = nil,
        readSteps: StepReader? = nil
    ) {
        self.requestAuthorization = requestAuthorization ?? { types in
            try await healthStore.requestAuthorization(toShare: [], read: types)
            return true
        }
        self.readSteps = readSteps ?? { type, start, end in
            try await withCheckedThrowingContinuation { continuation in
                let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
                let query = HKStatisticsQuery(
                    quantityType: type,
                    quantitySamplePredicate: predicate,
                    options: .cumulativeSum
                ) { _, result, error in
                    if let error { continuation.resume(throwing: error) }
                    else {
                        continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count()))
                    }
                }
                healthStore.execute(query)
            }
        }
    }

    func capabilityState() -> AppleAuthorizationState {
        HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    /// Reads only step count for the explicitly confirmed local context
    /// window. The returned summary is not suitable for cloud/agent payloads.
    func readConfirmedStepContext(start: Date, end: Date) async throws -> AppleHealthContext {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw AppleSystemActionAdapterError.unavailable(.health)
        }
        guard end > start, end.timeIntervalSince(start) <= 7 * 24 * 60 * 60 else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "healthWindow")
        }
        guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
            throw AppleSystemActionAdapterError.unavailable(.health)
        }
        do {
            guard try await requestAuthorization([stepType]) else {
                throw AppleSystemActionAdapterError.authorizationDenied(.health)
            }
            let stepCount = try await readSteps(stepType, start, end)
            return AppleHealthContext(
                stepCount: stepCount,
                windowStart: start,
                windowEnd: end
            )
        } catch let error as AppleSystemActionAdapterError {
            throw error
        } catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .health,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }
}

struct AppleWeatherContext: Sendable, Equatable {
    let observedAt: Date
    let conditionCode: String
    let symbolName: String
    let temperatureCelsius: Double
    let apparentTemperatureCelsius: Double
    let humidity: Double
}

final class AppleWeatherContextClient: @unchecked Sendable {
    typealias Fetcher = @Sendable (CLLocation) async throws -> AppleWeatherContext
    private let fetcher: Fetcher

    init(fetcher: Fetcher? = nil) {
        self.fetcher = fetcher ?? { location in
            let current = try await WeatherService.shared.weather(for: location, including: .current)
            return AppleWeatherContext(
                observedAt: current.date,
                conditionCode: String(describing: current.condition),
                symbolName: current.symbolName,
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                apparentTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
                humidity: current.humidity
            )
        }
    }

    /// Coordinates are consumed in memory for WeatherKit and are deliberately
    /// absent from the returned summary and operational error.
    func fetchConfirmedContext(latitude: Double, longitude: Double) async throws -> AppleWeatherContext {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "coordinate")
        }
        do { return try await fetcher(CLLocation(latitude: latitude, longitude: longitude)) }
        catch let error as AppleSystemActionAdapterError { throw error }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .weather,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }
}

protocol AppleMomentPersisting: Sendable {
    func saveDraft(
        title: String,
        occurredAt: Date,
        contactReferenceHashes: [String],
        photoFileURL: URL?,
        photoFileExtension: String?
    ) async throws -> UUID
    func complete(
        proposal: SystemActionProposal,
        coordinate: CLLocationCoordinate2D?
    ) async throws -> UUID
    func isCompleted(id: UUID, proposalID: UUID) async -> Bool
    func discardDraft(id: UUID) async throws
}

/// Device-local Moment truth. Moment media and one-shot coordinates never
/// enter the action ledger or cloud contract; the proposal carries only an
/// opaque draft UUID in its source references.
actor AppleMomentStore: AppleMomentPersisting {
    static let shared = AppleMomentStore()
    static let maximumPhotoByteCount = 50 * 1_024 * 1_024

    private enum State: String, Codable { case draft, completed }
    private struct Record: Codable {
        let schemaVersion: Int
        let id: UUID
        let createdAt: Date
        let occurredAt: Date
        let title: String
        let contactReferenceHashes: [String]
        let photoRelativePath: String?
        let photoByteCount: Int?
        let state: State
        let proposalID: UUID?
        let latitude: Double?
        let longitude: Double?
    }

    private struct CleanupObligation: Codable {
        let schemaVersion: Int
        let draftID: UUID
        let proposalID: UUID?
        let proposalRevision: Int64?
        let payloadHash: String?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case draftID = "draft_id"
            case proposalID = "proposal_id"
            case proposalRevision = "proposal_revision"
            case payloadHash = "payload_hash"
        }
    }

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        vaultRootURL: URL = LocalVaultLocator().vaultURL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = vaultRootURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("moments", isDirectory: true)
        self.fileManager = fileManager
    }

    func saveDraft(
        title: String,
        occurredAt: Date,
        contactReferenceHashes: [String],
        photoFileURL: URL?,
        photoFileExtension: String?
    ) throws -> UUID {
        let id = UUID()
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        guard !cleanTitle.isEmpty,
              contactReferenceHashes.count <= 20,
              contactReferenceHashes.allSatisfy({ value in
                  value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }
              }) else {
            throw AppleLocalContextStoreError.invalidRecord
        }
        try createDirectories()
        var photoRelativePath: String?
        var photoByteCount: Int?
        if let photoFileURL {
            let safeExtension = (photoFileExtension ?? "image").lowercased().filter { $0.isLetter || $0.isNumber }
            guard !safeExtension.isEmpty, safeExtension.count <= 12 else {
                throw AppleLocalContextStoreError.invalidRecord
            }
            let relative = "assets/\(id.uuidString.lowercased()).\(safeExtension)"
            let destination = directoryURL.appendingPathComponent(relative)
            do {
                photoByteCount = try SystemActionBoundedFileCopier.copy(
                    from: photoFileURL,
                    to: destination,
                    maximumByteCount: Self.maximumPhotoByteCount
                )
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path
                )
                photoRelativePath = relative
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }
        let record = Record(
            schemaVersion: 1,
            id: id,
            createdAt: Date(),
            occurredAt: occurredAt,
            title: cleanTitle,
            contactReferenceHashes: contactReferenceHashes,
            photoRelativePath: photoRelativePath,
            photoByteCount: photoByteCount,
            state: .draft,
            proposalID: nil,
            latitude: nil,
            longitude: nil
        )
        do {
            try write(record)
            return id
        } catch {
            if let photoRelativePath {
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent(photoRelativePath))
            }
            throw error
        }
    }

    func complete(
        proposal: SystemActionProposal,
        coordinate: CLLocationCoordinate2D?
    ) throws -> UUID {
        guard case .moment(let approved) = proposal.payload else {
            throw AppleLocalContextStoreError.invalidRecord
        }
        let referencedID = proposal.sourceReferences.compactMap { reference -> UUID? in
            guard reference.kind == .entity,
                  reference.identifier.hasPrefix("moment:") else { return nil }
            return UUID(uuidString: String(reference.identifier.dropFirst("moment:".count)))
        }.first

        let base: Record
        if let referencedID {
            base = try read(id: referencedID)
            if base.state == .completed {
                guard base.proposalID == proposal.id,
                      base.occurredAt == approved.occurredAt,
                      base.title == (approved.title ?? proposal.title),
                      base.contactReferenceHashes == approved.selectedContactReferenceHashes else {
                    throw AppleLocalContextStoreError.invalidRecord
                }
                return base.id
            }
        } else {
            try createDirectories()
            base = Record(
                schemaVersion: 1,
                id: UUID(),
                createdAt: Date(),
                occurredAt: approved.occurredAt,
                title: approved.title ?? proposal.title,
                contactReferenceHashes: approved.selectedContactReferenceHashes,
                photoRelativePath: nil,
                photoByteCount: nil,
                state: .draft,
                proposalID: nil,
                latitude: nil,
                longitude: nil
            )
        }
        let completed = Record(
            schemaVersion: base.schemaVersion,
            id: base.id,
            createdAt: base.createdAt,
            // The approved revision is the executable truth. A referenced
            // draft contributes only its stable identity and staged media.
            occurredAt: approved.occurredAt,
            title: approved.title ?? proposal.title,
            contactReferenceHashes: approved.selectedContactReferenceHashes,
            photoRelativePath: base.photoRelativePath,
            photoByteCount: base.photoByteCount,
            state: .completed,
            proposalID: proposal.id,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )
        try write(completed)
        return completed.id
    }

    func discardDraft(id: UUID) throws {
        try createDirectories()
        try writeCleanupMarker(.init(
            schemaVersion: 1,
            draftID: id,
            proposalID: nil,
            proposalRevision: nil,
            payloadHash: nil
        ))
        try cleanupDraft(id: id)
    }

    /// Persists the cross-store cleanup intent before the rejection is written
    /// to the action ledger. Startup replays it only after proving that exact
    /// proposal revision/hash has a durable rejected decision.
    func prepareDiscard(
        id: UUID,
        proposalID: UUID,
        proposalRevision: Int64,
        payloadHash: String
    ) throws {
        try createDirectories()
        try writeCleanupMarker(.init(
            schemaVersion: 1,
            draftID: id,
            proposalID: proposalID,
            proposalRevision: proposalRevision,
            payloadHash: payloadHash
        ))
    }

    func cancelPreparedDiscard(id: UUID) throws {
        let marker = cleanupMarkerURL(id: id)
        if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
    }

    func commitPreparedDiscard(id: UUID) throws {
        try cleanupDraft(id: id)
    }

    /// Replays crash-safe draft deletion obligations. A marker is written
    /// before any destructive step; the manifest remains until its staged
    /// photo has been removed, so a restart never loses the cleanup target.
    func retryPendingCleanup(
        isProposalRejected: @Sendable (UUID, Int64, String) async throws -> Bool = { _, _, _ in false }
    ) async throws {
        let cleanup = cleanupDirectoryURL
        guard fileManager.fileExists(atPath: cleanup.path) else { return }
        let urls = try fileManager.contentsOfDirectory(
            at: cleanup,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where url.pathExtension == "json" {
            let obligation = try readCleanupMarker(at: url)
            guard obligation.draftID.uuidString.lowercased()
                    == url.deletingPathExtension().lastPathComponent.lowercased() else {
                throw AppleLocalContextStoreError.invalidRecord
            }
            if let proposalID = obligation.proposalID,
               let proposalRevision = obligation.proposalRevision,
               let payloadHash = obligation.payloadHash {
                guard try await isProposalRejected(
                    proposalID,
                    proposalRevision,
                    payloadHash
                ) else {
                    // The marker was durable before the cross-store rejection.
                    // No matching ledger decision means the reject never
                    // committed, so retain the user's draft and cancel intent.
                    try fileManager.removeItem(at: url)
                    continue
                }
            } else if obligation.proposalID != nil
                        || obligation.proposalRevision != nil
                        || obligation.payloadHash != nil {
                throw AppleLocalContextStoreError.invalidRecord
            }
            try cleanupDraft(id: obligation.draftID)
        }
    }

    func pendingCleanupIDs() throws -> [UUID] {
        guard fileManager.fileExists(atPath: cleanupDirectoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: cleanupDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func isCompleted(id: UUID, proposalID: UUID) -> Bool {
        guard let record = try? read(id: id) else { return false }
        return record.state == .completed && record.proposalID == proposalID
    }

    func clearAll() throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    private func createDirectories() throws {
        try fileManager.createDirectory(
            at: directoryURL.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try fileManager.createDirectory(
            at: cleanupDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    private var cleanupDirectoryURL: URL {
        directoryURL.appendingPathComponent("cleanup", isDirectory: true)
    }

    private func cleanupMarkerURL(id: UUID) -> URL {
        cleanupDirectoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func writeCleanupMarker(_ obligation: CleanupObligation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(obligation)
        try data.write(
            to: cleanupMarkerURL(id: obligation.draftID),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func readCleanupMarker(at url: URL) throws -> CleanupObligation {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 4 * 1_024 else { throw AppleLocalContextStoreError.recordTooLarge }
        let obligation = try JSONDecoder().decode(CleanupObligation.self, from: data)
        guard obligation.schemaVersion == 1,
              obligation.payloadHash.map({ value in
                  value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }
              }) ?? true,
              obligation.proposalRevision.map({ $0 > 0 }) ?? true else {
            throw AppleLocalContextStoreError.invalidRecord
        }
        return obligation
    }

    private func cleanupDraft(id: UUID) throws {
        let marker = cleanupMarkerURL(id: id)
        let manifest = manifestURL(id: id)
        guard fileManager.fileExists(atPath: manifest.path) else {
            if fileManager.fileExists(atPath: marker.path) {
                try fileManager.removeItem(at: marker)
            }
            return
        }
        let record = try read(id: id)
        guard record.state == .draft else {
            if fileManager.fileExists(atPath: marker.path) {
                try fileManager.removeItem(at: marker)
            }
            return
        }
        if let path = record.photoRelativePath {
            let photo = directoryURL.appendingPathComponent(path)
            if fileManager.fileExists(atPath: photo.path) {
                try fileManager.removeItem(at: photo)
            }
        }
        // The manifest is the authoritative pointer to staged media, so it is
        // removed only after photo deletion succeeds.
        try fileManager.removeItem(at: manifest)
        if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
    }

    private func manifestURL(id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func write(_ record: Record) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        guard data.count <= 16 * 1_024 else { throw AppleLocalContextStoreError.recordTooLarge }
        try data.write(
            to: manifestURL(id: record.id),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func read(id: UUID) throws -> Record {
        let data = try Data(contentsOf: manifestURL(id: id), options: .mappedIfSafe)
        guard data.count <= 16 * 1_024 else { throw AppleLocalContextStoreError.recordTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(Record.self, from: data)
        guard record.schemaVersion == 1, record.id == id else {
            throw AppleLocalContextStoreError.invalidRecord
        }
        return record
    }
}
