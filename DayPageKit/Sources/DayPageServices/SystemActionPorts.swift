import Foundation
import DayPageModels

/// Thin framework-neutral port implemented by one native Apple adapter per
/// action kind. Implementations request permission only inside a confirmed
/// user execution and return only bounded receipt metadata.
public protocol SystemActionNativeAdapter: Sendable {
    var kind: SystemActionKind { get }
    var rollbackCapability: SystemActionRollbackCapability { get }

    func capabilitySnapshot() async -> SystemActionCapabilitySnapshot

    func execute(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext
    ) async throws -> SystemActionAdapterResult

    func reconcile(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionReconciliationResult

    func undo(
        proposal: SystemActionProposal,
        originalReceipt: SystemActionReceipt,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionAdapterResult
}

public extension SystemActionNativeAdapter {
    func reconcile(
        proposal: SystemActionProposal,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionReconciliationResult {
        SystemActionReconciliationResult(
            disposition: .needsReview,
            errorCode: "reconciliation_not_supported"
        )
    }

    func undo(
        proposal: SystemActionProposal,
        originalReceipt: SystemActionReceipt,
        context: SystemActionExecutionContext,
        material: SystemActionLocalMaterial?
    ) async throws -> SystemActionAdapterResult {
        SystemActionAdapterResult(
            outcome: .unsupported,
            errorCode: "undo_not_supported",
            reconciliationState: .needsReview
        )
    }
}

/// Stable error-code mapping prevents native error descriptions (which may
/// contain user content or external identifiers) from reaching receipts.
public protocol SystemActionErrorCodeMapping: Sendable {
    func boundedCode(for error: Error) -> String
}

public struct DefaultSystemActionErrorCodeMapper: SystemActionErrorCodeMapping {
    public init() {}

    public func boundedCode(for error: Error) -> String {
        if let error = error as? SystemActionCodedError {
            let code = Self.contractCode(error.systemActionErrorCode)
            if !code.isEmpty { return code }
        }
        return "native_adapter_error"
    }

    private static func contractCode(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 45, 46, 48...57, 95, 97...122: return Character(String(scalar))
            default: return "_"
            }
        }
        return String(String(scalars).prefix(80))
    }
}

public protocol SystemActionCodedError: Error {
    var systemActionErrorCode: String { get }
}

/// Native adapters use this marker when the framework may have changed state
/// but cannot prove the final result. The coordinator must persist this as
/// needs-review evidence rather than flattening it into an ordinary failure.
public protocol SystemActionAmbiguousError: Error {
    var isSystemActionAmbiguous: Bool { get }
}
