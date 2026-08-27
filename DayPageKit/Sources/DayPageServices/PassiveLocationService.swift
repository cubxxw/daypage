import Foundation
import CoreLocation
import DayPageModels
import DayPageStorage

// MARK: - VisitDraft

/// A passively-detected location visit, pending user confirmation.
public struct VisitDraft: Codable, Identifiable, Equatable {
    public var id: UUID
    public var arrivalDate: Date
    public var departureDate: Date?
    public var latitude: Double
    public var longitude: Double
    public var placeName: String?
    public var status: Status
    /// Describes whether Core Location supplied a real arrival date. This is
    /// optional so drafts written by earlier releases remain decodable; an
    /// absent value is treated as a known arrival stored in `arrivalDate`.
    public var sourceArrivalSemantics: SourceArrivalSemantics?

    public enum Status: String, Codable {
        case pending
        case confirmed
        case ignored
    }

    public enum SourceArrivalSemantics: String, Codable {
        case known
        /// Core Location reported `Date.distantPast`, meaning the current
        /// visit began before monitoring could observe its arrival.
        case ongoing
    }
}

// MARK: - Passive visit upsert

/// A normalized visit observation that keeps Core Location's sentinel meaning
/// separate from the user-facing arrival date. `sourceArrivalDate == nil`
/// represents an ongoing visit whose arrival was not observed.
struct PassiveVisitObservation: Equatable {
    var observedAt: Date
    var sourceArrivalDate: Date?
    var departureDate: Date?
    var latitude: Double
    var longitude: Double
}

struct PassiveVisitUpsertResult: Equatable {
    var draftID: UUID
    var inserted: Bool
}

/// Pure matching/upsert logic, split from CLLocationManager so replay and
/// spatial-boundary behavior can be tested without constructing a CLVisit.
enum PassiveVisitDraftUpserter {
    /// CLVisit coordinates can move slightly between the arrival and departure
    /// callbacks. A 100 m radius is narrow enough to distinguish nearby places
    /// while remaining stable across normal visit-location jitter.
    static let spatialToleranceMeters: CLLocationDistance = 100
    static let arrivalToleranceSeconds: TimeInterval = 1
    /// Unknown-arrival observations do not carry a stable arrival timestamp.
    /// Bound their identity lifetime so an abandoned active draft cannot absorb
    /// a later visit at the same place indefinitely. Forty-eight hours covers a
    /// long home/hospital stay while still expiring stale OS state.
    static let maximumOngoingAge: TimeInterval = 48 * 60 * 60

    @discardableResult
    static func upsert(
        _ observation: PassiveVisitObservation,
        into drafts: inout [VisitDraft]
    ) -> PassiveVisitUpsertResult {
        if let index = drafts.firstIndex(where: { matches($0, observation) }) {
            // Preserve identity, first-observed arrival, place name, and user
            // status. A later departure callback only completes the same draft.
            if let departureDate = observation.departureDate {
                drafts[index].departureDate = departureDate
            }
            return PassiveVisitUpsertResult(draftID: drafts[index].id, inserted: false)
        }

        let draft = VisitDraft(
            id: UUID(),
            arrivalDate: observation.sourceArrivalDate ?? observation.observedAt,
            departureDate: observation.departureDate,
            latitude: observation.latitude,
            longitude: observation.longitude,
            placeName: nil,
            status: .pending,
            sourceArrivalSemantics: observation.sourceArrivalDate == nil ? .ongoing : .known
        )
        drafts.append(draft)
        return PassiveVisitUpsertResult(draftID: draft.id, inserted: true)
    }

    static func matches(_ draft: VisitDraft, _ observation: PassiveVisitObservation) -> Bool {
        let storedLocation = CLLocation(latitude: draft.latitude, longitude: draft.longitude)
        let observedLocation = CLLocation(
            latitude: observation.latitude,
            longitude: observation.longitude
        )
        guard storedLocation.distance(from: observedLocation) <= spatialToleranceMeters else {
            return false
        }

        if let sourceArrivalDate = observation.sourceArrivalDate {
            // Legacy drafts have no semantics field and stored a known arrival
            // directly, so they participate in the same idempotency rule.
            guard draft.sourceArrivalSemantics != .ongoing else { return false }
            return abs(draft.arrivalDate.timeIntervalSince(sourceArrivalDate))
                <= arrivalToleranceSeconds
        }

        guard draft.sourceArrivalSemantics == .ongoing else { return false }
        let ongoingAge = observation.observedAt.timeIntervalSince(draft.arrivalDate)
        guard ongoingAge >= -arrivalToleranceSeconds,
              ongoingAge <= maximumOngoingAge else { return false }
        switch (draft.departureDate, observation.departureDate) {
        case (nil, _):
            // An active ongoing draft is completed in place by its departure
            // callback; repeated active callbacks also resolve here.
            return true
        case let (storedDeparture?, observedDeparture?):
            return abs(storedDeparture.timeIntervalSince(observedDeparture))
                <= arrivalToleranceSeconds
        case (_?, nil):
            // A new ongoing visit at a previously completed place is distinct.
            return false
        }
    }
}

