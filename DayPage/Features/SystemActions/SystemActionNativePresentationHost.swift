import ContactsUI
import CoreTransferable
import CryptoKit
import EventKitUI
import AVFoundation
import PhotosUI
import PencilKit
import SwiftUI
import UniformTypeIdentifiers
import VisionKit
import DayPageModels
import DayPageStorage

/// Foreground-only presentation rail for approved native effects. It lives on
/// the review sheet so Apple editors are always presented from the surface that
/// displays the exact revision and payload hash being executed.
private struct SystemActionNativePresentationModifier: ViewModifier {
    @ObservedObject private var broker = SystemActionUIBroker.shared

    func body(content: Content) -> some View {
        content.sheet(item: presentationBinding) { presentation in
            switch presentation.content {
            case .calendarEditor(let controller):
                SystemActionControllerHost(controller: controller).ignoresSafeArea()
            case .contactEditor(let controller):
                SystemActionControllerHost(
                    controller: UINavigationController(rootViewController: controller)
                )
                .ignoresSafeArea()
            case .capture(let request):
                SystemActionCaptureView(request: request, broker: broker)
            }
        }
    }

    private var presentationBinding: Binding<SystemActionUIPresentation?> {
        Binding(
            get: { broker.activePresentation },
            set: { value in
                guard value == nil, let active = broker.activePresentation else { return }
                broker.cancel(presentationID: active.id)
            }
        )
    }
}

extension View {
    func systemActionNativePresentations() -> some View {
        modifier(SystemActionNativePresentationModifier())
    }
}

private struct SystemActionControllerHost: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// CNContactPicker is the user-mediated read boundary for Moment relations.
/// DayPage retains only SHA-256 references, never names, phone numbers or
/// addresses in the proposal or cloud ledger.
struct SystemActionContactPicker: UIViewControllerRepresentable {
    let onComplete: ([String]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let controller = CNContactPickerViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: SystemActionContactPicker
        init(parent: SystemActionContactPicker) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            parent.onComplete(contacts.prefix(20).map { contact in
                SHA256.hash(data: Data(contact.identifier.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
            })
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}

/// A PhotosPicker transfer that immediately copies the provider-owned file to
/// an app temporary URL with a hard byte limit. The selected image is never
/// materialized as `Data` merely to move it into the protected Vault.
private struct SystemActionImportedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("system-action-photo-\(UUID().uuidString.lowercased())")
            do {
                _ = try SystemActionBoundedFileCopier.copy(
                    from: received.file,
                    to: target,
                    maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
                )
                return Self(url: target)
            } catch {
                try? FileManager.default.removeItem(at: target)
                throw error
            }
        }
    }
}

