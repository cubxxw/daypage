import SwiftUI
import QuickLook
import CoreLocation
import UIKit
import DayPageModels
import DayPageServices

struct SystemActionPresentationHost: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SystemActionCenterModel
    let presentation: SystemActionPresentation

    var body: some View {
        switch presentation {
        case .center(let selectedProposalID):
            SystemActionCenterView(model: model, selectedProposalID: selectedProposalID)
        case .draft(let seed):
            seedHost { try model.makeSeedProposal(seed) }
        case .focus(let seed):
            seedHost { try model.makeFocusProposal(seed) }
        case .moment:
            SystemActionMomentComposerView(model: model)
        case .capture:
            seedHost {
                try model.makeSeedProposal(.init(kind: "capture", title: "采集内容", notes: nil))
            }
        }
    }

    @ViewBuilder
    private func seedHost(makeProposal: () throws -> SystemActionProposal) -> some View {
        if let proposal = try? makeProposal() {
            SystemActionReviewView(model: model, proposal: proposal, isNew: true) {
                dismiss()
            }
        } else {
            NavigationStack {
                SystemActionEmptyState(
                    title: "无法创建动作草稿",
                    systemImage: "exclamationmark.triangle",
                    detail: "输入不完整或动作类型不受此版本支持。"
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
            }
            .tint(DSColor.accentOnBg)
        }
    }
}

private enum SystemActionCenterTab: String, CaseIterable {
    case pending = "待审批"
    case today = "今天"
    case automations = "自动化"
    case receipts = "回执"
}

