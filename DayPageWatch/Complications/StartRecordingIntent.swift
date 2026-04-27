import AppIntents
import AVFoundation
import WatchKit

// MARK: - StartRecordingIntent

/// App Intent triggered by the Watch Action Button to start a recording.
/// Uses a minimal AVAudioRecorder for quick-start recording without UI.
@available(watchOS 9.0, *)
struct StartRecordingIntent: AppIntent {

    static let title: LocalizedStringResource = "Start DayPage Recording"
    static let description: LocalizedStringResource = "Quickly start a voice recording from the Action button"

    static var supportedActionButtonSets: [ActionButtonSet] {
        [.system]
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            return .result(dialog: "Audio session error")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.daypage.watch", isDirectory: true)
            .appendingPathComponent("action_\(Date().timeIntervalSince1970).m4a")

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()

        // Record for 30 seconds then auto-stop
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            recorder.stop()
            // Transfer via WCSession
            WatchTransferService.shared.transferAudioFile(url) { _ in }
            try? AVAudioSession.sharedInstance().setActive(false)
        }

        return .result(dialog: "Recording started")
    }
}
