import Foundation
import UIKit
import WatchConnectivity
import CryptoKit
import DayPageModels
import DayPageStorage
import DayPageServices

// MARK: - WatchReceiveService

/// Receives audio files transferred from the DayPageWatch app on Apple Watch.
/// Moves received files into the DayPage vault (raw/assets/) for processing.
@MainActor
final class WatchReceiveService: NSObject, ObservableObject {

    struct DeliveryObligation: Codable, Equatable, Sendable {
        let version: Int
        let transferID: String
        let assetFileName: String
        let createdAt: Date
        let duration: Double?

        var audioPath: String { "raw/assets/\(assetFileName)" }
    }

    static let shared = WatchReceiveService()

    @Published var lastReceivedFile: URL?
    @Published var lastError: String?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(protectedDataBecameAvailable),
            name: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil
        )
        Task { @MainActor [weak self] in self?.retryPendingDeliveries() }
    }

    @objc private func protectedDataBecameAvailable() {
        retryPendingDeliveries()
    }

    private func retryPendingDeliveries() {
        do {
            try Self.recoverOrphanedAssets()
            for obligation in try Self.pendingObligations() {
                do {
                    let memo = try Self.materializeVoiceMemo(for: obligation)
                    if Self.needsTranscription(memo, audioPath: obligation.audioPath) {
                        try VoiceAttachmentQueue.shared.enqueueDurably(
                            audioPath: obligation.audioPath,
                            memoDate: obligation.createdAt
                        )
                    }
                    try Self.complete(obligation)
                    lastReceivedFile = Self.assetURL(for: obligation)
                } catch {
                    lastError = error.localizedDescription
                    DayPageLogger.log(
                        level: "ERROR",
                        message: "WatchReceiveService retained delivery obligation: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchReceiveService: WCSessionDelegate {

    // WCSessionDelegate callbacks arrive on an arbitrary background thread.
    // Mark each method nonisolated and hop back to MainActor only for @Published mutations.

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        if let error {
            DayPageLogger.log(level: "ERROR", message: "WatchReceiveService activation error: \(error.localizedDescription)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    /// Called when the iPhone receives a file transfer from the Watch.
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let sourceURL = file.fileURL
        let metadata = file.metadata ?? [:]

        guard let type = metadata["type"] as? String, type == "watchAudio" else {
            DayPageLogger.log(level: "WARN", message: "WatchReceiveService ignored file with type: \(metadata["type"] ?? "nil")")
            return
        }

        // Strip any path separators / ".." segments to prevent path traversal.
        let rawFilename = metadata["filename"] as? String ?? sourceURL.lastPathComponent
        let filename = (rawFilename as NSString).lastPathComponent

        // Content-bound transfer IDs make a lost delivery acknowledgement
        // safe: the same clip resolves to the same asset and memo on retry.
        do {
            let computedTransferID = try Self.fileSHA256(sourceURL)
            let suppliedTransferID = metadata["transfer_id"] as? String
            let transferID = suppliedTransferID?.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil ? suppliedTransferID! : computedTransferID
            guard transferID == computedTransferID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let assetsURL = try VaultInitializer.assetsDirectory()
            let fileExtension = (filename as NSString).pathExtension
            let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
            let destURL = assetsURL.appendingPathComponent("watch_\(transferID)\(suffix)")
            if FileManager.default.fileExists(atPath: destURL.path) {
                guard try Self.fileSHA256(destURL) == computedTransferID else {
                    throw CocoaError(.fileWriteFileExists)
                }
                // WCSession's received URL is an ephemeral duplicate. Never
                // overwrite the already referenced vault asset.
                try FileManager.default.removeItem(at: sourceURL)
            } else {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            }

            DayPageLogger.log(level: "INFO", message: "WatchReceiveService saved watch audio to: \(destURL.lastPathComponent)")

            // Vault-relative path: raw/assets/watch_<filename>
            let vaultRoot = VaultInitializer.vaultURL
            let audioPath = destURL.path.hasPrefix(vaultRoot.path)
                ? String(destURL.path.dropFirst(vaultRoot.path.count + 1))
                : "raw/assets/\(destURL.lastPathComponent)"

            // A single `now` shared by the memo's `created` date and the
            // transcription enqueue: `VoiceAttachmentQueue.applyTranscript`
            // resolves the day file from `memoDate`, and it must land on the
            // same day as the memo we append below or the transcript can never
            // match the attachment (att.file == audioPath) and would exhaust
            // retries into `.failed`.
            let now = (metadata["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
            let duration = metadata["duration"] as? Double

            let obligation = DeliveryObligation(
                version: 1,
                transferID: transferID,
                assetFileName: destURL.lastPathComponent,
                createdAt: now,
                duration: duration
            )

            // Persist a phone-owned delivery obligation before touching the
            // raw day file. WCSession may now delete the Watch source, while a
            // protected-data or disk failure remains recoverable on launch.
            try Self.persist(obligation)
            let memo = try Self.materializeVoiceMemo(for: obligation)

            Task { @MainActor in
                do {
                    if Self.needsTranscription(memo, audioPath: audioPath) {
                        try VoiceAttachmentQueue.shared.enqueueDurably(
                            audioPath: audioPath,
                            memoDate: now
                        )
                    }
                    try Self.complete(obligation)
                    self.lastReceivedFile = destURL
                } catch {
                    // The memo and queue entry are already idempotent. Retain
                    // the marker so a later retry can finish acknowledgement.
                    self.lastError = error.localizedDescription
                }
            }
        } catch {
            DayPageLogger.log(level: "ERROR", message: "WatchReceiveService failed to move file: \(error.localizedDescription)")
            Task { @MainActor in
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Build and persist the voice memo for a received watch audio clip.
    ///
    /// Mirrors the phone-side capture path (`TodayViewModel.submit` →
    /// `RawStorage.append`): a `.voice` memo carrying one `audio` attachment in
    /// the `.pending` transcription state, so the Today timeline shows a card
    /// immediately and `VoiceAttachmentQueue` can later patch the transcript
    /// onto the exact attachment whose `file` matches `audioPath`.
    ///
    /// `internal static` and returns the memo purely for test access — the
    /// production caller ignores the return value.
    @discardableResult
    nonisolated static func appendVoiceMemo(
        audioPath: String,
        duration: Double?,
        created: Date
    ) throws -> Memo {
        if let existing = try RawStorage.read(for: created).first(where: { memo in
            memo.attachments.contains(where: { $0.file == audioPath })
        }) {
            return existing
        }
        let attachment = Memo.Attachment(
            file: audioPath,
            kind: "audio",
            duration: duration,
            transcript: nil,
            transcriptionStatus: .pending
        )
        let memo = Memo(
            type: .voice,
            created: created,
            device: "Apple Watch",
            attachments: [attachment]
        )
        try RawStorage.append(memo)
        DayPageLogger.log(level: "INFO", message: "WatchReceiveService appended voice memo \(memo.id) to \(created)")
        return memo
    }

    @discardableResult
    nonisolated static func materializeVoiceMemo(
        for obligation: DeliveryObligation,
        append: (String, Double?, Date) throws -> Memo = appendVoiceMemo
    ) throws -> Memo {
        try validate(obligation)
        guard FileManager.default.fileExists(atPath: assetURL(for: obligation).path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try append(obligation.audioPath, obligation.duration, obligation.createdAt)
    }

    nonisolated static func needsTranscription(_ memo: Memo, audioPath: String) -> Bool {
        memo.attachments.contains { attachment in
            guard attachment.file == audioPath else { return false }
            return attachment.transcriptionStatus == nil
                || attachment.transcriptionStatus == .pending
        }
    }

    nonisolated static func persist(_ obligation: DeliveryObligation) throws {
        try validate(obligation)
        let directory = obligationDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(obligation).write(to: obligationURL(for: obligation), options: .atomic)
    }

    nonisolated static func complete(_ obligation: DeliveryObligation) throws {
        let source = obligationURL(for: obligation)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let directory = deliveredObligationDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    nonisolated static func pendingObligations() throws -> [DeliveryObligation] {
        try obligations(in: obligationDirectory())
    }

    private nonisolated static func deliveredObligations() throws -> [DeliveryObligation] {
        try obligations(in: deliveredObligationDirectory())
    }

    private nonisolated static func obligations(
        in directory: URL
    ) throws -> [DeliveryObligation] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { url in
            let obligation = try decoder.decode(DeliveryObligation.self, from: Data(contentsOf: url))
            try validate(obligation)
            guard url.deletingPathExtension().lastPathComponent == obligation.transferID else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return obligation
        }
    }

    /// If the app lost power after moving WCSession's ephemeral file but
    /// before the sidecar write completed, reconstruct the obligation from
    /// the content-addressed `watch_<sha256>` asset on the next launch.
    nonisolated static func recoverOrphanedAssets() throws {
        let assets = try VaultInitializer.assetsDirectory()
        let pending = try pendingObligations()
        let delivered = try deliveredObligations()
        let referenced = Set((pending + delivered).map(\.assetFileName))
        let files = try FileManager.default.contentsOfDirectory(
            at: assets,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        for url in files where url.lastPathComponent.hasPrefix("watch_")
            && !referenced.contains(url.lastPathComponent) {
            let stem = url.deletingPathExtension().lastPathComponent
            let transferID = String(stem.dropFirst("watch_".count))
            guard transferID.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                continue
            }
            // If a memo already durably references this asset, no recovery
            // marker is needed. Search the asset creation day first; the
            // normal sidecar path retains the precise Watch timestamp.
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if (try? RawStorage.read(for: createdAt).contains(where: {
                $0.attachments.contains(where: { $0.file == "raw/assets/\(url.lastPathComponent)" })
            })) == true {
                continue
            }
            try persist(.init(
                version: 1,
                transferID: transferID,
                assetFileName: url.lastPathComponent,
                createdAt: createdAt,
                duration: nil
            ))
        }
    }

    nonisolated static func assetURL(for obligation: DeliveryObligation) -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(obligation.assetFileName)
    }

    private nonisolated static func obligationDirectory() -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("watch-inbox", isDirectory: true)
    }

    private nonisolated static func deliveredObligationDirectory() -> URL {
        VaultInitializer.vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("watch-delivered", isDirectory: true)
    }

    private nonisolated static func obligationURL(for obligation: DeliveryObligation) -> URL {
        obligationDirectory().appendingPathComponent("\(obligation.transferID).json")
    }

    private nonisolated static func validate(_ obligation: DeliveryObligation) throws {
        guard obligation.version == 1,
              obligation.transferID.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              (obligation.assetFileName as NSString).lastPathComponent == obligation.assetFileName,
              obligation.assetFileName.hasPrefix("watch_\(obligation.transferID)"),
              obligation.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func fileSHA256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
