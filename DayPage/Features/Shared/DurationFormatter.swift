import Foundation
import DayPageModels

extension TimeInterval {
    var mmss: String {
        guard let safeDuration = MemoPresentationSafety.duration(self),
              let t = MemoPresentationSafety.roundedInt(safeDuration) else {
            return "00:00"
        }
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

extension Int {
    var mmss: String {
        String(format: "%02d:%02d", self / 60, self % 60)
    }
}
