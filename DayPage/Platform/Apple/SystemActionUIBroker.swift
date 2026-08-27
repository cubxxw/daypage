import Combine
import ContactsUI
import EventKitUI
import Foundation
import UIKit
import DayPageModels

/// The single foreground-presentation boundary used by native system actions.
///
/// Adapters await this broker after the exact proposal revision has been
/// approved. The app root observes `activePresentation`, presents the supplied
/// native editor or capture surface, and completes or cancels the matching ID.
/// Only one system presentation can be active, preventing continuations from
/// being attached to the wrong proposal when multiple entry points race.
@MainActor
final class SystemActionUIBroker: ObservableObject {
    static let shared = SystemActionUIBroker()

    @Published private(set) var activePresentation: SystemActionUIPresentation?

    private var pending: Pending?
    private var calendarDelegate: CalendarEditorDelegate?
    private var contactDelegate: ContactEditorDelegate?
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    var hasActivePresentation: Bool { activePresentation != nil }

    func presentCalendarEditor(_ controller: EKEventEditViewController) async throws -> AppleExternalReference {
        guard pending == nil, activePresentation == nil else {
            throw AppleSystemActionAdapterError.presentationInProgress(.calendar)
        }
        let presentationID = UUID()
        let delegate = CalendarEditorDelegate(presentationID: presentationID, broker: self)
        calendarDelegate = delegate
        controller.editViewDelegate = delegate
        return try await presentExternalEditor(
            id: presentationID,
            content: .calendarEditor(controller),
            capability: .calendar
        )
    }

    func presentContactEditor(_ controller: CNContactViewController) async throws -> AppleExternalReference {
        guard pending == nil, activePresentation == nil else {
            throw AppleSystemActionAdapterError.presentationInProgress(.contacts)
        }
        let presentationID = UUID()
        let delegate = ContactEditorDelegate(presentationID: presentationID, broker: self)
        contactDelegate = delegate
        controller.delegate = delegate
        return try await presentExternalEditor(
            id: presentationID,
            content: .contactEditor(controller),
            capability: .contacts
        )
    }

    func presentCapture(
        actionID: UUID,
        kind: SystemActionCaptureKind,
        suggestedTitle: String?,
        attachesToSource: Bool,
        sourceMemoID: UUID? = nil
    ) async throws -> SystemActionCaptureArtifact {
        let presentationID = UUID()
        let request = SystemActionCaptureUIRequest(
            presentationID: presentationID,
            actionID: actionID,
            kind: kind,
            suggestedTitle: suggestedTitle.map {
                AppleAdapterPrivacy.boundedPublicText($0, limit: 200)
            },
            attachesToSource: attachesToSource,
            sourceMemoID: sourceMemoID
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending == nil, activePresentation == nil else {
                    continuation.resume(
                        throwing: AppleSystemActionAdapterError.presentationInProgress(.capture)
                    )
                    return
                }
                pending = .capture(
                    id: presentationID,
                    capability: .capture,
                    continuation: continuation
                )
                activePresentation = .init(id: presentationID, content: .capture(request))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(presentationID: presentationID)
            }
        }
    }

    /// Completes the active capture. The app root must first persist the
    /// selected/scanned content inside DayPage's local container and pass only
    /// the relative path and bounded structural counts. Raw bytes, recognized
    /// text, file URLs, and absolute paths are intentionally not accepted.
    func completeCapture(
        presentationID: UUID,
        artifact: SystemActionCaptureArtifact
    ) {
        guard case .capture(let pendingID, _, let continuation) = pending,
              pendingID == presentationID else { return }
        do {
            try artifact.validateForLocalReceipt()
            clearPresentation()
            continuation.resume(returning: artifact)
        } catch {
            clearPresentation()
            continuation.resume(throwing: error)
        }
    }

    /// Cancels only the matching presentation. Stale sheet-dismiss callbacks
    /// therefore cannot cancel a newer request.
    func cancel(presentationID: UUID) {
        guard let pending, pending.id == presentationID else { return }
        clearPresentation()
        switch pending {
        case .external(_, let capability, let continuation):
            continuation.resume(throwing: AppleSystemActionAdapterError.userCancelled(capability))
        case .capture(_, let capability, let continuation):
            continuation.resume(throwing: AppleSystemActionAdapterError.userCancelled(capability))
        }
    }

    /// Call from root-level scene teardown. It is deliberately explicit so a
    /// background transition is not silently treated as a successful editor.
    func cancelActivePresentation() {
        guard let id = activePresentation?.id else { return }
        cancel(presentationID: id)
    }

    fileprivate func finishExternalEditor(
        presentationID: UUID,
        capability: AppleCapability,
        identifier: String?
    ) {
        guard case .external(let pendingID, let pendingCapability, let continuation) = pending,
              pendingID == presentationID,
              pendingCapability == capability else { return }
        clearPresentation()
        guard let identifier,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continuation.resume(throwing: AppleSystemActionAdapterError.ambiguousOutcome(capability))
            return
        }
        continuation.resume(returning: AppleExternalReference(identifier: identifier, createdAt: now()))
    }

    private func presentExternalEditor(
        id: UUID,
        content: SystemActionUIPresentation.Content,
        capability: AppleCapability
    ) async throws -> AppleExternalReference {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending == nil, activePresentation == nil else {
                    continuation.resume(
                        throwing: AppleSystemActionAdapterError.presentationInProgress(capability)
                    )
                    return
                }
                pending = .external(
                    id: id,
                    capability: capability,
                    continuation: continuation
                )
                activePresentation = .init(id: id, content: content)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(presentationID: id)
            }
        }
    }

    private func clearPresentation() {
        activePresentation = nil
        pending = nil
        calendarDelegate = nil
        contactDelegate = nil
    }
}

