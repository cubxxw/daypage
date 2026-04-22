import SwiftUI
import UIKit

// MARK: - InputTokens
//
// Centralized thresholds and haptic intensities for the press-to-talk
// interaction (US-008). Keeping them here lets the overlay view, gesture
// handler and any future tuning surface consume the same constants.

enum InputTokens {

    // MARK: - Press-to-Talk Gesture

    /// Minimum vertical upward swipe (in points) that arms the "cancel" state.
    /// Lowered from 80pt → 60pt: usability testing shows 80pt requires an awkward
    /// thumb extension on most phones; 60pt is comfortable while preventing accidental triggers.
    static let cancelSwipeThreshold: CGFloat = 60

    /// Minimum leftward swipe (in points) that arms the "transcribe only" state.
    /// Lowered from 80pt → 60pt to match cancelSwipeThreshold.
    static let transcribeSwipeThreshold: CGFloat = 60

    // MARK: - Haptic Intensities

    /// Fired on press-down (recording begins).
    static let pressDownHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .light

    /// Fired on in-place release (send immediately).
    static let sendReleaseHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .medium

    /// Fired when the drag enters cancel-armed zone.
    static let cancelArmHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .heavy

    /// Fired when the drag enters transcribe-armed zone.
    static let transcribeArmHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .medium

    /// Fired when a cancel-armed gesture is released (recording discarded).
    static let cancelReleaseHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .light

    /// Fired when a transcribe-armed gesture is released (text filled, not sent).
    static let transcribeReleaseHaptic: UIImpactFeedbackGenerator.FeedbackStyle = .medium
}
