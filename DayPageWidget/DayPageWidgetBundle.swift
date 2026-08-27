import WidgetKit
import SwiftUI

// MARK: - DayPageWidgetBundle
//
// Single @main entry point for the Widget Extension. Bundles:
//   • QuickCaptureWidget — Home Screen / Lock Screen (iOS 16+)
//   • QuickCaptureControl — Control Center / Lock Screen (iOS 18+)
//
// Both widgets fire the same StartRecordingIntent which routes through
// the daypage://record URL scheme to wake the main app and open the
// voice recorder.

@main
struct DayPageWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 17.0, *) {
            QuickCaptureWidget()
        }
        SystemActionWidget()

        if #available(iOS 16.1, *) {
            FocusSessionLiveActivity()
        }

        if #available(iOS 18.0, *) {
            QuickCaptureControl()
            SystemActionControl()
            FocusSessionControl()
        }

        // 「记录提醒」的 AlarmKit 灵动岛/锁屏呈现(iOS 26+ 真灵动岛)。
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            CaptureReminderLiveActivity()
        }
        #endif
    }
}