// MARK: - Passive visit persistence

enum PassiveVisitDraftPersistenceError: Error, Equatable {
    case notRegularFile
    case fileTooLarge
}

/// Bounded, atomic persistence for location drafts. The helper is internal so
/// its security boundaries can be tested without initializing CLLocationManager.
enum PassiveVisitDraftPersistence {
    /// More than enough for thousands of compact visit drafts while preventing
    /// an unexpected or corrupted file from causing an unbounded allocation.
    static let maximumFileBytes = 1 * 1_024 * 1_024

    static func load(from url: URL) throws -> [VisitDraft] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw PassiveVisitDraftPersistenceError.notRegularFile
        }
        guard let fileSize = values.fileSize,
              fileSize >= 0,
              fileSize <= maximumFileBytes else {
            throw PassiveVisitDraftPersistenceError.fileTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else {
            throw PassiveVisitDraftPersistenceError.fileTooLarge
        }
        return try JSONDecoder().decode([VisitDraft].self, from: data)
    }

    static func save(_ drafts: [VisitDraft], to url: URL) throws {
        let data = try JSONEncoder().encode(drafts)
        guard data.count <= maximumFileBytes else {
            throw PassiveVisitDraftPersistenceError.fileTooLarge
        }

        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: directoryProtectionAttributes
            )
        }

        #if os(iOS) || os(watchOS)
        // Visit callbacks can arrive while the app is in the background. This
        // protection class keeps the file encrypted before first unlock while
        // allowing background updates after the user has unlocked once.
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path
        )
        #endif
        try data.write(to: url, options: protectedAtomicWriteOptions)
    }

    private static var directoryProtectionAttributes: [FileAttributeKey: Any]? {
        #if os(iOS) || os(watchOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return nil
        #endif
    }

    private static var protectedAtomicWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(watchOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }
}

/// Persists the user's explicit product-level opt-in separately from Core
/// Location authorization. An OS grant alone must never silently turn visit
/// monitoring on after an app update or account transition.
struct PassiveVisitAutomationPreference {
    static let enabledKey = "system-actions.passive-visits-enabled.v1"

    let defaults: UserDefaults

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            defaults.set(true, forKey: Self.enabledKey)
        } else {
            defaults.removeObject(forKey: Self.enabledKey)
        }
    }
}

/// Central fail-closed gate for asynchronous visit and geocoder callbacks.
/// Core Location may deliver work already queued before the user disables the
/// feature or before an account transition finishes.
enum PassiveVisitAutomationGate {
    static func shouldAccept(
        automationEnabled: Bool,
        authorizationStatus: CLAuthorizationStatus,
        isMonitoring: Bool
    ) -> Bool {
        automationEnabled && authorizationStatus == .authorizedAlways && isMonitoring
    }
}

// MARK: - PassiveLocationService

