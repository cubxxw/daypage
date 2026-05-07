import UIKit

// MARK: - Haptic Tokens

enum Haptics {
    // Quiet confirmation for low-stakes taps (toggle, pin, navigate).
    static func tapConfirm() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    // Medium weight for commits that persist data (save, send, record).
    static func commit()     { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    // Warning pulse for destructive or irreversible actions.
    static func warn()       { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    // Success chime for completed async operations (compilation, upload).
    static func success()    { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
