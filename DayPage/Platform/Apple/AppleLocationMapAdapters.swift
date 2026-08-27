@preconcurrency import CoreLocation
import Foundation
import MapKit

struct AppleLocationSample: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let timestamp: Date
}

@MainActor
protocol AppleOneShotLocationServing: AnyObject {
    func authorizationState() -> AppleAuthorizationState
    func requestCurrentLocation() async throws -> AppleLocationSample
}

@MainActor
final class AppleOneShotLocationClient: NSObject {
    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<AppleLocationSample, Error>?

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    func authorizationState() -> AppleAuthorizationState {
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .unavailable
        }
    }

    /// Must be called only after the user confirms the concrete moment action.
    /// This never escalates to Always authorization.
    func requestCurrentLocation() async throws -> AppleLocationSample {
        guard CLLocationManager.locationServicesEnabled() else {
            throw AppleSystemActionAdapterError.unavailable(.location)
        }
        guard continuation == nil else {
            throw AppleSystemActionAdapterError.ambiguousOutcome(.location)
        }
        switch authorizationState() {
        case .denied:
            throw AppleSystemActionAdapterError.authorizationDenied(.location)
        case .restricted:
            throw AppleSystemActionAdapterError.authorizationRestricted(.location)
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized:
            manager.requestLocation()
        case .writeOnly, .limited, .unavailable:
            throw AppleSystemActionAdapterError.unavailable(.location)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if self.authorizationState() == .authorized {
                    self.manager.requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(AppleSystemActionAdapterError.userCancelled(.location)))
            }
        }
    }

    fileprivate func handleAuthorizationChange(_ manager: CLLocationManager) {
        switch authorizationState() {
        case .authorized:
            if continuation != nil { manager.requestLocation() }
        case .denied:
            finish(.failure(AppleSystemActionAdapterError.authorizationDenied(.location)))
        case .restricted:
            finish(.failure(AppleSystemActionAdapterError.authorizationRestricted(.location)))
        default:
            break
        }
    }

    fileprivate func handleLocations(_ locations: [CLLocation]) {
        guard let location = locations
            .filter({ $0.horizontalAccuracy >= 0 })
            .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else {
            finish(.failure(AppleSystemActionAdapterError.ambiguousOutcome(.location)))
            return
        }
        finish(.success(AppleLocationSample(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp
        )))
    }

    fileprivate func handleFailure(_ error: Error) {
        finish(.failure(AppleSystemActionAdapterError.frameworkFailure(
            capability: .location,
            code: AppleAdapterPrivacy.failureCode(error)
        )))
    }

    private func finish(_ result: Result<AppleLocationSample, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension AppleOneShotLocationClient: AppleOneShotLocationServing {}

@MainActor
extension AppleOneShotLocationClient: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorizationChange(manager)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        handleLocations(locations)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        handleFailure(error)
    }
}

@MainActor
final class AppleMapClient {
    enum RouteMode { case any, driving, walking, transit, cycling }
    typealias Opener = @MainActor @Sendable (MKMapItem, [String: Any]?) -> Bool
    typealias AddressResolver = @MainActor @Sendable (String) async throws -> MKMapItem?

    private let opener: Opener
    private let addressResolver: AddressResolver

    init(
        opener: @escaping Opener = { item, options in item.openInMaps(launchOptions: options) },
        addressResolver: AddressResolver? = nil
    ) {
        self.opener = opener
        self.addressResolver = addressResolver ?? { address in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = address
            request.resultTypes = .address
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.first
        }
    }

    func openRoute(latitude: Double, longitude: Double, label: String?, mode: RouteMode) throws {
        try openResolvedRoute(
            item: mapItem(latitude: latitude, longitude: longitude, label: label),
            mode: mode
        )
    }

    /// Opens either an exact coordinate or a user-readable address. Route
    /// lookup does not request the device's location permission because the
    /// destination is proposal data, not the user's current position.
    func openRoute(
        latitude: Double?,
        longitude: Double?,
        address: String?,
        label: String?,
        mode: RouteMode
    ) async throws {
        let item: MKMapItem
        switch (latitude, longitude) {
        case (.some(let latitude), .some(let longitude)):
            item = try mapItem(latitude: latitude, longitude: longitude, label: label)
        case (.none, .none):
            let query = address?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty, query.utf8.count <= 512 else {
                throw AppleSystemActionAdapterError.invalidPayload(field: "route.address")
            }
            do {
                guard let resolved = try await addressResolver(query) else {
                    throw AppleSystemActionAdapterError.invalidPayload(field: "route.address")
                }
                item = resolved
                if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // This is already the exact approved, 240-byte-bounded
                    // proposal field. Do not normalize or truncate it again.
                    item.name = label
                }
            } catch let error as AppleSystemActionAdapterError {
                throw error
            } catch {
                throw AppleSystemActionAdapterError.frameworkFailure(
                    capability: .maps,
                    code: AppleAdapterPrivacy.failureCode(error)
                )
            }
        default:
            throw AppleSystemActionAdapterError.invalidPayload(field: "route.coordinate")
        }
        try openResolvedRoute(item: item, mode: mode)
    }

    private func mapItem(latitude: Double, longitude: Double, label: String?) throws -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "coordinate")
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = label
        return item
    }

    private func openResolvedRoute(item: MKMapItem, mode: RouteMode) throws {
        let directionsMode: String
        switch mode {
        case .any: directionsMode = MKLaunchOptionsDirectionsModeDefault
        case .driving: directionsMode = MKLaunchOptionsDirectionsModeDriving
        case .walking: directionsMode = MKLaunchOptionsDirectionsModeWalking
        case .transit: directionsMode = MKLaunchOptionsDirectionsModeTransit
        case .cycling: directionsMode = MKLaunchOptionsDirectionsModeCycling
        }
        let options = [MKLaunchOptionsDirectionsModeKey: directionsMode]
        guard opener(item, options) else {
            throw AppleSystemActionAdapterError.userCancelled(.maps)
        }
    }
}
