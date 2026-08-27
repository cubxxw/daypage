import CryptoKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import DayPageModels
import DayPageStorage

/// A local-only summary record. The cloud proposal carries only this UUID;
/// raw HealthKit, WeatherKit and CoreLocation values remain inside the user's
/// device container.
struct SystemActionLocalContextRecord: Codable, Sendable, Equatable {
    static let defaultRetentionDuration: TimeInterval = 30 * 24 * 60 * 60

    let schemaVersion: Int
    let id: UUID
    let kind: SystemActionLocalContextKind
    let observedAt: Date
    let expiresAt: Date?
    let boundedValues: [String: String]

    init(
        id: UUID = UUID(),
        kind: SystemActionLocalContextKind,
        observedAt: Date,
        expiresAt: Date? = nil,
        boundedValues: [String: String]
    ) {
        self.schemaVersion = 1
        self.id = id
        self.kind = kind
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.boundedValues = boundedValues
    }

    func retentionExpiresAt(
        maximumAge: TimeInterval = SystemActionLocalContextRecord.defaultRetentionDuration
    ) -> Date {
        (expiresAt ?? observedAt.addingTimeInterval(maximumAge)).localContextMillisecondPrecision
    }

    func withRetentionExpiresAt(_ expiresAt: Date) -> SystemActionLocalContextRecord {
        .init(
            id: id,
            kind: kind,
            observedAt: observedAt,
            expiresAt: expiresAt.localContextMillisecondPrecision,
            boundedValues: boundedValues
        )
    }
}

private extension Date {
    var localContextMillisecondPrecision: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}

private struct SystemActionMomentImportedPhoto: Transferable {
    let url: URL
    let fileExtension: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("daypage-moment-\(UUID().uuidString.lowercased())")
            do {
                _ = try SystemActionBoundedFileCopier.copy(
                    from: received.file,
                    to: target,
                    maximumByteCount: AppleMomentStore.maximumPhotoByteCount
                )
                return Self(
                    url: target,
                    fileExtension: received.file.pathExtension.isEmpty ? "image" : received.file.pathExtension
                )
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }
    }
}

