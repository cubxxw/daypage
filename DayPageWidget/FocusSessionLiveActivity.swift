import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct DayPageFocusActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let endsAt: Date
        let isPaused: Bool
        let remainingSeconds: Int?

        init(endsAt: Date, isPaused: Bool, remainingSeconds: Int? = nil) {
            self.endsAt = endsAt
            self.isPaused = isPaused
            self.remainingSeconds = remainingSeconds
        }
    }

    let actionID: UUID
    let boundedTitle: String
    let schedulesEndAlert: Bool?
}

@available(iOS 16.1, *)
struct FocusSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DayPageFocusActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "timer")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.boundedTitle)
                        .font(.headline)
                        .lineLimit(1)
                    focusTime(context.state)
                }
                Spacer()
                if #available(iOSApplicationExtension 17.0, *) {
                    focusButtons(actionID: context.attributes.actionID, state: context.state)
                } else {
                    Link(destination: URL(string: "daypage://actions?proposal=\(context.attributes.actionID.uuidString)")!) {
                        Image(systemName: "checkmark.shield")
                            .frame(width: 38, height: 38)
                            .background(.orange.opacity(0.16), in: Circle())
                    }
                }
            }
            .padding()
            .activityBackgroundTint(Color(UIColor.systemBackground))
            .activitySystemActionForegroundColor(.orange)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("DayPage", systemImage: "timer")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    focusTime(context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack {
                            Text(context.attributes.boundedTitle).lineLimit(1)
                            Spacer()
                            Link("检查", destination: URL(string: "daypage://actions?proposal=\(context.attributes.actionID.uuidString)")!)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        if #available(iOSApplicationExtension 17.0, *) {
                            focusButtons(actionID: context.attributes.actionID, state: context.state)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPaused ? "pause.fill" : "timer").foregroundStyle(.orange)
            } compactTrailing: {
                if context.state.isPaused {
                    Text("暂停").font(.caption2)
                } else {
                    Text(timerInterval: Date()...context.state.endsAt, countsDown: true)
                        .font(.caption2.monospacedDigit())
                        .frame(maxWidth: 42)
                }
            } minimal: {
                Image(systemName: "timer").foregroundStyle(.orange)
            }
            .widgetURL(URL(string: "daypage://actions?proposal=\(context.attributes.actionID.uuidString)"))
            .keylineTint(.orange)
        }
    }

    @ViewBuilder
    private func focusTime(_ state: DayPageFocusActivityAttributes.ContentState) -> some View {
        if state.isPaused {
            Label("已暂停 · \((state.remainingSeconds ?? 0) / 60) 分钟", systemImage: "pause.fill")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        } else {
            Text(timerInterval: Date()...state.endsAt, countsDown: true)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @available(iOSApplicationExtension 17.0, *)
    private func focusButtons(
        actionID: UUID,
        state: DayPageFocusActivityAttributes.ContentState
    ) -> some View {
        HStack(spacing: 10) {
            Button(intent: SetFocusSessionPausedIntent(
                actionID: actionID.uuidString,
                shouldPause: !state.isPaused
            )) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 36, height: 32)
            }
            .tint(.orange)
            Button(intent: EndFocusSessionIntent(actionID: actionID.uuidString)) {
                Image(systemName: "stop.fill").frame(width: 36, height: 32)
            }
            .tint(.red)
        }
        .buttonStyle(.bordered)
    }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct SetFocusSessionPausedIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暂停或继续专注"
    static let openAppWhenRun = true

    @Parameter(title: "动作 ID") var actionID: String
    @Parameter(title: "暂停") var shouldPause: Bool

    init() {}
    init(actionID: String, shouldPause: Bool) {
        self.actionID = actionID
        self.shouldPause = shouldPause
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: actionID),
              let activity = Activity<DayPageFocusActivityAttributes>.activities.first(where: {
                  $0.attributes.actionID == id
              }) else { return .result() }
        let now = Date()
        if shouldPause {
            let remaining = max(0, Int(activity.contentState.endsAt.timeIntervalSince(now).rounded(.up)))
            await activity.update(using: .init(
                endsAt: activity.contentState.endsAt,
                isPaused: true,
                remainingSeconds: remaining
            ))
            SystemActionSharedSummaryStore.requestFocusControl(
                actionID: id,
                operation: .pause,
                remainingSeconds: remaining
            )
        } else {
            let remaining = max(1, activity.contentState.remainingSeconds ?? 1)
            await activity.update(using: .init(
                endsAt: now.addingTimeInterval(TimeInterval(remaining)),
                isPaused: false,
                remainingSeconds: nil
            ))
            SystemActionSharedSummaryStore.requestFocusControl(
                actionID: id,
                operation: .resume,
                remainingSeconds: remaining
            )
        }
        return .result()
    }
}

@available(iOS 17.0, iOSApplicationExtension 17.0, *)
struct EndFocusSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "结束专注"
    static let openAppWhenRun = true

    @Parameter(title: "动作 ID") var actionID: String

    init() {}
    init(actionID: String) { self.actionID = actionID }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: actionID),
              let activity = Activity<DayPageFocusActivityAttributes>.activities.first(where: {
                  $0.attributes.actionID == id
              }) else { return .result() }
        await activity.end(dismissalPolicy: .immediate)
        SystemActionSharedSummaryStore.requestFocusControl(actionID: id, operation: .end)
        return .result()
    }
}
