import SwiftUI
import DayPageModels
import DayPageServices
import DayPageStorage

// MARK: - MacRootView

/// Top-level Mac layout: NavigationSplitView with a sidebar (Today / Archive)
/// + a content column. The two-column split is the macOS-native idiom; the
/// iOS sidebar drawer pattern would feel wrong with a mouse + keyboard.
struct MacRootView: View {

    @EnvironmentObject private var cloudAuth: MacCloudAuthService
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var syncQueue = SyncQueueService.shared

    enum Section: String, CaseIterable, Identifiable {
        case today
        case archive

        var id: String { rawValue }

        var label: String {
            switch self {
            case .today:   return "今天"
            case .archive: return "归档"
            }
        }

        var systemImage: String {
            switch self {
            case .today:   return "sun.max"
            case .archive: return "calendar"
            }
        }
    }

    @State private var selection: Section? = .today
    @State private var showingSignIn = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationTitle("DayPage")
            .frame(minWidth: 180)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarAccountButton
            }
        } detail: {
            switch selection {
            case .today, .none:
                MacTodayView()
            case .archive:
                MacArchiveView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Center-of-titlebar mini logo + dropdown affordance (visual
                // only for now — mirrors the flomo `≡ flomo ⌄` look).
                HStack(spacing: 6) {
                    Image(systemName: "sun.haze.fill")
                        .foregroundStyle(.secondary)
                    Text("DayPage").fontWeight(.semibold)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                syncStatus
            }
            ToolbarItem(placement: .primaryAction) {
                Text("⌘K")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                    .help("搜索（暂未启用）")
            }
        }
        .sheet(isPresented: $showingSignIn) {
            MacAuthView()
                .environmentObject(cloudAuth)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, cloudAuth.session != nil else { return }
            Task { await SyncQueueService.shared.flushIfOnline() }
        }
        .onOpenURL { url in
            guard NativeAuthFlow.isCallback(url, for: .macOS) else { return }
            showingSignIn = true
            Task { await cloudAuth.handleAuthCallback(url) }
        }
        .alert(
            "无法开启云同步",
            isPresented: Binding(
                get: { cloudAuth.syncErrorMessage != nil },
                set: { if !$0 { cloudAuth.dismissSyncError() } }
            )
        ) {
            Button("好", role: .cancel) { cloudAuth.dismissSyncError() }
        } message: {
            Text(cloudAuth.syncErrorMessage ?? "")
        }
    }

    private var sidebarAccountButton: some View {
        Button {
            showingSignIn = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cloudAuth.session == nil
                    ? "person.crop.circle.badge.plus"
                    : "person.crop.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(
                        cloudAuth.session == nil
                            ? Color(nsColor: .secondaryLabelColor)
                            : Color.orange
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(cloudAuth.accountLabel ?? "仅本机账户")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(cloudAuth.session == nil ? "登录并开启同步" : "账户与同步")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(.regularMaterial)
        .accessibilityLabel(cloudAuth.session == nil ? "仅本机账户，登录并开启同步" : "账户与同步")
    }

    @ViewBuilder
    private var syncStatus: some View {
        if syncQueue.isFlushingNow {
            Label("同步中", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else if cloudAuth.session == nil {
            Label(
                syncQueue.pendingCount == 0 ? "仅本地" : "本地已保存 · \(syncQueue.pendingCount) 条待登录",
                systemImage: "externaldrive"
            )
            .foregroundStyle(.secondary)
        } else if syncQueue.pendingCount > 0 {
            Button {
                cloudAuth.retrySync()
            } label: {
                Label("\(syncQueue.pendingCount) 条待同步", systemImage: "icloud.and.arrow.up")
            }
            .foregroundStyle(.orange)
        } else {
            Label("已同步", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        }
    }
}

// MARK: - Archive placeholder

/// Minimal archive list: every day file under vault/raw/, sorted descending.
struct MacArchiveView: View {

    @State private var dayFiles: [String] = []
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading) {
            if let err = loadError {
                Text(err).foregroundStyle(.secondary)
            } else if dayFiles.isEmpty {
                Text("vault/raw/ 还是空的。先去今天写一条 memo。")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List(dayFiles, id: \.self) { name in
                    Text(name)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .navigationTitle("归档")
        .frame(minWidth: 320)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let url = VaultInitializer.vaultURL.appendingPathComponent("raw", isDirectory: true)
        do {
            let names = try FileManager.default
                .contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .map { $0.lastPathComponent }
                .filter { $0.hasSuffix(".md") }
                .sorted(by: >)
            dayFiles = names
        } catch {
            loadError = "读取 vault/raw 失败：\(error.localizedDescription)"
        }
    }
}