private struct SystemActionCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    let request: SystemActionCaptureUIRequest
    let broker: SystemActionUIBroker

    @State private var photoSelection: PhotosPickerItem?
    @State private var showsFileImporter = false
    @State private var showsDocumentScanner = false
    @State private var showsTextScanner = false
    @State private var showsInkCanvas = false
    @State private var showsTextEditor = false
    @State private var showsCamera = false
    @State private var showsVoiceRecorder = false
    @State private var isPersisting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(request.suggestedTitle ?? request.kind.displayName).font(.headline)
                            Text("只有您在此页面选取或创建的内容会保存到 DayPage 本机目录。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: request.kind.systemImage).foregroundStyle(.tint)
                    }
                }

                Section("采集方式") { captureControl }

                Section {
                    Label("原始内容不进入云端动作账本", systemImage: "icloud.slash")
                    Label("回执只记录类型、大小与页数等有限元数据", systemImage: "checkmark.shield")
                    if request.attachesToSource, request.sourceMemoID != nil {
                        Label("完成后可由您附加到已验证的来源 memo", systemImage: "paperclip")
                    } else {
                        Label("完成后先进入收件箱，由您选择归档位置", systemImage: "tray")
                    }
                } header: {
                    Text("隐私边界")
                }
                .font(.footnote)
            }
            .navigationTitle("完成采集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        broker.cancel(presentationID: request.presentationID)
                        dismiss()
                    }
                    .disabled(isPersisting)
                }
            }
            .overlay {
                if isPersisting {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        ProgressView("正在安全保存…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await persistImportedFile(url) }
                case .failure(let error):
                    errorMessage = bounded(error.localizedDescription)
                }
            }
            .sheet(isPresented: $showsDocumentScanner) {
                SystemActionDocumentScanner { images in
                    showsDocumentScanner = false
                    Task { await persistDocument(images) }
                } onCancel: {
                    showsDocumentScanner = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showsInkCanvas) {
                SystemActionInkCanvas { drawing in
                    showsInkCanvas = false
                    Task {
                        await persist(
                            data: drawing.dataRepresentation(),
                            fileExtension: "drawing",
                            contentType: "com.apple.pencilkit.drawing"
                        )
                    }
                } onCancel: {
                    showsInkCanvas = false
                }
            }
            .sheet(isPresented: $showsTextScanner) {
                if #available(iOS 16.0, *) {
                    SystemActionTextScanner { text in
                        showsTextScanner = false
                        Task {
                            await persist(
                                data: Data(text.utf8),
                                fileExtension: "txt",
                                contentType: UTType.plainText.identifier,
                                characterCount: text.count
                            )
                        }
                    } onCancel: {
                        showsTextScanner = false
                    }
                    .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $showsTextEditor) {
                SystemActionTextCapture { text in
                    showsTextEditor = false
                    Task {
                        await persist(
                            data: Data(text.utf8),
                            fileExtension: "txt",
                            contentType: UTType.plainText.identifier,
                            characterCount: text.count
                        )
                    }
                } onCancel: {
                    showsTextEditor = false
                }
            }
            .sheet(isPresented: $showsCamera) {
                SystemActionCameraCapture { data, width, height in
                    showsCamera = false
                    Task {
                        await persist(
                            data: data,
                            fileExtension: "jpg",
                            contentType: UTType.jpeg.identifier,
                            pixelWidth: width,
                            pixelHeight: height
                        )
                    }
                } onCancel: {
                    showsCamera = false
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showsVoiceRecorder) {
                SystemActionVoiceCapture { data in
                    showsVoiceRecorder = false
                    Task {
                        await persist(
                            data: data,
                            fileExtension: "m4a",
                            contentType: UTType.mpeg4Audio.identifier
                        )
                    }
                } onCancel: {
                    showsVoiceRecorder = false
                }
            }
            .alert(
                "采集未完成",
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

    @ViewBuilder
    private var captureControl: some View {
        switch request.kind {
        case .text:
            Button { showsTextEditor = true } label: {
                Label("打开文本编辑器", systemImage: "text.cursor")
            }
        case .photo:
            PhotosPicker(selection: $photoSelection, matching: .images) {
                Label("从系统照片选择器选一张", systemImage: "photo.on.rectangle")
            }
            .onChange(of: photoSelection) { item in
                guard let item else { return }
                Task { await persistPhoto(item) }
            }
        case .camera:
            Button {
                guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                    errorMessage = "此设备没有可用相机。"
                    return
                }
                showsCamera = true
            } label: {
                Label("打开相机", systemImage: "camera")
            }
        case .document:
            Button {
                guard VNDocumentCameraViewController.isSupported else {
                    errorMessage = "此设备不支持文档扫描。"
                    return
                }
                showsDocumentScanner = true
            } label: {
                Label("打开文档扫描器", systemImage: "doc.viewfinder")
            }
        case .textScan:
            Button {
                guard #available(iOS 16.0, *),
                      DataScannerViewController.isSupported,
                      DataScannerViewController.isAvailable else {
                    errorMessage = NSLocalizedString("此设备当前无法使用实时文字扫描。", comment: "")
                    return
                }
                showsTextScanner = true
            } label: {
                Label("打开实时文字扫描", systemImage: "text.viewfinder")
            }
        case .ink:
            Button { showsInkCanvas = true } label: {
                Label("打开 Pencil 画布", systemImage: "pencil.and.scribble")
            }
        case .file:
            Button { showsFileImporter = true } label: {
                Label("从“文件”选择", systemImage: "folder")
            }
        case .voice:
            Button { showsVoiceRecorder = true } label: {
                Label("打开语音采集", systemImage: "waveform")
            }
        }
    }

    private func persistPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let imported = try await item.loadTransferable(type: SystemActionImportedPhoto.self) else {
                throw SystemActionCaptureStoreError.emptyInput
            }
            defer { try? FileManager.default.removeItem(at: imported.url) }
            let type = item.supportedContentTypes.first ?? .image
            await persist(
                fileURL: imported.url,
                fileExtension: type.preferredFilenameExtension ?? "image",
                contentType: type.identifier
            )
        } catch {
            errorMessage = bounded(error.localizedDescription)
        }
    }

    private func persistImportedFile(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            if let size = values.fileSize,
               size > SystemActionCaptureArtifact.maximumByteCount {
                throw SystemActionCaptureStoreError.tooLarge
            }
            let type = values.contentType ?? .data
            let fallback = url.pathExtension.isEmpty ? "data" : url.pathExtension
            await persist(
                fileURL: url,
                fileExtension: type.preferredFilenameExtension ?? fallback,
                contentType: type.identifier
            )
        } catch {
            errorMessage = bounded(error.localizedDescription)
        }
    }

    private func persistDocument(_ images: [UIImage]) async {
        guard let first = images.first else {
            errorMessage = NSLocalizedString("扫描器没有返回页面。", comment: "")
            return
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first.size))
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-action-scan-\(UUID().uuidString.lowercased()).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try renderer.writePDF(to: temporaryURL) { context in
                for image in images {
                    let bounds = CGRect(origin: .zero, size: image.size)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    image.draw(in: bounds)
                }
            }
            await persist(
                fileURL: temporaryURL,
                fileExtension: "pdf",
                contentType: UTType.pdf.identifier,
                pageCount: images.count
            )
        } catch {
            errorMessage = bounded(error.localizedDescription)
        }
    }

    @MainActor
    private func persist(
        data: Data,
        fileExtension: String,
        contentType: String,
        pageCount: Int? = nil,
        characterCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) async {
        guard !isPersisting else { return }
        isPersisting = true
        defer { isPersisting = false }
        do {
            let artifact = try await SystemActionCaptureStore.shared.persist(
                data: data,
                request: request,
                fileExtension: fileExtension,
                contentType: contentType,
                pageCount: pageCount,
                characterCount: characterCount,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            broker.completeCapture(presentationID: request.presentationID, artifact: artifact)
            dismiss()
        } catch {
            errorMessage = bounded(error.localizedDescription)
        }
    }

    @MainActor
    private func persist(
        fileURL: URL,
        fileExtension: String,
        contentType: String,
        pageCount: Int? = nil,
        characterCount: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) async {
        guard !isPersisting else { return }
        isPersisting = true
        defer { isPersisting = false }
        do {
            let artifact = try await SystemActionCaptureStore.shared.persist(
                fileURL: fileURL,
                request: request,
                fileExtension: fileExtension,
                contentType: contentType,
                pageCount: pageCount,
                characterCount: characterCount,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            broker.completeCapture(presentationID: request.presentationID, artifact: artifact)
            dismiss()
        } catch {
            errorMessage = bounded(error.localizedDescription)
        }
    }

    private func bounded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty
            ? NSLocalizedString("无法读取或保存所选内容。", comment: "")
            : trimmed).prefix(240))
    }

}