struct SystemActionMomentComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SystemActionCenterModel

    @State private var title = "此刻"
    @State private var occurredAt = Date()
    @State private var requestsLocation = false
    @State private var placeLabel = ""
    @State private var contactReferenceHashes: [String] = []
    @State private var photoSelection: PhotosPickerItem?
    @State private var importedPhoto: SystemActionMomentImportedPhoto?
    @State private var showsContactPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Moment 标题", text: $title)
                    DatePicker("发生时间", selection: $occurredAt)
                } header: {
                    Text("本地草稿")
                } footer: {
                    Text("点按保存只会创建待审批提案；位置读取与最终落盘仍要在审批执行时完成。")
                }

                Section("可选输入") {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label(importedPhoto == nil ? "选择一张照片" : "已选择照片，可重新选择", systemImage: "photo")
                    }
                    .onChange(of: photoSelection) { item in
                        guard let item else { return }
                        Task { await importPhoto(item) }
                    }

                    Button {
                        showsContactPicker = true
                    } label: {
                        Label(
                            contactReferenceHashes.isEmpty
                                ? "选择相关联系人"
                                : "已选择 \(contactReferenceHashes.count) 位联系人",
                            systemImage: "person.2"
                        )
                    }

                    Toggle("审批执行时读取一次当前位置", isOn: $requestsLocation)
                    if requestsLocation {
                        TextField("地点标签", text: $placeLabel)
                    }
                }

                Section("隐私") {
                    Label("照片原件写入受文件保护的本机 Moment 目录", systemImage: "lock.iphone")
                    Label("联系人只保存不可逆引用哈希", systemImage: "person.badge.shield.checkmark")
                    Label("坐标只写入本机 Moment，不进入云端回执", systemImage: "location.slash")
                }
                .font(.footnote)

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("保存本地草稿并送审", systemImage: "checkmark.shield")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || cleanTitle.isEmpty || (requestsLocation && cleanPlaceLabel.isEmpty))
                }
            }
            .navigationTitle("新建 Moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cleanupTemporaryPhoto(); dismiss() }
                        .disabled(isSaving)
                }
            }
            .sheet(isPresented: $showsContactPicker) {
                SystemActionContactPicker { hashes in
                    contactReferenceHashes = Array(hashes.prefix(20))
                    showsContactPicker = false
                } onCancel: {
                    showsContactPicker = false
                }
                .ignoresSafeArea()
            }
            .alert("Moment 未保存", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear {
                if !isSaving { cleanupTemporaryPhoto() }
            }
        }
        .tint(DSColor.accentOnBg)
    }

    private var cleanTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .systemActionPrefixUTF8Bytes(160)
    }

    private var cleanPlaceLabel: String {
        placeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            .systemActionPrefixUTF8Bytes(240)
    }

    @MainActor
    private func importPhoto(_ item: PhotosPickerItem) async {
        photoSelection = nil
        do {
            guard let imported = try await item.loadTransferable(type: SystemActionMomentImportedPhoto.self) else {
                throw CocoaError(.fileReadUnknown)
            }
            cleanupTemporaryPhoto()
            importedPhoto = imported
        } catch {
            errorMessage = String(error.localizedDescription.prefix(240))
        }
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        var draftID: UUID?
        do {
            let id = try await AppleMomentStore.shared.saveDraft(
                title: cleanTitle,
                occurredAt: occurredAt,
                contactReferenceHashes: contactReferenceHashes,
                photoFileURL: importedPhoto?.url,
                photoFileExtension: importedPhoto?.fileExtension
            )
            draftID = id
            let proposal = try SystemActionProposal(
                payload: .moment(.init(
                    occurredAt: occurredAt,
                    title: cleanTitle,
                    location: requestsLocation ? .init(label: cleanPlaceLabel) : nil,
                    selectedContactReferenceHashes: contactReferenceHashes
                )),
                title: cleanTitle,
                rationale: "由您在 Moment 编辑器中显式保存的本地草稿。",
                sourceReferences: [.init(kind: .entity, identifier: "moment:\(id.uuidString.lowercased())")],
                creatorSource: .user,
                creatorDeviceID: model.deviceID,
                redactionLevel: .privateOnLockScreen,
                targetDevice: .creatingDevice
            )
            guard await model.save(proposal) else {
                throw CocoaError(.fileWriteUnknown)
            }
            cleanupTemporaryPhoto()
            isSaving = false
            dismiss()
        } catch {
            if let draftID { try? await AppleMomentStore.shared.discardDraft(id: draftID) }
            isSaving = false
            errorMessage = String(error.localizedDescription.prefix(240))
        }
    }

    private func cleanupTemporaryPhoto() {
        if let url = importedPhoto?.url { try? FileManager.default.removeItem(at: url) }
        importedPhoto = nil
    }
}