@MainActor
struct SystemActionUIPresentation: Identifiable {
    enum Content {
        case calendarEditor(EKEventEditViewController)
        case contactEditor(CNContactViewController)
        case capture(SystemActionCaptureUIRequest)
    }

    let id: UUID
    let content: Content
}

struct SystemActionCaptureUIRequest: Identifiable, Sendable, Equatable {
    var id: UUID { presentationID }
    let presentationID: UUID
    let actionID: UUID
    let kind: SystemActionCaptureKind
    let suggestedTitle: String?
    let attachesToSource: Bool
    let sourceMemoID: UUID?

    init(
        presentationID: UUID,
        actionID: UUID,
        kind: SystemActionCaptureKind,
        suggestedTitle: String?,
        attachesToSource: Bool,
        sourceMemoID: UUID? = nil
    ) {
        self.presentationID = presentationID
        self.actionID = actionID
        self.kind = kind
        self.suggestedTitle = suggestedTitle
        self.attachesToSource = attachesToSource
        self.sourceMemoID = sourceMemoID
    }
}

/// Structural metadata returned after a capture is durably stored locally.
/// There is intentionally no `Data`, recognized text, URL, or absolute path.
struct SystemActionCaptureArtifact: Sendable, Equatable {
    static let maximumByteCount = 100 * 1_024 * 1_024

    let kind: SystemActionCaptureKind
    let relativePath: String
    let uniformTypeIdentifier: String?
    let byteCount: Int?
    let pageCount: Int?
    let characterCount: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?

    init(
        kind: SystemActionCaptureKind,
        relativePath: String,
        uniformTypeIdentifier: String? = nil,
        byteCount: Int? = nil,
        pageCount: Int? = nil,
        characterCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    fileprivate func validateForLocalReceipt() throws {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 512,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw AppleSystemActionAdapterError.invalidPayload(field: "capture.relativePath")
        }
        if let uniformTypeIdentifier {
            guard !uniformTypeIdentifier.isEmpty, uniformTypeIdentifier.utf8.count <= 128 else {
                throw AppleSystemActionAdapterError.invalidPayload(field: "capture.contentType")
            }
        }
        if let byteCount, !(1...Self.maximumByteCount).contains(byteCount) {
            throw AppleSystemActionAdapterError.invalidPayload(field: "capture.byteCount")
        }
        if let pageCount, !(1...10_000).contains(pageCount) {
            throw AppleSystemActionAdapterError.invalidPayload(field: "capture.pageCount")
        }
        if let characterCount, !(0...10_000_000).contains(characterCount) {
            throw AppleSystemActionAdapterError.invalidPayload(field: "capture.characterCount")
        }
        if let pixelWidth, !(1...100_000).contains(pixelWidth) {
            throw AppleSystemActionAdapterError.invalidPayload(field: "capture.pixelWidth")
        }
        if let pixelHeight, !(1...100_000).contains(pixelHeight) {
            throw AppleSystemActionAdapterError.invalidPayload(field: "capture.pixelHeight")
        }
    }

    var boundedReceiptMetadata: [String: String] {
        var metadata = ["capture_kind": kind.rawValue]
        if let uniformTypeIdentifier {
            metadata["content_type"] = AppleAdapterPrivacy.boundedPublicText(
                uniformTypeIdentifier,
                limit: 128
            )
        }
        if let byteCount { metadata["byte_count"] = String(byteCount) }
        if let pageCount { metadata["page_count"] = String(pageCount) }
        if let characterCount { metadata["character_count"] = String(characterCount) }
        if let pixelWidth { metadata["pixel_width"] = String(pixelWidth) }
        if let pixelHeight { metadata["pixel_height"] = String(pixelHeight) }
        return metadata
    }

    var localReceiptMetadata: [String: String] {
        var metadata = boundedReceiptMetadata
        metadata["relative_path"] = relativePath
        return metadata
    }
}

@MainActor
private enum Pending {
    case external(
        id: UUID,
        capability: AppleCapability,
        continuation: CheckedContinuation<AppleExternalReference, Error>
    )
    case capture(
        id: UUID,
        capability: AppleCapability,
        continuation: CheckedContinuation<SystemActionCaptureArtifact, Error>
    )

    var id: UUID {
        switch self {
        case .external(let id, _, _), .capture(let id, _, _): return id
        }
    }
}

@MainActor
private final class CalendarEditorDelegate: NSObject, @preconcurrency EKEventEditViewDelegate {
    private let presentationID: UUID
    private weak var broker: SystemActionUIBroker?

    init(presentationID: UUID, broker: SystemActionUIBroker) {
        self.presentationID = presentationID
        self.broker = broker
    }

    func eventEditViewController(
        _ controller: EKEventEditViewController,
        didCompleteWith action: EKEventEditViewAction
    ) {
        switch action {
        case .saved:
            broker?.finishExternalEditor(
                presentationID: presentationID,
                capability: .calendar,
                identifier: controller.event?.eventIdentifier
            )
        case .canceled, .deleted:
            broker?.cancel(presentationID: presentationID)
        @unknown default:
            broker?.cancel(presentationID: presentationID)
        }
    }
}

@MainActor
private final class ContactEditorDelegate: NSObject, @preconcurrency CNContactViewControllerDelegate {
    private let presentationID: UUID
    private weak var broker: SystemActionUIBroker?

    init(presentationID: UUID, broker: SystemActionUIBroker) {
        self.presentationID = presentationID
        self.broker = broker
    }

    func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
        guard let contact else {
            broker?.cancel(presentationID: presentationID)
            return
        }
        broker?.finishExternalEditor(
            presentationID: presentationID,
            capability: .contacts,
            identifier: contact.identifier
        )
    }
}