struct SystemActionCaptureInboxRecord: Codable, Sendable, Equatable, Identifiable {
    let schemaVersion: Int
    let id: UUID
    let actionID: UUID
    let createdAt: Date
    let suggestedTitle: String?
    let attachesToSource: Bool
    let sourceMemoID: UUID?
    let kind: SystemActionCaptureKind
    let relativePath: String
    let uniformTypeIdentifier: String
    let byteCount: Int
    let contentSHA256: String
    let filedMemoID: UUID?
    let filedDestination: SystemActionCaptureFilingDestination?
}

enum SystemActionCaptureFilingDestination: String, Codable, Sendable, Equatable {
    case sourceMemo = "source_memo"
    case newMemo = "new_memo"
}

protocol SystemActionCaptureFiling: Sendable {
    func fileAsNewMemo(record: SystemActionCaptureInboxRecord, sourceURL: URL) throws -> UUID
    func attachToSourceMemo(record: SystemActionCaptureInboxRecord, sourceURL: URL) throws -> UUID
}

/// The only bridge from the protected operational inbox into user-authored
/// Vault content. Filing is explicit and uses deterministic IDs/asset paths so
/// a crash after the Vault write but before the inbox manifest update recovers
/// without creating a second memo or attachment.
struct SystemActionCaptureVaultFiler: SystemActionCaptureFiling {
    func fileAsNewMemo(record: SystemActionCaptureInboxRecord, sourceURL: URL) throws -> UUID {
        let prepared = try prepareAttachment(record: record, sourceURL: sourceURL)
        do {
            if let existing = RawStorage.memo(id: record.id) {
                guard existing.attachments.contains(where: { $0.file == prepared.attachment.file }) else {
                    throw SystemActionCaptureStoreError.filingConflict
                }
                return existing.id
            }
            let memoType: Memo.MemoType
            switch prepared.attachment.kind {
            case "photo": memoType = .photo
            case "audio": memoType = .voice
            default: memoType = .mixed
            }
            let memo = Memo(
                id: record.id,
                type: memoType,
                created: Date(),
                attachments: [prepared.attachment],
                body: record.suggestedTitle ?? NSLocalizedString("系统动作采集", comment: "")
            )
            try RawStorage.append(memo)
            return memo.id
        } catch {
            if prepared.created,
               RawStorage.memo(id: record.id)?.attachments.contains(where: {
                   $0.file == prepared.attachment.file
               }) != true {
                try? FileManager.default.removeItem(at: prepared.destinationURL)
            }
            throw error
        }
    }