/// Uses CLLocationManager visit monitoring to detect when the user arrives at
/// significant places without draining battery.
///
/// Visits are saved to vault/drafts/visits.json as VisitDraft records.
/// The user can confirm or ignore them in TodayView.
///
/// Requires "Always" location authorization and UIBackgroundModes: location in Info.plist.
@MainActor
public final class PassiveLocationService: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = PassiveLocationService()

    // MARK: - Published

    @Published public var pendingDrafts: [VisitDraft] = []
    @Published public private(set) var automationEnabled: Bool
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus

    // MARK: - Private

    private let manager: CLLocationManager
    private let automationPreference: PassiveVisitAutomationPreference
    private var isMonitoring = false

    // MARK: - Init

    private override init() {
        let manager = CLLocationManager()
        let preference = PassiveVisitAutomationPreference(defaults: .standard)
        self.manager = manager
        automationPreference = preference
        automationEnabled = preference.isEnabled
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        loadDrafts()
    }

    // MARK: - Public API

    /// Start monitoring visits if Always authorization is granted.
    public func startMonitoringIfAuthorized() {
        guard automationEnabled else { return }
        guard manager.authorizationStatus == .authorizedAlways else { return }
        guard !isMonitoring else { return }
        // Visit monitoring (CLVisit) is unavailable on watchOS — it requires an iPhone.
        #if !os(watchOS)
        manager.startMonitoringVisits()
        isMonitoring = true
        #endif
    }

    /// Stop monitoring visits.
    public func stopMonitoring() {
        #if !os(watchOS)
        manager.stopMonitoringVisits()
        #endif
        isMonitoring = false
    }

    /// This is the only product entry point that may request Always access.
    /// Enabling records the explicit user choice first, then requests the OS
    /// grant just in time. Disabling stops monitoring even if iOS retains the
    /// authorization grant.
    public func setVisitAutomationEnabled(_ enabled: Bool) {
        automationPreference.setEnabled(enabled)
        automationEnabled = enabled
        guard enabled else {
            stopMonitoring()
            return
        }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            startMonitoringIfAuthorized()
        case .notDetermined, .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            stopMonitoring()
        @unknown default:
            stopMonitoring()
        }
    }

    /// Account-scoped opt-in and pending observations must never cross an
    /// identity boundary. The runtime keeps its quarantine set if this exact
    /// cleanup cannot be completed.
    public func resetForAccountTransition() throws {
        stopMonitoring()
        automationPreference.setEnabled(false)
        automationEnabled = false
        pendingDrafts = []

        let url = Self.draftsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw PassiveVisitDraftPersistenceError.notRegularFile
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Confirm a pending draft, converting it to a location Memo in today's file.
    public func confirmDraft(_ draft: VisitDraft) throws {
        guard let storedDraft = pendingDrafts.first(where: { $0.id == draft.id }),
              storedDraft.status == .pending else { return }

        let memo = Memo(
            id: storedDraft.id,
            type: .location,
            created: storedDraft.arrivalDate,
            location: Memo.Location(
                name: storedDraft.placeName,
                lat: storedDraft.latitude,
                lng: storedDraft.longitude
            )
        )
        // The draft UUID is also the memo UUID. If the process previously
        // appended the memo but stopped before persisting the draft status, a
        // retry observes the same memo and does not append a duplicate block.
        let existing = try RawStorage.read(for: memo.created)
        if !existing.contains(where: { $0.id == memo.id }) {
            try RawStorage.append(memo)
        }
        updateDraftStatus(id: storedDraft.id, status: .confirmed)
    }

    /// Ignore a pending draft.
    public func ignoreDraft(_ draft: VisitDraft) {
        updateDraftStatus(id: draft.id, status: .ignored)
    }

    /// Return today's pending (unactioned) drafts.
    public func todayPendingDrafts() -> [VisitDraft] {
        let calendar = Calendar.current
        return pendingDrafts.filter { draft in
            draft.status == .pending &&
            calendar.isDateInToday(draft.arrivalDate)
        }
    }

    // MARK: - Persistence

    private static var draftsURL: URL {
        let draftsDir = VaultInitializer.vaultURL.appendingPathComponent("drafts", isDirectory: true)
        return draftsDir.appendingPathComponent("visits.json")
    }

    private func loadDrafts() {
        let url = Self.draftsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            pendingDrafts = try PassiveVisitDraftPersistence.load(from: url)
        } catch {
            DayPageLogger.shared.error("loadDrafts: \(error)")
        }
    }

    private func saveDrafts() {
        let url = Self.draftsURL
        do {
            try PassiveVisitDraftPersistence.save(pendingDrafts, to: url)
        } catch {
            DayPageLogger.shared.error("saveDrafts: \(error)")
        }
    }

    private func updateDraftStatus(id: UUID, status: VisitDraft.Status) {
        if let index = pendingDrafts.firstIndex(where: { $0.id == id }) {
            pendingDrafts[index].status = status
        }
        saveDrafts()
    }

    // MARK: - Geocoding

    private func geocodeAndUpdate(draftID: UUID, location: CLLocation) {
        let geocoder = CLGeocoder()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self, let placemark = placemarks?.first else { return }

            var parts: [String] = []
            if let name = placemark.name, !name.isEmpty {
                parts.append(name)
            }
            if let locality = placemark.locality, !parts.contains(locality) {
                parts.append(locality)
            }
            let placeName = parts.isEmpty ? placemark.country : parts.joined(separator: ", ")

            Task { @MainActor [weak self] in
                guard let self,
                      PassiveVisitAutomationGate.shouldAccept(
                        automationEnabled: self.automationEnabled,
                        authorizationStatus: self.authorizationStatus,
                        isMonitoring: self.isMonitoring
                      ) else { return }
                if let index = self.pendingDrafts.firstIndex(where: { $0.id == draftID }) {
                    self.pendingDrafts[index].placeName = placeName
                    self.saveDrafts()
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension PassiveLocationService: CLLocationManagerDelegate {

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.authorizationStatus = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedAlways where self.automationEnabled:
                self.startMonitoringIfAuthorized()
            default:
                self.stopMonitoring()
            }
        }
    }

    // Visit monitoring (CLVisit) is unavailable on watchOS — it requires an iPhone.
    #if !os(watchOS)
    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didVisit visit: CLVisit
    ) {
        let observation = PassiveVisitObservation(
            observedAt: Date(),
            sourceArrivalDate: visit.arrivalDate == .distantPast ? nil : visit.arrivalDate,
            departureDate: visit.departureDate == .distantFuture ? nil : visit.departureDate,
            latitude: visit.coordinate.latitude,
            longitude: visit.coordinate.longitude
        )

        Task { @MainActor [weak self] in
            guard let self,
                  PassiveVisitAutomationGate.shouldAccept(
                    automationEnabled: self.automationEnabled,
                    authorizationStatus: self.authorizationStatus,
                    isMonitoring: self.isMonitoring
                  ) else { return }
            let result = PassiveVisitDraftUpserter.upsert(
                observation,
                into: &self.pendingDrafts
            )
            self.saveDrafts()

            if result.inserted {
                let location = CLLocation(
                    latitude: observation.latitude,
                    longitude: observation.longitude
                )
                self.geocodeAndUpdate(draftID: result.draftID, location: location)
            }
        }
    }
    #endif
}
