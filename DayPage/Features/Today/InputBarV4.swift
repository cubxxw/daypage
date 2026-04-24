import SwiftUI
import CoreLocation
import PhotosUI
import UIKit

// MARK: - InputBarV4  "Silent Press-to-Talk"
//
// Design variant D: frosted-glass capsule (ultraThinMaterial) as the voice
// primary CTA, morphing to a text editor via matchedGeometryEffect.
//
// States:
//   collapsed  — capsule: mic icon + "Hold to talk … or tap to write ›"
//   composing  — capsule expands to TextEditor; mic hidden
//   recording  — PressToTalk overlay; capsule stays visible
//
// Bottom shelf has three secondary actions: Notes, Attach (+), Camera.
// Long-press semantics reuse PressToTalkButton / PressToTalkPhase from V2/V3.

struct InputBarV4: View {

    // MARK: Bindings (identical surface to V2/V3)

    @Binding var text: String
    var isSubmitting: Bool
    var isLocating: Bool
    var pendingLocation: Memo.Location?
    var locationAuthStatus: CLAuthorizationStatus
    var isProcessingPhoto: Bool
    var pendingAttachments: [PendingAttachment]
    var onFetchLocation: () -> Void
    var onClearLocation: () -> Void
    var onAddPhoto: (PhotosPickerItem) -> Void
    var onCapturePhoto: () -> Void
    var onRemoveAttachment: (String) -> Void
    var onStartVoiceRecording: () -> Void
    var onVoiceComplete: (VoiceRecordingResult) -> Void
    var onPressToTalkSend: (VoiceRecordingResult) -> Void
    var onPressToTalkTranscribe: (String) -> Void
    var onAddFile: () -> Void
    var onSubmit: () -> Void

    // MARK: Private State

    @FocusState private var isFocused: Bool
    @State private var showAttachmentMenu: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var pressToTalkPhase: PressToTalkPhase = .idle
    @State private var userExpandedText: Bool = false

    @StateObject private var voiceService = VoiceService.shared

    @Namespace private var morphNS

    // MARK: Derived

    private var isComposing: Bool {
        userExpandedText || !text.isEmpty || !pendingAttachments.isEmpty || pendingLocation != nil
    }