    func attachToSourceMemo(record: SystemActionCaptureInboxRecord, sourceURL: URL) throws -> UUID {
        guard record.attachesToSource, let sourceMemoID = record.sourceMemoID else {
            throw SystemActionCaptureStoreError.sourceMemoMissing
        }
        let prepared = try prepareAttachment(record: record, sourceURL: sourceURL)
        do {
            guard try RawStorage.appendAttachment(
                prepared.attachment,
                toMemoID: sourceMemoID
            ) != nil else {
                throw SystemActionCaptureStoreError.sourceMemoMissing
            }
            return sourceMemoID
        } catch {
            if prepared.created,
               RawStorage.memo(id: sourceMemoID)?.attachments.contains(where: {
                   $0.file == prepared.attachment.file
               }) != true {
                try? FileManager.default.removeItem(at: prepared.destinationURL)
            }
            throw error
        }
    }

    private func prepareAttachment(
        record: SystemActionCaptureInboxRecord,
        sourceURL: URL
    ) throws -> (attachment: Memo.Attachment, destinationURL: URL, created: Bool) {
        let sourceDigest = try SystemActionFileDigest.sha256(
            fileURL: sourceURL,
            maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
        )
        guard sourceDigest.byteCount == record.byteCount,
              sourceDigest.hash == record.contentSHA256 else {
            throw SystemActionCaptureStoreError.filingConflict
        }
        let sourceExtension = sourceURL.pathExtension.isEmpty ? "data" : sourceURL.pathExtension
        let filename = "capture_\(record.id.uuidString.lowercased()).\(sourceExtension)"
        let destination = try VaultInitializer.assetsDirectory().appendingPathComponent(filename)
        let attachmentKind: String
        switch record.kind {
        case .photo, .camera: attachmentKind = "photo"
        case .voice: attachmentKind = "audio"
        default: attachmentKind = "file"
        }
        let attachment = Memo.Attachment(
            file: "raw/assets/\(filename)",
            kind: attachmentKind
        )

        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  values.fileSize == record.byteCount,
                  try SystemActionFileDigest.sha256(
                    fileURL: destination,
                    maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
                  ).hash == record.contentSHA256 else {
                throw SystemActionCaptureStoreError.filingConflict
            }
            return (attachment, destination, false)
        }
        let copiedByteCount = try SystemActionBoundedFileCopier.copy(
            from: sourceURL,
            to: destination,
            maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
        )
        let copiedDigest = try SystemActionFileDigest.sha256(
            fileURL: destination,
            maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
        )
        guard copiedByteCount == record.byteCount,
              copiedDigest.byteCount == record.byteCount,
              copiedDigest.hash == record.contentSHA256 else {
            try? FileManager.default.removeItem(at: destination)
            throw SystemActionCaptureStoreError.filingConflict
        }
        return (attachment, destination, true)
    }
}