struct SystemActionCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: SystemActionCenterModel
    @StateObject private var passiveLocation = PassiveLocationService.shared
    let selectedProposalID: UUID?

    @State private var selectedTab: SystemActionCenterTab = .pending
    @State private var selectedProposal: SystemActionProposal?
    @State private var showAccess = false
    @State private var showContextComposer = false
    @State private var showMomentComposer = false
    @State private var showCaptureInbox = false
    @State private var pendingSelectedProposalID: UUID?

    init(model: SystemActionCenterModel, selectedProposalID: UUID?) {
        self.model = model
        self.selectedProposalID = selectedProposalID
        _pendingSelectedProposalID = State(initialValue: selectedProposalID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                trustHeader
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        Picker("动作中心", selection: $selectedTab) {
                            ForEach(SystemActionCenterTab.allCases, id: \.self) { tab in
                                Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel(Text("动作中心"))
                    } else {
                        Picker("动作中心", selection: $selectedTab) {
                            ForEach(SystemActionCenterTab.allCases, id: \.self) { tab in
                                Text(LocalizedStringKey(tab.rawValue)).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, DSSpacing.lg)
                .padding(.bottom, DSSpacing.md)

                Group {
                    if model.isRefreshing && model.snapshot == nil {
                        ProgressView("正在读取本地动作账本…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch selectedTab {
                        case .pending: reviewList
                        case .today: todayList
                        case .automations: automationList
                        case .receipts: receiptList
                        }
                    }
                }
            }
            .background(DSColor.bgWarm.ignoresSafeArea())
            .navigationTitle("动作中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showAccess = true
                    } label: {
                        Image(systemName: "hand.raised")
                    }
                    .accessibilityLabel("系统访问")

                    Menu {
                        Button("新建 Moment", systemImage: "sparkles.rectangle.stack") {
                            showMomentComposer = true
                        }
                        Button("采集文档或手写", systemImage: "viewfinder") {
                            pendingSelectedProposalID = nil
                            selectedProposal = try? model.makeSeedProposal(.init(kind: "capture", title: "采集内容", notes: nil))
                        }
                        Button("打开采集收件箱", systemImage: "tray.full") {
                            showCaptureInbox = true
                        }
                        Button("准备专注", systemImage: "timer") {
                            pendingSelectedProposalID = nil
                            selectedProposal = try? model.makeFocusProposal(.init(title: "专注", durationSeconds: 1_500))
                        }
                        Button("添加本地上下文", systemImage: "sensor") {
                            showContextComposer = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建动作提案")
                }
            }
            .task {
                await model.refresh(syncRemote: true)
                resolvePendingSelection()
            }
            .onChange(of: model.isCapabilityOffered(.location)) { isOffered in
                if !isOffered {
                    passiveLocation.setVisitAutomationEnabled(false)
                }
            }
            .onChange(of: model.proposals.map(\.id)) { _ in resolvePendingSelection() }
            .refreshable { await model.refresh(syncRemote: true) }
            .sheet(item: $selectedProposal) { proposal in
                SystemActionReviewView(
                    model: model,
                    proposal: proposal,
                    isNew: !model.proposals.contains(where: { $0.id == proposal.id })
                ) {
                    selectedProposal = nil
                }
            }
            .sheet(isPresented: $showAccess) {
                SystemAccessView(model: model)
            }
            .sheet(isPresented: $showContextComposer) {
                SystemActionContextComposerView(model: model)
            }
            .sheet(isPresented: $showMomentComposer) {
                SystemActionMomentComposerView(model: model)
            }
            .sheet(isPresented: $showCaptureInbox) {
                SystemActionCaptureInboxView()
            }
            .alert(
                "动作未完成",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
        .tint(DSColor.accentOnBg)
    }

    @ViewBuilder
    private var todayList: some View {
        let proposals = model.proposals(on: Date()).sorted { $0.createdAt > $1.createdAt }
        let receipts = model.receipts(on: Date()).sorted { $0.completedAt > $1.completedAt }
        if proposals.isEmpty && receipts.isEmpty {
            SystemActionEmptyState(
                title: "今天还没有系统动作",
                systemImage: "sun.max",
                detail: "今天产生的提案与执行结果会按时间汇总在这里。"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DSSpacing.md) {
                    if !proposals.isEmpty {
                        Text("今天的提案")
                            .font(DSType.titleSM)
                            .foregroundColor(DSColor.inkPrimary)
                        ForEach(proposals) { proposal in
                            SystemActionProposalCard(
                                proposal: proposal,
                                receipt: model.latestReceipt(for: proposal),
                                isWorking: model.activeOperationID == proposal.id
                            ) {
                                pendingSelectedProposalID = nil
                                selectedProposal = proposal
                            }
                        }
                    }
                    if !receipts.isEmpty {
                        Text("今天的回执")
                            .font(DSType.titleSM)
                            .foregroundColor(DSColor.inkPrimary)
                            .padding(.top, proposals.isEmpty ? 0 : DSSpacing.sm)
                        ForEach(receipts) { receipt in
                            Button {
                                pendingSelectedProposalID = nil
                                selectedProposal = model.proposals.first { $0.id == receipt.proposalID }
                            } label: {
                                SystemActionReceiptRow(
                                    receipt: receipt,
                                    proposal: model.proposals.first { $0.id == receipt.proposalID }
                                )
                                .padding(DSSpacing.md)
                                .background(
                                    DSColor.surfaceWhite,
                                    in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(DSSpacing.lg)
            }
        }
    }

    private var automationList: some View {
        List {
            Section {
                Label("所有自动入口仍只生成提案；不会绕过逐次审批。", systemImage: "checkmark.shield")
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                Button {
                    showAccess = true
                } label: {
                    Label("管理系统访问与云端披露", systemImage: "hand.raised")
                }
                Button {
                    showCaptureInbox = true
                } label: {
                    Label("打开可恢复的采集收件箱", systemImage: "tray.full")
                }
            } header: {
                Text("安全边界")
            }

            Section("能力策略") {
                ForEach(SystemActionCapability.productCapabilities, id: \.rawValue) { capability in
                    HStack(spacing: DSSpacing.md) {
                        Image(systemName: capability.systemImage)
                            .foregroundColor(model.isCapabilityOffered(capability) ? DSColor.accentOnBg : DSColor.inkSubtle)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(capability.displayName).font(DSType.bodyMD)
                            Text(model.isCapabilityOffered(capability)
                                 ? model.disclosureLevel(for: capability).displayName
                                 : NSLocalizedString("已关闭", comment: ""))
                                .font(DSType.labelSM)
                                .foregroundColor(DSColor.inkMuted)
                        }
                        Spacer()
                        Image(systemName: model.isCapabilityOffered(capability) ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundColor(model.isCapabilityOffered(capability) ? .green : .secondary)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { passiveLocation.automationEnabled },
                    set: { passiveLocation.setVisitAutomationEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("到访建议")
                        Text("明确开启后才请求“始终”定位；停留记录仍需逐条确认。")
                            .font(DSType.labelSM)
                            .foregroundColor(DSColor.inkMuted)
                    }
                }
                .disabled(!model.isCapabilityOffered(.location))

                LabeledContent("定位状态", value: visitAuthorizationSummary)
                if passiveLocation.automationEnabled,
                   passiveLocation.authorizationStatus == .denied {
                    Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
                LabeledContent("专注入口", value: model.isCapabilityOffered(.focus) ? "可从 App Intent / 控件发起" : "关闭")
            } header: {
                Text("系统入口")
            } footer: {
                Text("后台信号只生成有限证据和待审批提案；执行仍需要当前修订与内容指纹的明确批准。")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var visitAuthorizationSummary: String {
        guard model.isCapabilityOffered(.location) else {
            return NSLocalizedString("已由能力策略关闭", comment: "")
        }
        switch passiveLocation.authorizationStatus {
        case .authorizedAlways:
            return passiveLocation.automationEnabled
                ? NSLocalizedString("始终授权 · 正在监测", comment: "")
                : NSLocalizedString("始终授权 · 自动化关闭", comment: "")
        case .authorizedWhenInUse:
            return NSLocalizedString("仅使用期间；开启时请求升级", comment: "")
        case .denied:
            return NSLocalizedString("已拒绝；可在系统设置中更改", comment: "")
        case .restricted:
            return NSLocalizedString("受系统限制", comment: "")
        case .notDetermined:
            return NSLocalizedString("尚未请求", comment: "")
        @unknown default:
            return NSLocalizedString("不可用", comment: "")
        }
    }

    private var trustHeader: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(DSColor.accentOnBg)
                .frame(width: 44, height: 44)
                .background(DSColor.amberSoft, in: RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("先看清，再执行")
                    .font(DSType.titleSM)
                    .foregroundColor(DSColor.inkPrimary)
                Text("Agent 只能提交提案。每次批准绑定当前修订与内容哈希；修改后必须重新批准。")
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DSSpacing.lg)
        .background(DSColor.surfaceWhite)
        .overlay(alignment: .bottom) { Rectangle().fill(DSColor.borderSubtle).frame(height: 0.5) }
    }

    @ViewBuilder
    private var reviewList: some View {
        if model.pendingProposals.isEmpty {
            SystemActionEmptyState(
                title: "没有待处理动作",
                systemImage: "checkmark.shield",
                detail: "日历、提醒、联系人等建议会先出现在这里。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: DSSpacing.md) {
                    ForEach(model.pendingProposals) { proposal in
                        SystemActionProposalCard(
                            proposal: proposal,
                            receipt: model.latestReceipt(for: proposal),
                            isWorking: model.activeOperationID == proposal.id
                        ) {
                            pendingSelectedProposalID = nil
                            selectedProposal = proposal
                        }
                    }
                }
                .padding(DSSpacing.lg)
            }
        }
    }

    @ViewBuilder
    private var receiptList: some View {
        if model.receipts.isEmpty {
            SystemActionEmptyState(
                title: "还没有执行回执",
                systemImage: "doc.text.magnifyingglass",
                detail: "成功、失败、撤销与需要人工确认的结果都会留在本地账本。"
            )
        } else {
            List {
                ForEach(model.receipts.sorted(by: { $0.completedAt > $1.completedAt })) { receipt in
                    Button {
                        pendingSelectedProposalID = nil
                        selectedProposal = model.proposals.first { $0.id == receipt.proposalID }
                    } label: {
                        SystemActionReceiptRow(
                            receipt: receipt,
                            proposal: model.proposals.first { $0.id == receipt.proposalID }
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(DSColor.surfaceWhite)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func resolvePendingSelection() {
        guard selectedProposal == nil,
              let proposalID = pendingSelectedProposalID,
              let proposal = model.proposals.first(where: { $0.id == proposalID }) else {
            return
        }
        pendingSelectedProposalID = nil
        selectedProposal = proposal
    }
}

private struct SystemActionCaptureInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [SystemActionCaptureInboxRecord] = []
    @State private var previewURL: URL?
    @State private var activeRecordID: UUID?
    @State private var recordToDiscard: SystemActionCaptureInboxRecord?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    SystemActionEmptyState(
                        title: "采集收件箱为空",
                        systemImage: "tray",
                        detail: "完成文档、照片、手写、文件或语音采集后，会先安全暂存在这里。"
                    )
                } else {
                    List(records) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(record.suggestedTitle ?? record.kind.displayName, systemImage: "doc")
                                    .font(DSType.bodyMD.weight(.semibold))
                                Spacer()
                                if activeRecordID == record.id { ProgressView().controlSize(.small) }
                            }
                            Text("\(record.kind.displayName) · \(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file)) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(DSType.labelSM)
                                .foregroundColor(DSColor.inkMuted)
                            Text(record.attachesToSource ? "原意图：附加到来源；当前安全暂存，等待您明确归档。" : "原意图：新建 memo；当前安全暂存，等待您明确归档。")
                                .font(DSType.labelSM)
                                .foregroundColor(DSColor.inkMuted)
                            if let memoID = record.filedMemoID {
                                Label(
                                    record.filedDestination == .sourceMemo
                                        ? "已附加到来源 memo …\(memoID.uuidString.suffix(8))"
                                        : "已归档为新 memo …\(memoID.uuidString.suffix(8))",
                                    systemImage: "checkmark.circle.fill"
                                )
                                    .font(DSType.labelSM)
                                    .foregroundColor(.green)
                                Button("删除收件箱副本", systemImage: "trash", role: .destructive) {
                                    recordToDiscard = record
                                }
                                .buttonStyle(.bordered)
                                .disabled(activeRecordID != nil)
                            } else {
                                ViewThatFits(in: .horizontal) {
                                    HStack { recordButtons(record) }
                                    VStack { recordButtons(record) }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(DSColor.bgWarm)
            .navigationTitle("采集收件箱")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await reload() }
            .quickLookPreview($previewURL)
            .alert("采集收件箱", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog(
                "删除这份暂存？",
                isPresented: Binding(
                    get: { recordToDiscard != nil },
                    set: { if !$0 { recordToDiscard = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除暂存", role: .destructive) {
                    guard let record = recordToDiscard else { return }
                    recordToDiscard = nil
                    Task { await discard(record) }
                }
                Button("取消", role: .cancel) { recordToDiscard = nil }
            } message: {
                Text("此操作不能撤销。若已归档为 memo，Vault 中的 memo 与附件不会被删除。")
            }
        }
        .tint(DSColor.accentOnBg)
    }

    @ViewBuilder
    private func recordButtons(_ record: SystemActionCaptureInboxRecord) -> some View {
        Button("预览", systemImage: "eye") {
            Task { previewURL = await SystemActionCaptureStore.shared.fileURL(for: record) }
        }
        .buttonStyle(.bordered)
        if record.attachesToSource, record.sourceMemoID != nil {
            Button("附加到来源 memo", systemImage: "paperclip") {
                Task { await fileToSourceMemo(record) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(activeRecordID != nil)
        }
        Button("保存为新 memo", systemImage: "square.and.pencil") {
            Task { await fileAsMemo(record) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(activeRecordID != nil)
        Button("删除暂存", systemImage: "trash", role: .destructive) {
            recordToDiscard = record
        }
        .buttonStyle(.bordered)
        .disabled(activeRecordID != nil)
    }

    @MainActor
    private func reload() async {
        records = await SystemActionCaptureStore.shared.recent()
    }

    @MainActor
    private func fileAsMemo(_ record: SystemActionCaptureInboxRecord) async {
        guard activeRecordID == nil else { return }
        activeRecordID = record.id
        do {
            let memoID = try await SystemActionCaptureStore.shared.fileAsNewMemo(id: record.id)
            message = "已由您明确归档为 memo …\(memoID.uuidString.suffix(8))。"
            await reload()
        } catch {
            message = String(error.localizedDescription.prefix(240))
        }
        activeRecordID = nil
    }

    @MainActor
    private func fileToSourceMemo(_ record: SystemActionCaptureInboxRecord) async {
        guard activeRecordID == nil else { return }
        activeRecordID = record.id
        do {
            let memoID = try await SystemActionCaptureStore.shared.fileToSourceMemo(id: record.id)
            message = "已由您明确附加到来源 memo …\(memoID.uuidString.suffix(8))。"
            await reload()
        } catch {
            message = String(error.localizedDescription.prefix(240))
        }
        activeRecordID = nil
    }

    @MainActor
    private func discard(_ record: SystemActionCaptureInboxRecord) async {
        guard activeRecordID == nil else { return }
        activeRecordID = record.id
        do {
            try await SystemActionCaptureStore.shared.discard(id: record.id)
            message = "暂存已删除。"
            await reload()
        } catch {
            message = String(error.localizedDescription.prefix(240))
        }
        activeRecordID = nil
    }
}

private struct SystemActionProposalCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let proposal: SystemActionProposal
    let receipt: SystemActionReceipt?
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                proposalHeader

                Text(proposal.rationale.isEmpty
                    ? NSLocalizedString("未提供建议原因", comment: "")
                    : proposal.rationale)
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.inkMuted)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Label("R\(proposal.revision)", systemImage: "arrow.triangle.2.circlepath")
                    Text(String(proposal.payloadHash.prefix(10)))
                    Spacer()
                    if receipt?.outcome == .ambiguous {
                        Label("需要确认", systemImage: "questionmark.diamond")
                    } else {
                        Image(systemName: "chevron.right")
                    }
                }
                .font(DSType.mono9)
                .foregroundColor(DSColor.inkMuted)
            }
            .padding(DSSpacing.lg)
            .background(DSColor.surfaceWhite, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                    .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("system-action.proposal.\(proposal.id.uuidString)")
    }

    @ViewBuilder
    private var proposalHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                proposalIdentity
                proposalStatus
            }
        } else {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                proposalIdentity
                Spacer(minLength: 8)
                proposalStatus
            }
        }
    }

    private var proposalIdentity: some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: proposal.kind.systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DSColor.accentOnBg)
                .frame(width: 44, height: 44)
                .background(DSColor.amberSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(proposal.title)
                    .font(DSType.titleSM)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                Text(proposal.kind.displayName)
                    .font(DSType.mono9)
                    .tracking(1.0)
                    .foregroundColor(DSColor.inkMuted)
            }
        }
    }

    @ViewBuilder
    private var proposalStatus: some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else {
            Text(proposal.lifecycleState.displayName)
                .font(DSType.mono9)
                .foregroundColor(proposal.lifecycleState.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(proposal.lifecycleState.tint.opacity(0.1), in: Capsule())
        }
    }
}

private struct SystemActionReceiptRow: View {
    let receipt: SystemActionReceipt
    let proposal: SystemActionProposal?

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: receipt.outcome.systemImage)
                .foregroundColor(receipt.outcome.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(proposal?.title ?? NSLocalizedString("系统动作", comment: ""))
                    .font(DSType.bodyMD)
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                Text(receiptSummary)
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                Text(executorSummary)
                    .font(DSType.mono9)
                    .foregroundColor(DSColor.inkSubtle)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(DSType.caption)
                .foregroundColor(DSColor.inkSubtle)
        }
        .contentShape(Rectangle())
    }

    private var receiptSummary: String {
        String.localizedStringWithFormat(
            NSLocalizedString("system_action.receipt.summary", value: "%1$@ · %2$@ · %3$@", comment: ""),
            receipt.phase == .undo ? NSLocalizedString("撤销", comment: "") : NSLocalizedString("执行", comment: ""),
            receipt.outcome.displayName,
            receipt.completedAt.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private var executorSummary: String {
        let identifier = String(receipt.deviceID.suffix(8))
        let mode = receipt.executionMode == .onlineLease
            ? NSLocalizedString("云端租约", comment: "")
            : NSLocalizedString("本机所有者", comment: "")
        return String.localizedStringWithFormat(
            NSLocalizedString("system_action.receipt.executor", value: "执行设备 …%@ · %@", comment: ""),
            identifier,
            mode
        )
    }
}

/// In-context approval surface for Today. It exposes the same exact
/// revision/hash and executable fields as the full review sheet, so this
/// compact presentation is not a weaker approval path.
struct SystemActionTodayProposalCard: View {
    @ObservedObject var model: SystemActionCenterModel
    let proposal: SystemActionProposal
    let openReview: () -> Void

    @State private var showRejectConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                Image(systemName: proposal.kind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DSColor.accentOnBg)
                    .frame(width: 40, height: 40)
                    .background(DSColor.amberSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.title)
                        .font(DSType.titleSM)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineLimit(2)
                    Text("\(proposal.kind.displayName) · R\(proposal.revision) · \(proposal.payloadHash.prefix(10))")
                        .font(DSType.mono9)
                        .foregroundColor(DSColor.inkMuted)
                }
                Spacer(minLength: 4)
                if model.activeOperationID == proposal.id {
                    ProgressView().controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Label(provenanceSummary, systemImage: "quote.bubble")
                ForEach(SystemActionProposalPreview.lines(for: proposal).prefix(4), id: \.self) { line in
                    Text(line)
                }
            }
            .font(DSType.labelSM)
            .foregroundColor(DSColor.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)

            Label(model.disclosureSummary(for: proposal), systemImage: "lock.shield")
                .font(DSType.labelSM)
                .foregroundColor(DSColor.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DSSpacing.sm) { actionButtons }
                VStack(spacing: DSSpacing.sm) { actionButtons }
            }
        }
        .padding(DSSpacing.lg)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
                .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 16, y: 7)
        .confirmationDialog("拒绝这个提案？", isPresented: $showRejectConfirmation) {
            Button("拒绝", role: .destructive) {
                Task { _ = await model.reject(proposal) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("不会调用任何 Apple Framework；拒绝决定会留在本地账本。")
        }
        .accessibilityIdentifier("system-action.today-card")
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("确认并执行", systemImage: "checkmark.shield.fill") {
            Task { _ = await model.approve(proposal, executeImmediately: true) }
        }
        .buttonStyle(.borderedProminent)
        .tint(DSColor.accentOnBg)
        .disabled(model.activeOperationID != nil)

        Button("编辑 / 详情", systemImage: "slider.horizontal.3", action: openReview)
            .buttonStyle(.bordered)
            .disabled(model.activeOperationID != nil)

        Button("拒绝", systemImage: "xmark", role: .destructive) {
            showRejectConfirmation = true
        }
        .buttonStyle(.bordered)
        .disabled(model.activeOperationID != nil)
    }

    private var provenanceSummary: String {
        let source = proposal.sourceReferences.first.map {
            "\($0.kind.displayName): \($0.identifier)"
        } ?? NSLocalizedString("无外部引用", comment: "")
        return "\(proposal.creatorSource.displayName) · \(source) · \(proposal.rationale)"
    }
}

enum SystemActionProposalPreview {
    static func lines(for proposal: SystemActionProposal) -> [String] {
        switch proposal.payload {
        case .calendarEvent(let value):
            return compact([
                localized("system_action.preview.start", "开始：%@", date(value.startAt)),
                localized(
                    "system_action.preview.end",
                    "结束：%@ · %@",
                    date(value.endAt),
                    value.isAllDay ? NSLocalizedString("全天", comment: "") : NSLocalizedString("非全天", comment: "")
                ),
                value.location.flatMap(location).map {
                    localized("system_action.preview.location", "地点：%@", $0)
                },
                value.notes.map { localized("system_action.preview.notes", "备注：%@", $0) },
            ])
        case .reminder(let value):
            return compact([
                localized(
                    "system_action.preview.due",
                    "到期：%@",
                    value.dueAt.map(date) ?? NSLocalizedString("无", comment: "")
                ),
                localized(
                    "system_action.preview.priority",
                    "优先级：%@",
                    value.priority.map(String.init) ?? NSLocalizedString("无", comment: "")
                ),
                value.notes.map { localized("system_action.preview.notes", "备注：%@", $0) },
            ])
        case .contactDraft(let value):
            return compact([
                localized(
                    "system_action.preview.name",
                    "姓名：%@ %@",
                    value.givenName,
                    value.familyName
                ),
                value.organization.map { localized("system_action.preview.organization", "组织：%@", $0) },
                value.phoneNumbers.isEmpty ? nil : localized(
                    "system_action.preview.phone",
                    "电话：%@",
                    value.phoneNumbers.map(\.value).joined(separator: NSLocalizedString("、", comment: ""))
                ),
                value.emailAddresses.isEmpty ? nil : localized(
                    "system_action.preview.email",
                    "邮箱：%@",
                    value.emailAddresses.map(\.value).joined(separator: NSLocalizedString("、", comment: ""))
                ),
            ])
        case .notification(let value):
            return [
                localized(
                    "system_action.preview.trigger",
                    "触发：%@ · %@",
                    date(value.fireAt),
                    value.interruption.displayName
                ),
                localized("system_action.preview.body", "正文：%@", value.body),
            ]
        case .route(let value):
            return compact([
                location(value.destination).map {
                    localized("system_action.preview.destination", "目的地：%@", $0)
                },
                localized(
                    "system_action.preview.transport",
                    "交通：%@ · %@",
                    value.mode.displayName,
                    value.opensImmediately
                        ? NSLocalizedString("立即打开地图", comment: "")
                        : NSLocalizedString("不立即打开", comment: "")
                ),
            ])
        case .capture(let value):
            return compact([
                localized("system_action.preview.capture", "采集方式：%@", value.captureKind.displayName),
                value.suggestedTitle.map {
                    localized("system_action.preview.suggested_title", "建议标题：%@", $0)
                },
                localized(
                    "system_action.preview.target",
                    "目标：%@",
                    value.attachesToSource
                        ? NSLocalizedString("附加到来源", comment: "")
                        : NSLocalizedString("新建 memo", comment: "")
                ),
            ])
        case .focusSession(let value):
            return [
                localized(
                    "system_action.preview.duration_minutes",
                    "时长：%lld 分钟",
                    Int64(value.durationSeconds / 60)
                ),
                localized(
                    "system_action.preview.focus_surfaces",
                    "结束提醒：%@ · Live Activity：%@",
                    yesNo(value.schedulesEndAlert),
                    yesNo(value.allowsLiveActivity)
                ),
            ]
        case .moment(let value):
            return compact([
                localized("system_action.preview.occurred", "发生：%@", date(value.occurredAt)),
                value.location.flatMap(location).map {
                    localized("system_action.preview.location", "地点：%@", $0)
                },
                localized(
                    "system_action.preview.contacts_count",
                    "相关联系人：%lld 位（仅引用哈希）",
                    Int64(value.selectedContactReferenceHashes.count)
                ),
            ])
        case .localContextAttachment(let value):
            return [
                localized(
                    "system_action.preview.local_summary",
                    "本地摘要：%@ · %@",
                    value.contextKind.displayName,
                    value.summaryCode
                ),
                localized("system_action.preview.observed", "观测：%@", date(value.observedAt)),
            ]
        case .unsupported(let kind, _):
            return [localized("system_action.preview.unknown", "未知动作：%@ · 此版本拒绝执行", kind)]
        }
    }

    static func fieldMap(for proposal: SystemActionProposal) -> [String: String] {
        Dictionary(
            lines(for: proposal).enumerated().map { index, line in
                if let separator = line.firstIndex(where: { $0 == "：" || $0 == ":" }) {
                    return (
                        String(line[..<separator]),
                        String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                    )
                }
                return (
                    localized("system_action.preview.field", "字段 %lld", Int64(index + 1)),
                    line
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func compact(_ values: [String?]) -> [String] { values.compactMap { $0 } }

    private static func localized(
        _ key: String,
        _ fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: NSLocalizedString(key, value: fallback, comment: "System action proposal preview"),
            locale: Locale.current,
            arguments: arguments
        )
    }

    private static func location(_ value: SystemActionLocation) -> String? {
        if let address = value.address {
            return [value.label, address].compactMap { $0 }.joined(separator: " · ")
        }
        if let latitude = value.latitude, let longitude = value.longitude {
            let coordinate = String(format: "%.6f, %.6f", latitude, longitude)
            return [value.label, coordinate].compactMap { $0 }.joined(separator: " · ")
        }
        return value.label
    }

    private static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? NSLocalizedString("是", comment: "") : NSLocalizedString("否", comment: "")
    }
}

extension SystemActionCapability {
    static let productCapabilities: [SystemActionCapability] = [
        .calendar, .reminders, .contacts, .notifications, .location, .routes,
        .photos, .capture, .focus, .spotlight, .healthContext, .weatherContext,
    ]

    var displayName: String {
        switch self {
        case .calendar: return NSLocalizedString("日历", comment: "")
        case .reminders: return NSLocalizedString("提醒事项", comment: "")
        case .contacts: return NSLocalizedString("联系人", comment: "")
        case .notifications: return NSLocalizedString("通知", comment: "")
        case .location: return NSLocalizedString("位置", comment: "")
        case .routes: return NSLocalizedString("地图路线", comment: "")
        case .photos: return NSLocalizedString("照片", comment: "")
        case .capture: return NSLocalizedString("采集", comment: "")
        case .focus: return NSLocalizedString("专注", comment: "")
        case .spotlight: return "Spotlight"
        case .healthContext: return "HealthKit"
        case .weatherContext: return "WeatherKit"
        case .unsupported(let value): return value
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        case .notifications: return "bell"
        case .location: return "location"
        case .routes: return "map"
        case .photos: return "photo.on.rectangle"
        case .capture: return "viewfinder"
        case .focus: return "timer"
        case .spotlight: return "magnifyingglass"
        case .healthContext: return "heart.text.square"
        case .weatherContext: return "cloud.sun"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}

extension SystemActionDisclosureLevel {
    var displayName: String {
        switch self {
        case .disabled: return NSLocalizedString("已关闭", comment: "")
        case .privateDeviceOnly: return NSLocalizedString("提案仅本机", comment: "")
        case .redactedSync: return NSLocalizedString("仅同步策略摘要", comment: "")
        case .fullProposal: return NSLocalizedString("同步完整提案", comment: "")
        }
    }
}

extension SystemActionCreatorSource {
    var displayName: String {
        switch self {
        case .user: return NSLocalizedString("用户", comment: "")
        case .localAgent: return NSLocalizedString("本机 Agent", comment: "")
        case .cloudMCP: return NSLocalizedString("云端 MCP", comment: "")
        case .systemEntry: return NSLocalizedString("系统入口", comment: "")
        }
    }
}

extension SystemActionSourceKind {
    var displayName: String {
        switch self {
        case .memo: return "Memo"
        case .dailyPage: return NSLocalizedString("Daily Page", comment: "")
        case .entity: return NSLocalizedString("实体", comment: "")
        case .place: return NSLocalizedString("地点", comment: "")
        case .shareInbox: return NSLocalizedString("分享收件箱", comment: "")
        case .systemEntry: return NSLocalizedString("系统入口", comment: "")
        }
    }
}

extension SystemActionNotificationInterruption {
    var displayName: String {
        switch self {
        case .passive: return NSLocalizedString("静默", comment: "")
        case .active: return NSLocalizedString("普通", comment: "")
        case .timeSensitive: return NSLocalizedString("时效性", comment: "")
        }
    }
}

extension SystemActionRouteMode {
    var displayName: String {
        switch self {
        case .any: return NSLocalizedString("系统默认", comment: "")
        case .driving: return NSLocalizedString("驾车", comment: "")
        case .walking: return NSLocalizedString("步行", comment: "")
        case .transit: return NSLocalizedString("公交", comment: "")
        case .cycling: return NSLocalizedString("骑行", comment: "")
        }
    }
}

extension SystemActionLocalContextKind {
    var displayName: String {
        switch self {
        case .placeSummary: return NSLocalizedString("位置摘要", comment: "")
        case .weatherSummary: return NSLocalizedString("天气摘要", comment: "")
        case .healthSummary: return NSLocalizedString("健康摘要", comment: "")
        case .photo: return NSLocalizedString("照片引用", comment: "")
        case .contactSelection: return NSLocalizedString("联系人引用", comment: "")
        }
    }
}

extension SystemActionKind {
    var displayName: String {
        switch self {
        case .calendarEvent: return NSLocalizedString("日历日程", comment: "")
        case .reminder: return NSLocalizedString("提醒事项", comment: "")
        case .contactDraft: return NSLocalizedString("联系人草稿", comment: "")
        case .notification: return NSLocalizedString("本地通知", comment: "")
        case .route: return NSLocalizedString("地图路线", comment: "")
        case .capture: return NSLocalizedString("采集", comment: "")
        case .focusSession: return NSLocalizedString("专注会话", comment: "")
        case .moment: return "Moment"
        case .localContextAttachment: return NSLocalizedString("本地上下文", comment: "")
        case .unsupported: return NSLocalizedString("不受支持的动作", comment: "")
        }
    }

    var systemImage: String {
        switch self {
        case .calendarEvent: return "calendar"
        case .reminder: return "checklist"
        case .contactDraft: return "person.crop.circle.badge.plus"
        case .notification: return "bell"
        case .route: return "map"
        case .capture: return "viewfinder"
        case .focusSession: return "timer"
        case .moment: return "sparkles.rectangle.stack"
        case .localContextAttachment: return "sensor"
        case .unsupported: return "questionmark.square.dashed"
        }
    }
}

extension SystemActionLifecycleState {
    var displayName: String {
        switch self {
        case .pendingReview: return NSLocalizedString("待审批", comment: "")
        case .approved: return NSLocalizedString("已批准", comment: "")
        case .rejected: return NSLocalizedString("已拒绝", comment: "")
        case .executing: return NSLocalizedString("执行中", comment: "")
        case .succeeded: return NSLocalizedString("已完成", comment: "")
        case .failed: return NSLocalizedString("失败", comment: "")
        case .needsReview: return NSLocalizedString("需确认", comment: "")
        case .cancelled: return NSLocalizedString("已取消", comment: "")
        case .undoPending: return NSLocalizedString("撤销中", comment: "")
        case .undone: return NSLocalizedString("已撤销", comment: "")
        case .expired: return NSLocalizedString("已过期", comment: "")
        case .unsupported: return NSLocalizedString("不支持", comment: "")
        }
    }

    var tint: Color {
        switch self {
        case .succeeded, .undone: return .green
        case .failed, .rejected: return .red
        case .needsReview, .expired: return .orange
        default: return DSColor.accentOnBg
        }
    }
}

extension SystemActionReceiptOutcome {
    var displayName: String {
        switch self {
        case .succeeded: return NSLocalizedString("成功", comment: "")
        case .failed: return NSLocalizedString("失败", comment: "")
        case .cancelled: return NSLocalizedString("已取消", comment: "")
        case .ambiguous: return NSLocalizedString("结果不确定", comment: "")
        case .unsupported: return NSLocalizedString("不支持", comment: "")
        }
    }

    var systemImage: String {
        switch self {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle.fill"
        case .ambiguous: return "questionmark.diamond.fill"
        case .unsupported: return "nosign"
        }
    }

    var tint: Color {
        switch self {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled, .unsupported: return .secondary
        case .ambiguous: return .orange
        }
    }
}

extension SystemActionReconciliationState {
    var displayName: String {
        switch self {
        case .notNeeded: return NSLocalizedString("无需协调", comment: "")
        case .pending: return NSLocalizedString("等待协调", comment: "")
        case .reconciled: return NSLocalizedString("已协调", comment: "")
        case .ambiguous: return NSLocalizedString("结果不确定", comment: "")
        case .needsReview: return NSLocalizedString("需人工确认", comment: "")
        }
    }
}

extension SystemActionRollbackCapability {
    var displayName: String {
        switch self {
        case .reversible: return NSLocalizedString("可撤销", comment: "")
        case .compensating: return NSLocalizedString("补偿式撤销", comment: "")
        case .manual: return NSLocalizedString("需手动处理", comment: "")
        case .none: return NSLocalizedString("不可撤销", comment: "")
        }
    }
}

private struct SystemActionEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundColor(DSColor.accentOnBg)
            Text(LocalizedStringKey(title))
                .font(DSType.titleSM)
                .foregroundColor(DSColor.inkPrimary)
            Text(LocalizedStringKey(detail))
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(DSSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