    private var overlayMode: RecordingOverlayMode? {
        switch pressToTalkPhase {
        case .idle:           return nil
        case .recording:      return .recording
        case .cancelArmed:    return .cancelArmed
        case .transcribeArmed: return .transcribeArmed
        case .transcribing:   return .transcribing
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if let mode = overlayMode {
                RecordingOverlayView(
                    mode: mode,
                    elapsedSeconds: voiceService.elapsedSeconds,
                    waveform: voiceService.waveformHistory
                )
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: mode)
            }

            Rectangle()
                .fill(DSColor.outlineVariant.opacity(0.5))
                .frame(height: 0.5)

            if !pendingAttachments.isEmpty {
                attachmentPreviewRow
            }

            if let loc = pendingLocation {
                locationChipRow(loc: loc)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if isComposing {
                    composingCapsule
                } else {
                    collapsedCapsule
                }
                sendButton
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isComposing)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            bottomShelf
                .padding(.bottom, 4)
        }
        .background(DSColor.backgroundWarm)
        .sheet(isPresented: $showAttachmentMenu) {
            AttachmentMenuPopover(
                onCapturePhoto: { showAttachmentMenu = false; onCapturePhoto() },
                onPickPhoto: { showAttachmentMenu = false },
                onAddFile: { showAttachmentMenu = false; onAddFile() },
                onAddLocation: { showAttachmentMenu = false; onFetchLocation() },
                isLocating: isLocating,
                hasPendingLocation: pendingLocation != nil
            )
        }
        .onChange(of: photosPickerItem) { newItem in
            guard let item = newItem else { return }
            onAddPhoto(item)
            photosPickerItem = nil
        }
    }

    // MARK: - Collapsed Capsule

    private var collapsedCapsule: some View {
        // Tap anywhere on capsule → expand to text mode
        // Long-press on mic area (right side overlay) → voice recording
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    userExpandedText = true
                }
                isFocused = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "mic")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DSColor.onBackgroundPrimary)

                    Text("Hold to talk")
                        .font(.custom("SpaceGrotesk-Medium", size: 15))
                        .foregroundStyle(DSColor.onBackgroundPrimary)

                    Spacer(minLength: 0)

                    Text("or tap to write  ›")
                        .font(.custom("SpaceGrotesk-Regular", size: 13))
                        .foregroundStyle(DSColor.onBackgroundSubtle)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DSColor.outlineVariant.opacity(0.5), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Invisible press-to-talk overlay on the right quarter
            PressToTalkButton(
                onTap: {},
                onPressStart: handlePressToTalkStart,
                onReleaseSend: handlePressToTalkReleaseSend,
                onReleaseCancel: handlePressToTalkReleaseCancel,
                onReleaseTranscribe: handlePressToTalkReleaseTranscribe,
                onPhaseChange: { pressToTalkPhase = $0 },
                size: 44,
                idleBackgroundColor: .clear,
                idleIconColor: .clear
            )
            .padding(.trailing, 6)
            .allowsHitTesting(true)
        }
    }

    // MARK: - Composing Capsule

    private var composingCapsule: some View {
        HStack(alignment: .center, spacing: 8) {
            // + button
            Button {
                showAttachmentMenu = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DSColor.onBackgroundMuted)
                    .frame(width: 28, height: 28)
                    .background(DSColor.surfaceSunken, in: Circle())
            }
            .buttonStyle(.plain)
            .overlay {
                PhotosPicker(selection: $photosPickerItem, matching: .images, photoLibrary: .shared()) {
                    Color.clear
                }
                .opacity(0)
                .allowsHitTesting(false)
            }

            // Multi-line text field — no system inset, aligns naturally with + button
            TextField("Write something…", text: $text, axis: .vertical)
                .font(.custom("SpaceGrotesk-Regular", size: 15))
                .foregroundStyle(DSColor.onBackgroundPrimary)
                .focused($isFocused)
                .lineLimit(1...5)
                .tint(DSColor.onBackgroundPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(DSColor.outlineVariant.opacity(0.5), lineWidth: 0.5)
                )
        )
        .onTapGesture { isFocused = true }
    }

    // MARK: - Send Button

    private var sendButton: some View {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: handleSend) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(
                hasContent ? DSColor.onBackgroundPrimary : DSColor.onBackgroundSubtle.opacity(0.3),
                in: Circle()
            )
            .animation(.easeInOut(duration: 0.18), value: hasContent)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !hasContent)
    }

    // MARK: - Bottom Shelf

    private var bottomShelf: some View {
        HStack(spacing: 0) {
            Spacer()
            shelfButton(icon: "doc.text", label: "Notes") { showAttachmentMenu = true }
            Spacer()
            shelfButton(icon: "plus", label: "Attach") { showAttachmentMenu = true }
            Spacer()
            PhotosPicker(selection: $photosPickerItem, matching: .images, photoLibrary: .shared()) {
                shelfButtonLabel(icon: "camera", label: "Camera")
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }

    private func shelfButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { shelfButtonLabel(icon: icon, label: label) }
            .buttonStyle(.plain)
    }

    private func shelfButtonLabel(icon: String, label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(DSColor.onBackgroundMuted)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DSColor.onBackgroundSubtle)
        }
        .frame(width: 60, height: 40)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func handleSend() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { userExpandedText = false }
            isFocused = false
            return
        }
        onSubmit()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { userExpandedText = false }
    }

    private func handlePressToTalkStart() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await voiceService.startRecording() }
    }

    private func handlePressToTalkReleaseSend() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let result = await voiceService.stopAndTranscribe() {
                onPressToTalkSend(result)
            }
        }
    }

    private func handlePressToTalkReleaseCancel() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voiceService.cancelRecording()
    }

    private func handlePressToTalkReleaseTranscribe() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let result = await voiceService.stopAndTranscribe(),
               let t = result.transcript, !t.isEmpty {
                onPressToTalkTranscribe(t)
            }
        }
    }

    // MARK: - Attachment Preview

    private var attachmentPreviewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { att in attachmentChip(att) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func attachmentChip(_ att: PendingAttachment) -> some View {
        let (icon, label) = chipContent(att)
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(DSColor.onBackgroundMuted)
            Text(label).font(.system(size: 12)).foregroundStyle(DSColor.onBackgroundMuted).lineLimit(1)
            Button { onRemoveAttachment(att.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(DSColor.onBackgroundSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DSColor.surfaceSunken, in: Capsule())
    }

    private func chipContent(_ att: PendingAttachment) -> (icon: String, label: String) {
        switch att {
        case .photo(let r): return ("photo", r.fileURL.lastPathComponent)
        case .voice(let r): return ("mic",   r.filePath.split(separator: "/").last.map(String.init) ?? "Voice")
        case .file(let r):  return ("doc",   r.fileName)
        }
    }

    private func locationChipRow(loc: Memo.Location) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "mappin").font(.system(size: 10, weight: .semibold)).foregroundStyle(DSColor.accentAmber)
            Text(locationLabel(loc)).font(.system(size: 12)).foregroundStyle(DSColor.accentAmber).lineLimit(1)
            Spacer()
            Button(action: onClearLocation) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(DSColor.onBackgroundSubtle)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func locationLabel(_ loc: Memo.Location) -> String {
        if let name = loc.name, !name.isEmpty { return name }
        if let lat = loc.lat, let lng = loc.lng {
            return String(format: "%.4f, %.4f", lat, lng)
        }
        return "Unknown location"
    }
}