actor SystemActionCaptureStore {
    static let shared = SystemActionCaptureStore()
    private let vaultRootURL: URL
    private let filer: any SystemActionCaptureFiling

    init(
        vaultRootURL: URL = LocalVaultLocator().vaultURL,
        filer: any SystemActionCaptureFiling = SystemActionCaptureVaultFiler()
    ) {
        self.vaultRootURL = vaultRootURL.standardizedFileURL
        self.filer = filer
    }

    func persist(
        data: Data,
        request: SystemActionCaptureUIRequest,
        fileExtension: String,
        contentType: String,
        pageCount: Int?,
        characterCount: Int?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws -> SystemActionCaptureArtifact {
        guard !data.isEmpty else { throw SystemActionCaptureStoreError.emptyInput }
        guard data.count <= SystemActionCaptureArtifact.maximumByteCount else {
            throw SystemActionCaptureStoreError.tooLarge
        }
        let safeExtension = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !safeExtension.isEmpty, safeExtension.count <= 12 else {
            throw SystemActionCaptureStoreError.invalidType
        }
        let captureID = UUID()
        let relativePath = "_agent/system-actions/captures/\(request.actionID.uuidString.lowercased())/\(captureID.uuidString.lowercased()).\(safeExtension)"
        let target = vaultRootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        let contentSHA256 = SystemActionFileDigest.sha256(data: data)
        let artifact = SystemActionCaptureArtifact(
            kind: request.kind,
            relativePath: relativePath,
            uniformTypeIdentifier: contentType,
            byteCount: data.count,
            pageCount: pageCount,
            characterCount: characterCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        do {
            try writeInboxRecord(.init(
                schemaVersion: 1,
                id: captureID,
                actionID: request.actionID,
                createdAt: Date(),
                suggestedTitle: request.suggestedTitle,
                attachesToSource: request.attachesToSource,
                sourceMemoID: request.sourceMemoID,
                kind: request.kind,
                relativePath: relativePath,
                uniformTypeIdentifier: contentType,
                byteCount: data.count,
                contentSHA256: contentSHA256,
                filedMemoID: nil,
                filedDestination: nil
            ))
            return artifact
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func persist(
        fileURL: URL,
        request: SystemActionCaptureUIRequest,
        fileExtension: String,
        contentType: String,
        pageCount: Int?,
        characterCount: Int?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws -> SystemActionCaptureArtifact {
        let safeExtension = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !safeExtension.isEmpty, safeExtension.count <= 12 else {
            throw SystemActionCaptureStoreError.invalidType
        }
        let captureID = UUID()
        let relativePath = "_agent/system-actions/captures/\(request.actionID.uuidString.lowercased())/\(captureID.uuidString.lowercased()).\(safeExtension)"
        let target = vaultRootURL.appendingPathComponent(relativePath)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let staging = directory.appendingPathComponent(".\(UUID().uuidString.lowercased()).partial")
        defer { try? FileManager.default.removeItem(at: staging) }
        let byteCount = try SystemActionBoundedFileCopier.copy(
            from: fileURL,
            to: staging,
            maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: staging.path
        )
        try FileManager.default.moveItem(at: staging, to: target)
        let contentDigest = try SystemActionFileDigest.sha256(
            fileURL: target,
            maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
        )
        guard contentDigest.byteCount == byteCount else {
            try? FileManager.default.removeItem(at: target)
            throw SystemActionCaptureStoreError.filingConflict
        }
        let artifact = SystemActionCaptureArtifact(
            kind: request.kind,
            relativePath: relativePath,
            uniformTypeIdentifier: contentType,
            byteCount: byteCount,
            pageCount: pageCount,
            characterCount: characterCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        do {
            try writeInboxRecord(.init(
                schemaVersion: 1,
                id: captureID,
                actionID: request.actionID,
                createdAt: Date(),
                suggestedTitle: request.suggestedTitle,
                attachesToSource: request.attachesToSource,
                sourceMemoID: request.sourceMemoID,
                kind: request.kind,
                relativePath: relativePath,
                uniformTypeIdentifier: contentType,
                byteCount: byteCount,
                contentSHA256: contentDigest.hash,
                filedMemoID: nil,
                filedDestination: nil
            ))
            return artifact
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func recent(limit: Int = 50) -> [SystemActionCaptureInboxRecord] {
        let root = vaultRootURL
            .appendingPathComponent("_agent/system-actions/captures", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var records: [SystemActionCaptureInboxRecord] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".capture.json") {
            guard records.count < 200,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 16 * 1_024,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let record = try? Self.decoder.decode(SystemActionCaptureInboxRecord.self, from: data),
                  validate(record),
                  fileURL(for: record).standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let assetValues = try? fileURL(for: record).resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                  ),
                  assetValues.isRegularFile == true,
                  assetValues.isSymbolicLink != true,
                  assetValues.fileSize == record.byteCount,
                  (try? SystemActionFileDigest.sha256(
                    fileURL: fileURL(for: record),
                    maximumByteCount: SystemActionCaptureArtifact.maximumByteCount
                  )) == .init(hash: record.contentSHA256, byteCount: record.byteCount) else {
                continue
            }
            records.append(record)
        }
        return Array(records.sorted { $0.createdAt > $1.createdAt }.prefix(max(0, limit)))
    }

    func fileURL(for record: SystemActionCaptureInboxRecord) -> URL {
        vaultRootURL.appendingPathComponent(record.relativePath)
    }

    /// Explicit, user-confirmed deletion of the recoverable staging copy. If
    /// it was already filed, the normal Vault attachment remains untouched.
    func discard(id: UUID) throws {
        guard let record = recent(limit: 200).first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let asset = fileURL(for: record)
        let manifest = asset.appendingPathExtension("capture.json")
        let manifestData = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        do {
            try FileManager.default.removeItem(at: asset)
            let directory = asset.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: directory)
            }
        } catch {
            try? manifestData.write(
                to: manifest,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            throw error
        }
    }

    /// Account-bound operational material must not survive a sign-out or
    /// identity transition. The exact scoped directory cannot contain Vault
    /// raw Markdown or user-authored attachments.
    func clearAll() throws {
        let root = vaultRootURL
            .appendingPathComponent("_agent/system-actions/captures", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    /// Explicit filing is a normal user-authored Vault mutation, separate from
    /// action execution. This keeps the action ledger out of raw Markdown while
    /// ensuring a staged capture is recoverable and can become a visible memo.
    func fileAsNewMemo(id: UUID) throws -> UUID {
        guard var record = recent(limit: 200).first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let filedMemoID = record.filedMemoID { return filedMemoID }
        let memoID = try filer.fileAsNewMemo(record: record, sourceURL: fileURL(for: record))
        record = filedRecord(record, memoID: memoID, destination: .newMemo)
        try writeInboxRecord(record)
        return memoID
    }

    func fileToSourceMemo(id: UUID) throws -> UUID {
        guard var record = recent(limit: 200).first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if let filedMemoID = record.filedMemoID { return filedMemoID }
        let memoID = try filer.attachToSourceMemo(record: record, sourceURL: fileURL(for: record))
        record = filedRecord(record, memoID: memoID, destination: .sourceMemo)
        try writeInboxRecord(record)
        return memoID
    }

    private func filedRecord(
        _ record: SystemActionCaptureInboxRecord,
        memoID: UUID,
        destination: SystemActionCaptureFilingDestination
    ) -> SystemActionCaptureInboxRecord {
        .init(
            schemaVersion: record.schemaVersion,
            id: record.id,
            actionID: record.actionID,
            createdAt: record.createdAt,
            suggestedTitle: record.suggestedTitle,
            attachesToSource: record.attachesToSource,
            sourceMemoID: record.sourceMemoID,
            kind: record.kind,
            relativePath: record.relativePath,
            uniformTypeIdentifier: record.uniformTypeIdentifier,
            byteCount: record.byteCount,
            contentSHA256: record.contentSHA256,
            filedMemoID: memoID,
            filedDestination: destination
        )
    }

    private func writeInboxRecord(_ record: SystemActionCaptureInboxRecord) throws {
        guard validate(record) else { throw SystemActionCaptureStoreError.invalidType }
        let assetURL = fileURL(for: record)
        let manifest = assetURL.appendingPathExtension("capture.json")
        let data = try Self.encoder.encode(record)
        guard data.count <= 16 * 1_024 else { throw SystemActionCaptureStoreError.tooLarge }
        try data.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func validate(_ record: SystemActionCaptureInboxRecord) -> Bool {
        record.schemaVersion == 1
            && record.relativePath.hasPrefix("_agent/system-actions/captures/\(record.actionID.uuidString.lowercased())/")
            && !record.relativePath.contains("..")
            && (1...SystemActionCaptureArtifact.maximumByteCount).contains(record.byteCount)
            && record.contentSHA256.count == 64
            && record.contentSHA256.allSatisfy { "0123456789abcdef".contains($0) }
            && record.uniformTypeIdentifier.utf8.count <= 128
            && ((record.filedMemoID == nil) == (record.filedDestination == nil))
            && (record.filedDestination != .sourceMemo || record.sourceMemoID == record.filedMemoID)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum SystemActionBoundedFileCopier {
    private static let chunkByteCount = 64 * 1_024

    @discardableResult
    static func copy(from source: URL, to destination: URL, maximumByteCount: Int) throws -> Int {
        guard maximumByteCount > 0 else { throw SystemActionCaptureStoreError.tooLarge }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var byteCount = 0
        do {
            while let chunk = try input.read(upToCount: Self.chunkByteCount), !chunk.isEmpty {
                guard byteCount <= maximumByteCount - chunk.count else {
                    throw SystemActionCaptureStoreError.tooLarge
                }
                try output.write(contentsOf: chunk)
                byteCount += chunk.count
            }
            guard byteCount > 0 else { throw SystemActionCaptureStoreError.emptyInput }
            try output.synchronize()
            return byteCount
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

struct SystemActionFileDigest: Equatable {
    let hash: String
    let byteCount: Int

    static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(fileURL: URL, maximumByteCount: Int) throws -> SystemActionFileDigest {
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let expectedSize = values.fileSize,
              expectedSize > 0,
              expectedSize <= maximumByteCount else {
            throw SystemActionCaptureStoreError.filingConflict
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard byteCount <= maximumByteCount - chunk.count else {
                throw SystemActionCaptureStoreError.tooLarge
            }
            hasher.update(data: chunk)
            byteCount += chunk.count
        }
        guard byteCount == expectedSize else {
            throw SystemActionCaptureStoreError.filingConflict
        }
        return .init(
            hash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            byteCount: byteCount
        )
    }
}

private enum SystemActionCaptureStoreError: LocalizedError {
    case emptyInput
    case tooLarge
    case invalidType
    case sourceMemoMissing
    case filingConflict

    var errorDescription: String? {
        switch self {
        case .emptyInput: return NSLocalizedString("没有可保存的内容。", comment: "")
        case .tooLarge: return NSLocalizedString("所选内容超过 100 MB 上限。", comment: "")
        case .invalidType: return NSLocalizedString("无法确认所选内容的文件类型。", comment: "")
        case .sourceMemoMissing: return NSLocalizedString("找不到提案引用的来源 memo；可改为保存为新 memo。", comment: "")
        case .filingConflict: return NSLocalizedString("归档目标与现有文件不一致，已停止以避免覆盖。", comment: "")
        }
    }
}

private struct SystemActionDocumentScanner: UIViewControllerRepresentable {
    let onComplete: ([UIImage]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: SystemActionDocumentScanner
        init(parent: SystemActionDocumentScanner) { self.parent = parent }
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) { parent.onComplete((0..<scan.pageCount).map(scan.imageOfPage(at:))) }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) { parent.onCancel() }
    }
}

private struct SystemActionTextCapture: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle("文本采集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { onCancel(); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onComplete(String(text.prefix(1_000_000)))
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct SystemActionCameraCapture: UIViewControllerRepresentable {
    let onComplete: (Data, Int, Int) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemActionCameraCapture
        init(parent: SystemActionCameraCapture) { self.parent = parent }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.92) else {
                parent.onCancel()
                return
            }
            parent.onComplete(data, Int(image.size.width * image.scale), Int(image.size.height * image.scale))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel() }
    }
}

private struct SystemActionVoiceCapture: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: (Data) -> Void
    let onCancel: () -> Void
    @StateObject private var recorder = SystemActionVoiceRecorder()

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 68, weight: .light))
                    .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
                Text(LocalizedStringKey(recorder.isRecording ? "正在录音" : "准备采集一段语音"))
                    .font(.headline)
                Text("音频先写入临时文件；确认后才移动到 DayPage 本机目录。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    Task {
                        if recorder.isRecording {
                            if let data = recorder.stopAndRead() { onComplete(data); dismiss() }
                        } else {
                            await recorder.start()
                        }
                    }
                } label: {
                    Label(
                        LocalizedStringKey(recorder.isRecording ? "停止并保存" : "开始录音"),
                        systemImage: recorder.isRecording ? "stop.fill" : "mic.fill"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 36)
                if let error = recorder.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("语音采集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { recorder.cancel(); onCancel(); dismiss() }
                }
            }
        }
    }
}

@MainActor
private final class SystemActionVoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var temporaryURL: URL?

    func start() async {
        guard !isRecording else { return }
        do {
            guard await requestPermission() else {
                errorMessage = NSLocalizedString("麦克风权限未允许。", comment: "")
                return
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("system-action-\(UUID().uuidString.lowercased()).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.prepareToRecord()
            guard recorder.record() else { throw SystemActionVoiceRecorderError.startFailed }
            self.recorder = recorder
            temporaryURL = url
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = NSLocalizedString("无法开始录音。", comment: "")
            cancel()
        }
    }

    func stopAndRead() -> Data? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let url = temporaryURL else { return nil }
        temporaryURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        defer { try? AVAudioSession.sharedInstance().setActive(false) }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let limit = SystemActionCaptureArtifact.maximumByteCount
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                errorMessage = NSLocalizedString("所选内容超过 100 MB 上限。", comment: "")
                return nil
            }
            return data
        } catch {
            errorMessage = NSLocalizedString("无法读取或保存所选内容。", comment: "")
            return nil
        }
    }

    func cancel() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        temporaryURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

private enum SystemActionVoiceRecorderError: Error { case startFailed }

private struct SystemActionInkCanvas: View {
    @Environment(\.dismiss) private var dismiss
    let onComplete: (PKDrawing) -> Void
    let onCancel: () -> Void
    @State private var drawing = PKDrawing()

    var body: some View {
        NavigationStack {
            SystemActionPKCanvas(drawing: $drawing)
                .background(Color(uiColor: .systemBackground))
                .navigationTitle("Pencil 采集")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { onCancel(); dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { onComplete(drawing); dismiss() }
                            .disabled(drawing.strokes.isEmpty)
                    }
                }
        }
    }
}

private struct SystemActionPKCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .label, width: 5)
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding var drawing: PKDrawing
        init(drawing: Binding<PKDrawing>) { _drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { drawing = canvasView.drawing }
    }
}

