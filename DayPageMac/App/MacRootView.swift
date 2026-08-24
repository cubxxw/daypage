import SwiftUI
import DayPageModels
import DayPageStorage

// MARK: - MacRootView

/// Top-level Mac layout: NavigationSplitView with a sidebar (Today / Archive)
/// + a content column. The two-column split is the macOS-native idiom; the
/// iOS sidebar drawer pattern would feel wrong with a mouse + keyboard.
struct MacRootView: View {

    @EnvironmentObject private var cloudAuth: MacCloudAuthService
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
                if cloudAuth.session == nil {
                    Button("登录同步") { showingSignIn = true }
                } else {
                    Menu {
                        if let account = cloudAuth.accountLabel {
                            Text(account)
                        }
                        Button("立即同步") { cloudAuth.retrySync() }
                        Divider()
                        Button("退出登录") { Task { await cloudAuth.signOut() } }
                    } label: {
                        Image(systemName: "person.crop.circle.fill")
                    }
                }
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
        .onAppear {
            if cloudAuth.session == nil { showingSignIn = true }
        }
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