actor SystemActionLocalContextStore {
    static let shared = SystemActionLocalContextStore()

    struct RetentionPolicy: Sendable {
        var maximumAge: TimeInterval = 30 * 24 * 60 * 60
        var maximumRecordCount = 128
        var maximumTotalByteCount = 1 * 1_024 * 1_024

        static let `default` = RetentionPolicy()
    }

    private struct StoredFile {
        let url: URL
        let byteCount: Int
    }

    private let directoryURL: URL
    private let retentionPolicy: RetentionPolicy
    private let now: @Sendable () -> Date

    init(
        directoryURL: URL = SystemActionLocalContextStore.directoryURL,
        retentionPolicy: RetentionPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directoryURL = directoryURL
        self.retentionPolicy = RetentionPolicy(
            maximumAge: max(1, retentionPolicy.maximumAge),
            maximumRecordCount: max(1, retentionPolicy.maximumRecordCount),
            maximumTotalByteCount: max(1, retentionPolicy.maximumTotalByteCount)
        )
        self.now = now
    }

    func save(_ record: SystemActionLocalContextRecord) throws {
        let currentDate = now()
        let expiresAt = record.retentionExpiresAt(maximumAge: retentionPolicy.maximumAge)
        let normalizedRecord = record.withRetentionExpiresAt(expiresAt)
        guard isValid(normalizedRecord), expiresAt > currentDate else {
            throw SystemActionLocalContextStoreError.invalidRecord
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let retainedFiles = try scanAndPruneExpired(at: currentDate)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(normalizedRecord)
        guard data.count <= 16 * 1_024 else { throw SystemActionLocalContextStoreError.invalidRecord }
        let target = url(for: record.id)
        // Proposal approval binds this opaque UUID. Once a live record exists,
        // its private values must remain immutable for the proposal lifetime.
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw SystemActionLocalContextStoreError.invalidRecord
        }
        let otherFiles = retainedFiles.filter { $0.url.standardizedFileURL != target.standardizedFileURL }
        let retainedByteCount = otherFiles.reduce(0) { partial, file in
            partial.addingReportingOverflow(file.byteCount).overflow
                ? Int.max
                : partial + file.byteCount
        }
        guard otherFiles.count < retentionPolicy.maximumRecordCount,
              data.count <= retentionPolicy.maximumTotalByteCount,
              retainedByteCount <= retentionPolicy.maximumTotalByteCount - data.count else {
            throw SystemActionLocalContextStoreError.retentionLimitExceeded
        }
        try data.write(
            to: target,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: target.path
        )
    }

    func delete(id: UUID) throws {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Removes only the account-scoped local-context directory. Raw memos,
    /// assets and every other Vault path remain untouched.
    func clearAll() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        try FileManager.default.removeItem(at: directoryURL)
    }

    func prune() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        _ = try scanAndPruneExpired(at: now())
    }

    private func scanAndPruneExpired(at currentDate: Date) throws -> [StoredFile] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        let entries = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var retained: [StoredFile] = []

        for url in entries {
            let values = try url.resourceValues(forKeys: keys)
            guard url.pathExtension.lowercased() == "json",
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let byteCount = values.fileSize,
                  byteCount > 0,
                  byteCount <= 16 * 1_024 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count == byteCount else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let record = try? decoder.decode(SystemActionLocalContextRecord.self, from: data),
                  isValid(record),
                  url.deletingPathExtension().lastPathComponent == record.id.uuidString.lowercased() else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard record.retentionExpiresAt(maximumAge: retentionPolicy.maximumAge) > currentDate else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            retained.append(.init(url: url, byteCount: byteCount))
        }
        return retained
    }

    private func url(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private func isValid(_ record: SystemActionLocalContextRecord) -> Bool {
        let expiresAt = record.retentionExpiresAt(maximumAge: retentionPolicy.maximumAge)
        let maximumExpiresAt = record.observedAt
            .addingTimeInterval(retentionPolicy.maximumAge)
            .localContextMillisecondPrecision
        return record.schemaVersion == 1
            && expiresAt > record.observedAt
            && expiresAt <= maximumExpiresAt
            && record.boundedValues.count <= 16
            && record.boundedValues.allSatisfy {
                !$0.key.isEmpty
                    && $0.key.utf8.count <= 64
                    && $0.value.utf8.count <= 256
            }
    }

    nonisolated static var directoryURL: URL {
        LocalVaultLocator().vaultURL
            .appendingPathComponent("_agent", isDirectory: true)
            .appendingPathComponent("system-actions", isDirectory: true)
            .appendingPathComponent("local-context", isDirectory: true)
    }

    nonisolated static func url(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }
}

private enum SystemActionLocalContextStoreError: LocalizedError {
    case invalidRecord
    case retentionLimitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return NSLocalizedString("本地摘要超出安全边界，未保存。", comment: "")
        case .retentionLimitExceeded:
            return NSLocalizedString("本地摘要空间已满；请先处理现有待审批动作。", comment: "")
        }
    }
}

enum SystemActionLocalContextRecordFactory {
    static func photo(
        assetIdentifier: String?,
        observedAt: Date = Date(),
        fallbackReference: UUID = UUID()
    ) -> SystemActionLocalContextRecord {
        let opaqueSource = assetIdentifier.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? fallbackReference.uuidString.lowercased()
        return SystemActionLocalContextRecord(
            kind: .photo,
            observedAt: observedAt,
            boundedValues: ["asset_reference_hash": hash(opaqueSource)]
        )
    }