@available(iOS 16.0, *)
private struct SystemActionTextScanner: UIViewControllerRepresentable {
    let onComplete: (String) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UINavigationController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: true,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        context.coordinator.scanner = scanner
        scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("取消", comment: ""),
            style: .plain,
            target: context.coordinator,
            action: #selector(Coordinator.cancel)
        )
        scanner.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: NSLocalizedString("使用文字", comment: ""),
            style: .done,
            target: context.coordinator,
            action: #selector(Coordinator.complete)
        )
        let navigation = UINavigationController(rootViewController: scanner)
        Task { @MainActor in try? scanner.startScanning() }
        return navigation
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: SystemActionTextScanner
        weak var scanner: DataScannerViewController?
        private var recognizedText = ""
        init(parent: SystemActionTextScanner) { self.parent = parent }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) { update(allItems) }
        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) { update(allItems) }

        @objc func cancel() { parent.onCancel() }
        @objc func complete() {
            let value = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            parent.onComplete(String(value.prefix(1_000_000)))
        }
        private func update(_ items: [RecognizedItem]) {
            recognizedText = items.compactMap { item in
                if case .text(let text) = item { return text.transcript }
                return nil
            }.joined(separator: "\n")
            scanner?.navigationItem.rightBarButtonItem?.isEnabled = !recognizedText.isEmpty
        }
    }
}

extension SystemActionCaptureKind {
    var displayName: String {
        switch self {
        case .text: return NSLocalizedString("文本", comment: "")
        case .photo: return NSLocalizedString("照片", comment: "")
        case .camera: return NSLocalizedString("相机", comment: "")
        case .document: return NSLocalizedString("文档扫描", comment: "")
        case .textScan: return NSLocalizedString("文字扫描", comment: "")
        case .ink: return NSLocalizedString("Pencil 手写", comment: "")
        case .file: return NSLocalizedString("文件", comment: "")
        case .voice: return NSLocalizedString("语音", comment: "")
        }
    }
    var systemImage: String {
        switch self {
        case .text: return "text.cursor"
        case .photo: return "photo.on.rectangle"
        case .camera: return "camera"
        case .document: return "doc.viewfinder"
        case .textScan: return "text.viewfinder"
        case .ink: return "pencil.and.scribble"
        case .file: return "folder"
        case .voice: return "waveform"
        }
    }
}
