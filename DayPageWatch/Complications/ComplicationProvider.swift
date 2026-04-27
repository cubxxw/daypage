import WidgetKit
import ClockKit

// MARK: - DayPageComplicationTimelineProvider

/// Timeline provider for DayPage Watch complications.
/// Provides placeholder, template, and timeline entries.
struct DayPageComplicationTimelineProvider: TimelineProvider {

    typealias Entry = DayPageComplicationEntry

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), recordingActive: false, memoTally: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let entry = Entry(date: Date(), recordingActive: false, memoTally: 0)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entries = [
            Entry(date: Date(), recordingActive: false, memoTally: 0)
        ]
        let timeline = Timeline(entries: entries, policy: .never)
        completion(timeline)
    }
}

// MARK: - DayPageComplicationEntry

struct DayPageComplicationEntry: TimelineEntry {
    let date: Date
    let recordingActive: Bool
    let memoTally: Int
}

// MARK: - Complication Descriptors

/// 3 complication descriptors for different face locations.
struct DayPageComplicationConfigurator {

    /// Modular (rectangular) — shows recording state + memos
    static func modularDescriptor() -> CLKComplicationTemplate {
        let modular = CLKComplicationTemplateModularSmallStackText(
            line1TextProvider: CLKSimpleTextProvider(text: "DayPage"),
            line2TextProvider: CLKSimpleTextProvider(text: "Record")
        )
        return modular
    }

    /// Circular (watch face circular complication) — simple icon
    static func circularDescriptor() -> CLKComplicationTemplate {
        let circular = CLKComplicationTemplateCircularSmallSimpleText(
            textProvider: CLKSimpleTextProvider(text: "🎙")
        )
        return circular
    }

    /// Corner / Utilitarian — compact text
    static func utilitarianDescriptor() -> CLKComplicationTemplate {
        let utilitarian = CLKComplicationTemplateUtilitarianSmallFlat(
            textProvider: CLKSimpleTextProvider(text: "DayPage"),
            imageProvider: nil
        )
        return utilitarian
    }
}
