import SwiftUI
import MapKit
import CoreSpotlight
import HealthKit
import Photos
import DayPageModels

struct SystemActionReviewView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: SystemActionCenterModel
    let proposal: SystemActionProposal
    let isNew: Bool
    let onClose: () -> Void
    let onSaved: () -> Void

    @State private var draft: SystemActionEditableDraft
    @State private var showRejectConfirmation = false
    @State private var showUndoConfirmation = false
    @State private var showMomentContactPicker = false

    init(
        model: SystemActionCenterModel,
        proposal: SystemActionProposal,
        isNew: Bool,
        onSaved: @escaping () -> Void = {},
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.proposal = proposal
        self.isNew = isNew
        self.onClose = onClose
        self.onSaved = onSaved
        _draft = State(initialValue: SystemActionEditableDraft(proposal: proposal))
    }

    var body: some View {
        NavigationStack {
            Form {
                exactBindingSection
                basicsSection
                payloadSection
                if draft.hasChanges {
                    fieldChangesSection
                }
                provenanceSection
                if let receipt = model.latestReceipt(for: proposal) {
                    receiptSection(receipt)
                }
                actionSection
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.bgWarm)
            .navigationTitle(isNew ? "检查动作草稿" : "检查动作")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", action: onClose)
                }
            }
            .interactiveDismissDisabled(model.activeOperationID == proposal.id)
            .confirmationDialog(
                "拒绝这个提案？",
                isPresented: $showRejectConfirmation,
                titleVisibility: .visible
            ) {
                Button("拒绝", role: .destructive) {
                    Task { if await model.reject(proposal) { onClose() } }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("拒绝会留下不可变的决策记录，但不会调用任何 Apple Framework。")
            }
            .confirmationDialog(
                "撤销已执行的系统动作？",
                isPresented: $showUndoConfirmation,
                titleVisibility: .visible
            ) {
                Button("批准撤销", role: .destructive) {
                    Task { if await model.undo(proposal) { onClose() } }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("撤销也是一个新的、精确绑定的批准动作。若系统对象已被外部修改，DayPage 会停止并要求人工确认。")
            }
        }
        .tint(DSColor.accentOnBg)
        .systemActionNativePresentations()
        .sheet(isPresented: $showMomentContactPicker) {
            SystemActionContactPicker { hashes in
                draft.selectedContactReferenceHashes = Array(hashes.prefix(20))
                showMomentContactPicker = false
            } onCancel: {
                showMomentContactPicker = false
            }
            .ignoresSafeArea()
        }
    }

    private var exactBindingSection: some View {
        Section {
            LabeledContent {
                Text("R\(proposal.revision)").font(DSType.mono10)
            } label: {
                Label("修订", systemImage: "arrow.triangle.2.circlepath")
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Label("内容指纹", systemImage: "number")
                    bindingHash
                }
            } else {
                HStack(alignment: .top) {
                    Label("内容指纹", systemImage: "number")
                    Spacer()
                    bindingHash.multilineTextAlignment(.trailing)
                }
            }
            LabeledContent {
                Text(proposal.lifecycleState.displayName)
                    .foregroundColor(proposal.lifecycleState.tint)
            } label: {
                Label("状态", systemImage: proposal.kind.systemImage)
            }
        } header: {
            Text("本次批准绑定")
        } footer: {
            Text(String.localizedStringWithFormat(
                NSLocalizedString(
                    "system_action.binding.changed_revision",
                    value: "下方任意字段改变都会创建 R%lld 和新的指纹；旧批准不会继承。",
                    comment: ""
                ),
                proposal.revision + 1
            ))
        }
        .listRowBackground(DSColor.surfaceWhite)
    }

    private var bindingHash: some View {
        Text(proposal.payloadHash)
            .font(DSType.mono9)
            .foregroundColor(DSColor.inkMuted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .textSelection(.enabled)
    }

    private var basicsSection: some View {
        Section("提案") {
            TextField("标题", text: $draft.title, axis: .vertical)
                .lineLimit(1...3)
            TextField("为什么建议这样做", text: $draft.rationale, axis: .vertical)
                .lineLimit(2...6)
        }
        .listRowBackground(DSColor.surfaceWhite)
    }

    @ViewBuilder
    private var payloadSection: some View {
        switch proposal.payload {
        case .calendarEvent:
            Section("日历字段") {
                DatePicker("开始", selection: $draft.startAt)
                DatePicker("结束", selection: $draft.endAt)
                Toggle("全天", isOn: $draft.isAllDay)
                TextField("备注", text: $draft.notes, axis: .vertical)
                TextField("地点（可选）", text: $draft.primaryText, axis: .vertical)
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .reminder:
            Section("提醒事项字段") {
                Toggle("设置到期时间", isOn: $draft.optionalDateEnabled)
                if draft.optionalDateEnabled {
                    DatePicker("到期", selection: $draft.optionalDate)
                }
                Stepper(
                    String.localizedStringWithFormat(
                        NSLocalizedString("system_action.reminder.priority", value: "优先级 %lld", comment: ""),
                        draft.integerOption
                    ),
                    value: $draft.integerOption,
                    in: 0...9
                )
                TextField("备注", text: $draft.notes, axis: .vertical)
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .contactDraft:
            Section {
                TextField("名", text: $draft.primaryText)
                TextField("姓", text: $draft.secondaryText)
                TextField("组织", text: $draft.notes)
                VStack(alignment: .leading, spacing: 6) {
                    Text("电话号码（每行一个，最多 5 个）").font(DSType.labelSM).foregroundColor(DSColor.inkMuted)
                    TextEditor(text: $draft.phoneLines).frame(minHeight: 70)
                        .accessibilityLabel(Text("电话号码（每行一个，最多 5 个）"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("邮箱（每行一个，最多 5 个）").font(DSType.labelSM).foregroundColor(DSColor.inkMuted)
                    TextEditor(text: $draft.emailLines).frame(minHeight: 70)
                        .accessibilityLabel(Text("邮箱（每行一个，最多 5 个）"))
                }
            } header: {
                Text("联系人字段")
            } footer: {
                Text("批准后，DayPage 会将以上精确字段直接保存到通讯录；不会再显示可编辑的系统页面。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .notification:
            Section("通知字段") {
                TextField("正文", text: $draft.notes, axis: .vertical).lineLimit(2...6)
                DatePicker("触发时间", selection: $draft.optionalDate)
                Picker("提醒级别", selection: $draft.mode) {
                    Text("静默").tag("passive")
                    Text("普通").tag("active")
                    Text("时效性").tag("time_sensitive")
                }
                Label("v1 通知固定使用声音，不包含线程标识。", systemImage: "speaker.wave.2")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .route:
            Section {
                Picker("目的地输入", selection: $draft.routeDestinationMode) {
                    Text("地址").tag(SystemActionRouteDestinationMode.address)
                    Text("坐标").tag(SystemActionRouteDestinationMode.coordinates)
                }
                .pickerStyle(.segmented)
                TextField("地点名称（可选）", text: $draft.primaryText)
                if draft.routeDestinationMode == .address {
                    TextField("目的地地址", text: $draft.secondaryText, axis: .vertical)
                } else {
                    coordinateFields
                }
                Picker("交通方式", selection: $draft.mode) {
                    Text("系统默认").tag("any")
                    Text("驾车").tag("driving")
                    Text("步行").tag("walking")
                    Text("公交").tag("transit")
                    Text("骑行").tag("cycling")
                }
                Label("批准并执行后打开 Apple 地图", systemImage: "map")
                    .foregroundStyle(.secondary)
                if case .route(let route) = proposal.payload {
                    SystemActionRoutePreview(location: route.destination)
                }
            } header: {
                Text("路线字段")
            } footer: {
                Text("地址与坐标严格二选一；批准绑定您当前看到的目的地。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .capture:
            Section {
                Picker("采集方式", selection: $draft.mode) {
                    Text("输入文本").tag("text")
                    Text("选择照片").tag("photo")
                    Text("相机拍摄").tag("camera")
                    Text("扫描文档").tag("document")
                    Text("识别文字").tag("text_scan")
                    Text("手写 / Pencil").tag("ink")
                    Text("文件").tag("file")
                    Text("语音").tag("voice")
                }
                TextField("建议标题", text: $draft.primaryText)
                Toggle("附加到来源 memo", isOn: $draft.boolOption)
            } header: {
                Text("采集字段")
            } footer: {
                Text("采集必须在前台完成；系统相册选择器只会交付您选中的项目。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .focusSession:
            Section {
                Stepper(
                    String.localizedStringWithFormat(
                        NSLocalizedString("system_action.focus.minutes", value: "%lld 分钟", comment: ""),
                        draft.integerOption
                    ),
                    value: $draft.integerOption,
                    in: 1...1_440
                )
                Toggle("结束时提醒", isOn: $draft.boolOption)
                Toggle("显示 Live Activity", isOn: $draft.secondaryBoolOption)
            } header: {
                Text("专注字段")
            } footer: {
                Text("结束提醒与 Live Activity 分别绑定本次审批；锁屏和灵动岛只显示脱敏标题与剩余时间。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .moment:
            Section {
                DatePicker("发生时间", selection: $draft.startAt)
                Toggle("执行时读取一次当前位置", isOn: $draft.boolOption)
                if draft.boolOption {
                    TextField("地点名称", text: $draft.primaryText)
                }
                Button {
                    showMomentContactPicker = true
                } label: {
                    Label(selectedContactsLabel, systemImage: "person.2")
                }
            } header: {
                Text("Moment 字段")
            } footer: {
                Text("联系人通过系统选择器确认并只保存引用哈希。若启用位置，坐标会在批准执行时于本机读取一次，不进入提案。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .localContextAttachment(let value):
            Section {
                LabeledContent("类型", value: value.contextKind.rawValue)
                LabeledContent("摘要码", value: value.summaryCode)
                LabeledContent("观测时间", value: value.observedAt.formatted(date: .abbreviated, time: .shortened))
            } header: {
                Text("本地摘要")
            } footer: {
                Text("健康、天气与地点原始样本不会写入云端动作账本；这里只附加有限本地摘要。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        case .unsupported(let kind, _):
            Section {
                Label(kind, systemImage: "questionmark.square.dashed")
            } header: {
                Text("不受支持")
            } footer: {
                Text("此客户端会保留提案供检查与同步，但拒绝执行未知动作。")
            }
            .listRowBackground(DSColor.surfaceWhite)
        }
    }

    @ViewBuilder
    private var coordinateFields: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                coordinateLatitudeField
                coordinateLongitudeField
            }
        } else {
            HStack {
                coordinateLatitudeField
                coordinateLongitudeField
            }
        }
    }

    private var coordinateLatitudeField: some View {
        TextField("纬度 (-90…90)", text: $draft.latitude)
            .keyboardType(.numbersAndPunctuation)
    }

    private var coordinateLongitudeField: some View {
        TextField("经度 (-180…180)", text: $draft.longitude)
            .keyboardType(.numbersAndPunctuation)
    }

    private var selectedContactsLabel: String {
        guard !draft.selectedContactReferenceHashes.isEmpty else {
            return NSLocalizedString("选择相关联系人", comment: "")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("system_action.moment.selected_contacts", value: "已选择 %lld 位联系人", comment: ""),
            draft.selectedContactReferenceHashes.count
        )
    }

    private var provenanceSection: some View {
        Section("来源与隐私") {
            LabeledContent("创建方", value: proposal.creatorSource.displayName)
            LabeledContent("目标设备", value: targetDeviceLabel)
            LabeledContent("锁屏披露", value: redactionLabel)
            if proposal.sourceReferences.isEmpty {
                LabeledContent("引用", value: "无")
            } else {
                ForEach(Array(proposal.sourceReferences.enumerated()), id: \.offset) { _, source in
                    LabeledContent(source.kind.displayName, value: source.identifier)
                }
            }
        }
        .listRowBackground(DSColor.surfaceWhite)
    }

    private var fieldChangesSection: some View {
        Section {
            ForEach(fieldChanges) { change in
                VStack(alignment: .leading, spacing: 6) {
                    Text(change.label)
                        .font(DSType.labelSM.weight(.semibold))
                        .foregroundColor(DSColor.inkPrimary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("原值").font(DSType.mono9).foregroundColor(DSColor.inkSubtle)
                        Text(change.before).font(DSType.bodySM).foregroundColor(DSColor.inkMuted)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("新值").font(DSType.mono9).foregroundColor(DSColor.accentOnBg)
                        Text(change.after).font(DSType.bodySM).foregroundColor(DSColor.inkPrimary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("逐字段差异")
        } footer: {
            Text("保存后会生成新的修订和内容指纹；这里列出的每一项都必须重新批准。")
        }
        .listRowBackground(DSColor.surfaceWhite)
    }

    private var fieldChanges: [SystemActionReviewFieldChange] {
        guard let revised = try? draft.makeRevised() else { return [] }
        var changes: [SystemActionReviewFieldChange] = []
        if proposal.title != revised.title {
            changes.append(.init(label: "提案标题", before: proposal.title, after: revised.title))
        }
        if proposal.rationale != revised.rationale {
            changes.append(.init(label: "建议原因", before: proposal.rationale, after: revised.rationale))
        }
        let before = SystemActionProposalPreview.fieldMap(for: proposal)
        let after = SystemActionProposalPreview.fieldMap(for: revised)
        for key in Set(before.keys).union(after.keys).sorted() where before[key] != after[key] {
            changes.append(.init(
                label: key,
                before: before[key] ?? NSLocalizedString("无", comment: ""),
                after: after[key] ?? NSLocalizedString("无", comment: "")
            ))
        }
        return changes
    }

    private func receiptSection(_ receipt: SystemActionReceipt) -> some View {
        Section("最近回执") {
            LabeledContent("结果", value: receipt.outcome.displayName)
            LabeledContent("阶段", value: receipt.phase == .undo ? "撤销" : "执行")
            LabeledContent("尝试", value: String(receipt.attempt))
            LabeledContent("协调", value: receipt.reconciliationState.displayName)
            LabeledContent("执行设备", value: "…\(receipt.deviceID.suffix(8))")
            LabeledContent(
                "执行模式",
                value: receipt.executionMode == .onlineLease ? "云端租约" : "本机所有者"
            )
            LabeledContent("可撤销性", value: receipt.rollbackCapability.displayName)
            if receipt.outcome == .succeeded,
               model.snapshot?.pendingOutbox.contains(where: { operation in
                   guard case .receipt(let queued) = operation.payload else { return false }
                   return queued.id == receipt.id
               }) == true {
                Label("系统动作已成功；回执将在网络恢复后同步。", systemImage: "icloud.and.arrow.up")
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
            }
            if let code = receipt.boundedResult?.summaryCode {
                LabeledContent("有限结果", value: code)
            }
            if let hash = receipt.boundedResult?.externalIdentifierHash {
                VStack(alignment: .leading, spacing: 4) {
                    Text("外部对象哈希").font(DSType.labelSM).foregroundColor(DSColor.inkMuted)
                    Text(hash).font(DSType.mono9).textSelection(.enabled)
                }
            }
            if let errorCode = receipt.errorCode {
                LabeledContent("错误码", value: errorCode)
            }
        }
        .listRowBackground(DSColor.surfaceWhite)
    }

    private var actionSection: some View {
        Section {
            if isNew {
                actionButton("保存到待审批", systemImage: "tray.and.arrow.down", prominence: .primary) {
                    let candidate: SystemActionProposal
                    do {
                        candidate = try draft.makeRevised()
                    } catch {
                        model.errorMessage = Self.validationMessage(error)
                        return
                    }
                    // A seed starts at R1; `makeRevised` intentionally produces
                    // R2, so rebuild the edited payload as a new R1 proposal.
                    Task {
                        do {
                            let saved = try SystemActionProposal(
                                payload: candidate.payload,
                                title: candidate.title,
                                rationale: candidate.rationale,
                                sourceReferences: proposal.sourceReferences,
                                creatorSource: proposal.creatorSource,
                                creatorDeviceID: proposal.creatorDeviceID,
                                redactionLevel: proposal.redactionLevel,
                                targetDevice: proposal.targetDevice
                            )
                            if await model.save(saved) {
                                onSaved()
                                onClose()
                            }
                        } catch {
                            model.errorMessage = Self.validationMessage(error)
                        }
                    }
                }
            } else if draft.hasChanges {
                actionButton(
                    String.localizedStringWithFormat(
                        NSLocalizedString(
                            "system_action.review.save_revision",
                            value: "保存为 R%lld 并重新审批",
                            comment: ""
                        ),
                        proposal.revision + 1
                    ),
                    systemImage: "arrow.triangle.2.circlepath",
                    prominence: .primary
                ) {
                    let revised: SystemActionProposal
                    do {
                        revised = try draft.makeRevised()
                    } catch {
                        model.errorMessage = Self.validationMessage(error)
                        return
                    }
                    Task {
                        if await model.saveReplacement(original: proposal, revised: revised) {
                            onSaved()
                            onClose()
                        }
                    }
                }
            } else {
                stateActions
            }

            if !isNew && proposal.lifecycleState == .pendingReview {
                Button("拒绝提案", role: .destructive) { showRejectConfirmation = true }
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        } footer: {
            Text("\(actionFooter) 批量动作逐项执行、逐项回执；一个项目失败不会回滚已成功的同级项目。")
        }
        .listRowBackground(DSColor.surfaceWhite)
        .disabled(model.activeOperationID == proposal.id)
    }

    @ViewBuilder
    private var stateActions: some View {
        switch proposal.lifecycleState {
        case .pendingReview:
            actionButton("批准并执行", systemImage: "checkmark.shield.fill", prominence: .primary) {
                Task { if await model.approve(proposal, executeImmediately: true) { onClose() } }
            }
            actionButton("只批准，稍后执行", systemImage: "checkmark.shield", prominence: .secondary) {
                Task { if await model.approve(proposal, executeImmediately: false) { onClose() } }
            }
        case .approved:
            actionButton("执行已批准动作", systemImage: "play.fill", prominence: .primary) {
                Task { if await model.execute(proposal) { onClose() } }
            }
        case .needsReview:
            actionButton("检查外部结果", systemImage: "arrow.clockwise", prominence: .primary) {
                Task { _ = await model.execute(proposal) }
            }
        case .succeeded:
            if let receipt = model.latestReceipt(for: proposal),
               receipt.rollbackCapability == .reversible || receipt.rollbackCapability == .compensating {
                actionButton("请求撤销", systemImage: "arrow.uturn.backward", prominence: .destructive) {
                    showUndoConfirmation = true
                }
            }
        default:
            Text("此状态没有可用操作。")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private enum ActionProminence { case primary, secondary, destructive }

    private func actionButton(
        _ title: String,
        systemImage: String,
        prominence: ActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: systemImage)
                .font(DSType.titleSM)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominence == .destructive ? .red : prominence == .secondary ? DSColor.inkMuted : DSColor.amberDeep)
    }

    private var actionFooter: String {
        if draft.hasChanges && !isNew {
            return NSLocalizedString("字段已改变。保存后当前批准（如有）将失效，新修订回到待审批。", comment: "")
        }
        return NSLocalizedString(
            "执行前先把批准记录与本地 executing 状态持久化；再调用 Apple Framework；最后追加不可变回执。",
            comment: ""
        )
    }

    private var targetDeviceLabel: String {
        switch proposal.targetDevice {
        case .creatingDevice: return NSLocalizedString("创建此提案的设备", comment: "")
        case .anyOwnedOnline: return NSLocalizedString("任一在线自有设备", comment: "")
        case .specific: return NSLocalizedString("指定设备", comment: "")
        }
    }

    private var redactionLabel: String {
        switch proposal.redactionLevel {
        case .privateOnLockScreen: return NSLocalizedString("锁屏隐藏标题", comment: "")
        case .titleOnly: return NSLocalizedString("仅标题", comment: "")
        case .boundedSummary: return NSLocalizedString("有限摘要", comment: "")
        }
    }

    private static func validationMessage(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return String(description.prefix(240))
        }
        guard let validation = error as? SystemActionValidationError else {
            return NSLocalizedString(
                "system_action.error.review_generic",
                value: "无法保存。请检查字段后重试。",
                comment: ""
            )
        }
        switch validation {
        case .invalidField(let field):
            let format = NSLocalizedString(
                "system_action.error.invalid_field",
                value: "字段不符合 v1 契约：%@。",
                comment: ""
            )
            return String(format: format, field)
        case .payloadTooLarge:
            return NSLocalizedString("system_action.error.payload_too_large", value: "动作内容过大，无法保存。", comment: "")
        case .unsupportedActionKind:
            return NSLocalizedString("system_action.error.unsupported", value: "此版本不支持该动作类型。", comment: "")
        default:
            return NSLocalizedString("system_action.error.review_generic", value: "无法保存。请检查字段后重试。", comment: "")
        }
    }
}

private struct SystemActionReviewFieldChange: Identifiable {
    let id = UUID()
    let label: String
    let before: String
    let after: String
}

private struct SystemActionRoutePreview: View {
    let location: SystemActionLocation

    var body: some View {
        if let coordinate {
            Map(
                coordinateRegion: .constant(MKCoordinateRegion(
                    center: coordinate,
                    span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
                )),
                annotationItems: [PreviewPin(coordinate: coordinate)]
            ) { pin in
                MapMarker(coordinate: pin.coordinate, tint: .orange)
            }
            .frame(minHeight: 150)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .accessibilityLabel(Text("system_action.route.map_preview"))
        } else if let address = location.address {
            Label(address, systemImage: "mappin.and.ellipse")
                .font(DSType.bodySM)
                .foregroundColor(DSColor.inkMuted)
                .accessibilityLabel(String(
                    format: NSLocalizedString("system_action.route.address_preview", comment: ""),
                    address
                ))
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = location.latitude, let longitude = location.longitude else { return nil }
        let value = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(value) ? value : nil
    }

    private struct PreviewPin: Identifiable {
        let id = UUID()
        let coordinate: CLLocationCoordinate2D
    }
}

struct SystemAccessView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SystemActionCenterModel
    @State private var localAccessSnapshots: [SystemActionLocalAccessSnapshot] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("系统写入权限只在您批准并执行对应动作时请求。", systemImage: "hand.raised.fill")
                    Label("本地上下文读取由您点按对应按钮触发，并在本机先生成有限摘要。", systemImage: "hand.tap.fill")
                    Label("关闭能力不会删除既有 Apple 数据，只会停止新的执行。", systemImage: "pause.circle")
                    Label("健康原始样本、联系人、照片与精确位置不进入云端回执。", systemImage: "lock.shield")
                } header: {
                    Text("Just-in-time 权限")
                }

                Section("系统能力") {
                    ForEach(model.capabilities, id: \.kind.rawValue) { capability in
                        if capability.kind != .localContextAttachment {
                            capabilityToggle(
                                SystemActionCapability(actionKind: capability.kind),
                                title: capability.kind.displayName,
                                image: capability.kind.systemImage,
                                detail: detail(capability),
                                availability: capability.availability
                            )
                        }
                    }
                }

                Section {
                    ForEach(localAccessSnapshots) { snapshot in
                        capabilityToggle(
                            snapshot.capability,
                            title: snapshot.title,
                            image: snapshot.image,
                            detail: snapshot.detail,
                            availability: snapshot.availability
                        )
                    }
                } header: {
                    Text("本地输入与系统输出")
                } footer: {
                    Text("开关关闭后，已批准但尚未执行的相关动作也会在调用系统 Framework 前停止。“仅同步策略摘要”只同步能力设置；只有“同步完整提案”会上传可执行字段。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(DSColor.bgWarm)
            .navigationTitle("系统访问")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                localAccessSnapshots = SystemActionLocalAccessSnapshot.live()
                await model.refresh()
            }
        }
        .tint(DSColor.accentOnBg)
    }

    private func capabilityToggle(
        _ capability: SystemActionCapability,
        title: String,
        image: String,
        detail: String,
        availability: SystemActionAvailability
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.isCapabilityOffered(capability) },
                set: { offered in Task { await model.setCapability(capability, offered: offered) } }
            )) {
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: image)
                        .frame(width: 28)
                        .foregroundColor(availabilityTint(availability))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(DSType.bodyMD)
                        Text(detail).font(DSType.labelSM).foregroundColor(DSColor.inkMuted)
                    }
                }
            }
            if model.isCapabilityOffered(capability) {
                Menu {
                    disclosureButton(.privateDeviceOnly, capability: capability)
                    disclosureButton(.redactedSync, capability: capability)
                    disclosureButton(.fullProposal, capability: capability)
                } label: {
                    Label(
                        disclosureLabel(model.disclosureLevel(for: capability)),
                        systemImage: "icloud.and.arrow.up"
                    )
                    .font(DSType.labelSM)
                    .foregroundColor(DSColor.inkMuted)
                }
                .accessibilityLabel(String.localizedStringWithFormat(
                    NSLocalizedString("system_action.access.cloud_disclosure", value: "%@ 云端披露", comment: ""),
                    title
                ))
            }
        }
        .disabled(model.activePolicyCapability != nil)
    }

    @ViewBuilder
    private func disclosureButton(
        _ disclosure: SystemActionDisclosureLevel,
        capability: SystemActionCapability
    ) -> some View {
        Button {
            Task { await model.setDisclosure(disclosure, for: capability) }
        } label: {
            if model.disclosureLevel(for: capability) == disclosure {
                Label(disclosureLabel(disclosure), systemImage: "checkmark")
            } else {
                Text(disclosureLabel(disclosure))
            }
        }
    }

    private func disclosureLabel(_ disclosure: SystemActionDisclosureLevel) -> String {
        switch disclosure {
        case .disabled: return NSLocalizedString("关闭", comment: "")
        case .privateDeviceOnly: return NSLocalizedString("云端：提案仅本机", comment: "")
        case .redactedSync: return NSLocalizedString("云端：仅同步策略摘要", comment: "")
        case .fullProposal: return NSLocalizedString("云端：同步完整提案", comment: "")
        }
    }

    private func detail(_ value: SystemActionCapabilitySnapshot) -> String {
        let authorization: String
        switch value.authorization {
        case .notApplicable: authorization = NSLocalizedString("无需授权", comment: "")
        case .notDetermined: authorization = NSLocalizedString("尚未请求", comment: "")
        case .denied: authorization = NSLocalizedString("已拒绝", comment: "")
        case .restricted: authorization = NSLocalizedString("受系统限制", comment: "")
        case .limited: authorization = NSLocalizedString("有限访问", comment: "")
        case .writeOnly: authorization = NSLocalizedString("仅写入", comment: "")
        case .full: authorization = NSLocalizedString("已允许", comment: "")
        case .unsupported: authorization = NSLocalizedString("不支持", comment: "")
        }
        if let reasonCode = value.reasonCode { return "\(authorization) · \(reasonCode)" }
        return authorization
    }

    private func availabilitySymbol(_ value: SystemActionAvailability) -> String {
        switch value {
        case .available: return "checkmark.circle.fill"
        case .requiresPermission: return "hand.raised.circle"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .unsupported: return "nosign"
        }
    }

    private func availabilityTint(_ value: SystemActionAvailability) -> Color {
        switch value {
        case .available: return .green
        case .requiresPermission: return DSColor.accentOnBg
        case .unavailable: return .orange
        case .unsupported: return .secondary
        }
    }
}

private struct SystemActionLocalAccessSnapshot: Identifiable {
    var id: String { capability.rawValue }
    let capability: SystemActionCapability
    let title: String
    let image: String
    let detail: String
    let availability: SystemActionAvailability

    @MainActor
    static func live() -> [SystemActionLocalAccessSnapshot] {
        let healthAvailable = HKHealthStore.isHealthDataAvailable()
        let healthDetail = healthAvailable
            ? NSLocalizedString("可读取今日步数；HealthKit 不披露读取授权状态，使用时校验", comment: "")
            : NSLocalizedString("此设备不提供 Health 数据", comment: "")

        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let photoDetail: String
        let photoAvailability: SystemActionAvailability
        switch photoStatus {
        case .notDetermined:
            photoDetail = NSLocalizedString("系统选择器无需读取授权；保存 Moment 时尚未请求添加权限", comment: "")
            photoAvailability = .requiresPermission
        case .denied:
            photoDetail = NSLocalizedString("系统选择器仍可用；保存到相册的添加权限已拒绝", comment: "")
            photoAvailability = .requiresPermission
        case .restricted:
            photoDetail = NSLocalizedString("系统选择器仍可用；保存到相册受系统限制", comment: "")
            photoAvailability = .unavailable
        case .authorized, .limited:
            photoDetail = NSLocalizedString("系统选择器无需读取授权；已允许向相册添加", comment: "")
            photoAvailability = .available
        @unknown default:
            photoDetail = NSLocalizedString("相册添加权限状态不可识别", comment: "")
            photoAvailability = .unsupported
        }

        let spotlightAvailable = CSSearchableIndex.isIndexingAvailable()
        return [
            .init(
                capability: .healthContext,
                title: NSLocalizedString("HealthKit 健康摘要", comment: ""),
                image: "heart.text.square",
                detail: healthDetail,
                availability: healthAvailable ? .requiresPermission : .unavailable
            ),
            .init(
                capability: .weatherContext,
                title: NSLocalizedString("WeatherKit 天气摘要", comment: ""),
                image: "cloud.sun",
                detail: NSLocalizedString(
                    "WeatherKit entitlement 已配置；位置授权与服务结果在点按读取时校验",
                    comment: ""
                ),
                availability: .requiresPermission
            ),
            .init(
                capability: .photos,
                title: NSLocalizedString("Photos 选择与保存", comment: ""),
                image: "photo.on.rectangle",
                detail: photoDetail,
                availability: photoAvailability
            ),
            .init(
                capability: .spotlight,
                title: NSLocalizedString("Spotlight 脱敏索引", comment: ""),
                image: "magnifyingglass",
                detail: spotlightAvailable
                    ? NSLocalizedString("索引服务可用；审批前只发布通用占位", comment: "")
                    : NSLocalizedString("此设备当前不提供 Spotlight 索引服务", comment: ""),
                availability: spotlightAvailable ? .available : .unavailable
            ),
        ]
    }
}
