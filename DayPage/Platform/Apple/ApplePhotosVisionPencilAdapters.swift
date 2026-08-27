import Foundation
import Photos
import PencilKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

protocol ApplePhotoLibrary: AnyObject {
    func addOnlyAuthorizationStatus() -> PHAuthorizationStatus
    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus
    func saveAsset(data: Data, uniformTypeIdentifier: String) async throws
}

final class SystemApplePhotoLibrary: ApplePhotoLibrary {
    func addOnlyAuthorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    func saveAsset(data: Data, uniformTypeIdentifier: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = uniformTypeIdentifier
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: AppleSystemActionAdapterError.ambiguousOutcome(.photos)) }
            }
        }
    }
}

@MainActor
final class ApplePhotosClient {
    private let library: ApplePhotoLibrary

    init(library: ApplePhotoLibrary = SystemApplePhotoLibrary()) {
        self.library = library
    }

    func addOnlyAuthorizationState() -> AppleAuthorizationState {
        switch library.addOnlyAuthorizationStatus() {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .unavailable
        }
    }

    /// Requests add-only access just in time, after export confirmation.
    func saveConfirmedExport(data: Data, type: UTType) async throws {
        guard type.conforms(to: .image), !data.isEmpty else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "photo")
        }
        var state = addOnlyAuthorizationState()
        if state == .notDetermined {
            let status = await library.requestAddOnlyAuthorization()
            state = Self.map(status)
        }
        if state == .denied { throw AppleSystemActionAdapterError.authorizationDenied(.photos) }
        if state == .restricted { throw AppleSystemActionAdapterError.authorizationRestricted(.photos) }
        guard state == .authorized || state == .limited else {
            throw AppleSystemActionAdapterError.unavailable(.photos)
        }
        do { try await library.saveAsset(data: data, uniformTypeIdentifier: type.identifier) }
        catch let error as AppleSystemActionAdapterError { throw error }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .photos,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> AppleAuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .unavailable
        }
    }
}

@MainActor
enum AppleVisionCapability {
    static var documentCameraAvailable: Bool {
        VNDocumentCameraViewController.isSupported
    }

    @available(iOS 16.0, *)
    static var liveDataScannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}

enum ApplePencilCapability {
    static var isAvailable: Bool { true }

    static func decodeDrawing(_ data: Data) throws -> PKDrawing {
        do { return try PKDrawing(data: data) }
        catch {
            throw AppleSystemActionAdapterError.frameworkFailure(
                capability: .pencil,
                code: AppleAdapterPrivacy.failureCode(error)
            )
        }
    }
}