    static func contacts(
        referenceHashes: [String],
        observedAt: Date = Date()
    ) throws -> SystemActionLocalContextRecord {
        let unique = Array(NSOrderedSet(array: referenceHashes)).compactMap { $0 as? String }
        guard !unique.isEmpty, unique.count <= 16,
              unique.allSatisfy({ value in
                  value.utf8.count == 64 && value.utf8.allSatisfy { byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }
              }) else {
            throw SystemActionLocalContextStoreError.invalidRecord
        }
        return SystemActionLocalContextRecord(
            kind: .contactSelection,
            observedAt: observedAt,
            boundedValues: Dictionary(
                unique.enumerated().map { ("contact_reference_\($0.offset + 1)", $0.element.lowercased()) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SystemActionContextComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SystemActionCenterModel

    @State private var proposal: SystemActionProposal?
    @State private var activeKind: SystemActionLocalContextKind?
    @State private var errorMessage: String?
    @State private var stagedRecordID: UUID?
    @State private var showsPhotoPicker = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var showsContactPicker = false

    private let locationClient = AppleOneShotLocationClient()
    private let healthClient = AppleHealthContextClient()
    private let weatherClient = AppleWeatherContextClient()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("这里的读取由您的点击触发。DayPage 先在本机生成有限摘要，再让您检查一个只含本地引用 UUID 的动作提案。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("选择输入") {
                    contextButton(
                        title: "当前位置摘要",
                        detail: "一次性定位；坐标只保存在本机摘要",
                        image: "location",
                        kind: .placeSummary,
                        capability: .location,
                        action: capturePlace
                    )
                    contextButton(
                        title: "当前位置天气",
                        detail: "WeatherKit；位置与天气原始值不上云",
                        image: "cloud.sun",
                        kind: .weatherSummary,
                        capability: .weatherContext,
                        action: captureWeather
                    )
                    contextButton(
                        title: "今日步数摘要",
                        detail: "HealthKit 只读步数；不请求写入权限",
                        image: "figure.walk",
                        kind: .healthSummary,
                        capability: .healthContext,
                        action: captureHealth
                    )
                    contextSelectionButton(
                        title: "选择照片引用",
                        detail: "Photos 系统选择器；本机仅保存资源标识哈希",
                        image: "photo.on.rectangle",
                        capability: .photos
                    ) {
                        showsPhotoPicker = true
                    }
                    .photosPicker(
                        isPresented: $showsPhotoPicker,
                        selection: $photoSelection,
                        matching: .images
                    )
                    .onChange(of: photoSelection) { item in
                        guard let item else { return }
                        photoSelection = nil
                        stage(SystemActionLocalContextRecordFactory.photo(assetIdentifier: item.itemIdentifier))
                    }
                    contextSelectionButton(
                        title: "选择联系人引用",
                        detail: "Contacts 系统选择器；本机仅保存不可逆引用哈希",
                        image: "person.crop.circle.badge.checkmark",
                        capability: .contacts
                    ) {
                        showsContactPicker = true
                    }
                }

                Section("数据流") {
                    Label("Apple Framework → 本机加密保护文件", systemImage: "iphone.gen3")
                    Label("云端提案 → 类型 + UUID + 时间", systemImage: "link")
                    Label("Agent 无法读取本地摘要文件", systemImage: "lock.shield")
                }
                .font(.footnote)
            }
            .navigationTitle("添加本地上下文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $proposal, onDismiss: discardUnsavedRecord) { proposal in
                SystemActionReviewView(
                    model: model,
                    proposal: proposal,
                    isNew: true,
                    onSaved: { stagedRecordID = nil },
                    onClose: { self.proposal = nil }
                )
            }
            .sheet(isPresented: $showsContactPicker) {
                SystemActionContactPicker { hashes in
                    showsContactPicker = false
                    do {
                        stage(try SystemActionLocalContextRecordFactory.contacts(
                            referenceHashes: Array(hashes.prefix(16))
                        ))
                    } catch {
                        errorMessage = Self.bounded(error)
                    }
                } onCancel: {
                    showsContactPicker = false
                }
                .ignoresSafeArea()
            }
            .alert(
                "无法生成摘要",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .tint(DSColor.accentOnBg)
    }

    private func contextButton(
        title: String,
        detail: String,
        image: String,
        kind: SystemActionLocalContextKind,
        capability: SystemActionCapability,
        action: @escaping () async throws -> SystemActionLocalContextRecord
    ) -> some View {
        Button {
            guard model.isCapabilityOffered(capability) else {
                errorMessage = NSLocalizedString("此能力已在“系统访问”中关闭。", comment: "")
                return
            }
            activeKind = kind
            Task {
                do {
                    let record = try await action()
                    await saveAndPresent(record)
                } catch {
                    errorMessage = Self.bounded(error)
                    activeKind = nil
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: image).frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title)).foregroundStyle(.primary)
                    Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if activeKind == kind { ProgressView().controlSize(.small) }
                else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activeKind != nil)
    }

    private func contextSelectionButton(
        title: String,
        detail: String,
        image: String,
        capability: SystemActionCapability,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard model.isCapabilityOffered(capability) else {
                errorMessage = NSLocalizedString("此能力已在“系统访问”中关闭。", comment: "")
                return
            }
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: image).frame(width: 28).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title)).foregroundStyle(.primary)
                    Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activeKind != nil)
    }

    private func stage(_ record: SystemActionLocalContextRecord) {
        guard activeKind == nil else { return }
        activeKind = record.kind
        Task { await saveAndPresent(record) }
    }

    private func saveAndPresent(_ record: SystemActionLocalContextRecord) async {
        var savedRecordID: UUID?
        do {
            try await SystemActionLocalContextStore.shared.save(record)
            savedRecordID = record.id
            stagedRecordID = record.id
            proposal = try model.makeLocalContextProposal(record)
        } catch {
            if let savedRecordID {
                try? await SystemActionLocalContextStore.shared.delete(id: savedRecordID)
                if stagedRecordID == savedRecordID { stagedRecordID = nil }
            }
            errorMessage = Self.bounded(error)
        }
        activeKind = nil
    }

    private func capturePlace() async throws -> SystemActionLocalContextRecord {
        let sample = try await locationClient.requestCurrentLocation()
        return SystemActionLocalContextRecord(
            kind: .placeSummary,
            observedAt: sample.timestamp,
            boundedValues: [
                "latitude": String(format: "%.6f", sample.latitude),
                "longitude": String(format: "%.6f", sample.longitude),
                "horizontal_accuracy_m": String(format: "%.1f", sample.horizontalAccuracy)
            ]
        )
    }

    private func captureWeather() async throws -> SystemActionLocalContextRecord {
        let sample = try await locationClient.requestCurrentLocation()
        let weather = try await weatherClient.fetchConfirmedContext(
            latitude: sample.latitude,
            longitude: sample.longitude
        )
        return SystemActionLocalContextRecord(
            kind: .weatherSummary,
            observedAt: weather.observedAt,
            boundedValues: [
                "condition": String(weather.conditionCode.prefix(64)),
                "symbol": String(weather.symbolName.prefix(64)),
                "temperature_c": String(format: "%.1f", weather.temperatureCelsius),
                "apparent_c": String(format: "%.1f", weather.apparentTemperatureCelsius),
                "humidity_percent": String(Int((weather.humidity * 100).rounded()))
            ]
        )
    }

    private func captureHealth() async throws -> SystemActionLocalContextRecord {
        let end = Date()
        let start = Calendar.current.startOfDay(for: end)
        let health = try await healthClient.readConfirmedStepContext(start: start, end: end)
        return SystemActionLocalContextRecord(
            kind: .healthSummary,
            observedAt: end,
            boundedValues: [
                "window_start": ISO8601DateFormatter().string(from: health.windowStart),
                "window_end": ISO8601DateFormatter().string(from: health.windowEnd),
                "step_count": health.stepCount.map { String(Int($0.rounded())) } ?? "unavailable"
            ]
        )
    }

    private static func bounded(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty { return String(description.prefix(240)) }
        return NSLocalizedString("系统没有返回可确认的结果。请检查权限后重试。", comment: "")
    }

    private func discardUnsavedRecord() {
        guard let id = stagedRecordID else { return }
        stagedRecordID = nil
        Task {
            try? await SystemActionLocalContextStore.shared.delete(id: id)
        }
    }
}
