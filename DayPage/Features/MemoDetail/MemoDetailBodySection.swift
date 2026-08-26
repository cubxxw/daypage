import SwiftUI
import DayPageModels

struct MemoDetailBodySection: View {
    let memo: Memo
    let entityDisplayNames: [String: String]
    @Binding var isEditing: Bool
    let onOpenEntity: (String) -> Void
    let onSave: (String) async -> Bool

    @State private var editedBody = ""
    @State private var editorHeight: CGFloat = 180
    @State private var isSaving = false
    @StateObject private var editorController = MarkdownEditorController()

    private var bodyTrimmed: String {
        memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBodyDuplicateOfAudioTranscript: Bool {
        guard !bodyTrimmed.isEmpty else { return false }
        return memo.attachments.contains {
            $0.kind == "audio" &&
            $0.presentationFile != nil &&
            $0.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) == bodyTrimmed
        }
    }

    var body: some View {
        Group {
            if isEditing {
                editor
            } else if !bodyTrimmed.isEmpty && !isBodyDuplicateOfAudioTranscript {
                renderedBody
            }
        }
        .onChange(of: isEditing) { editing in
            if editing { editedBody = memo.body }
        }
        .onChange(of: memo.body) { newValue in
            if !isEditing { editedBody = newValue }
        }
    }

    private var renderedBody: some View {
        MarkdownBodyView(
            text: bodyTrimmed,
            lineSpacing: 8,
            blockSpacing: 12,
            entitySlugs: memo.entityMentions,
            entityDisplayNames: entityDisplayNames
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .contentShape(Rectangle())
        .onTapGesture(perform: startEditing)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "daypage-entity",
                  let slug = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "s" })?.value
            else { return .systemAction }
            onOpenEntity(slug)
            return .handled
        })
        .accessibilityHint(NSLocalizedString(
            "memo.detail.a11y.tap_to_edit", value: "双击以编辑正文",
            comment: "Detail view — body tap-to-edit VoiceOver hint"
        ))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                MarkdownEditor(
                    text: $editedBody,
                    measuredHeight: $editorHeight,
                    controller: editorController
                )
                .frame(height: editorHeight)

                MarkdownFormatBar { editorController.perform($0) }
            }
            .background(DSColor.glassLo)
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .strokeBorder(DSColor.amberRim, lineWidth: 0.5)
            }

            HStack(spacing: DSSpacing.md) {
                Button(action: cancelEditing) {
                    Text(NSLocalizedString(
                        "memo.detail.edit.cancel", value: "Cancel",
                        comment: "Detail view — cancel body edit"
                    ))
                    .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(DSColor.inkMuted)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: save) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(NSLocalizedString(
                            "memo.detail.edit.save", value: "Save",
                            comment: "Detail view — save body edit"
                        ))
                        .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                        .tracking(0.6)
                        .textCase(.uppercase)
                    }
                }
                .foregroundColor(DSColor.accentOnBg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .amberPillSurface(Capsule())
                .buttonStyle(.plain)
                .disabled(isSaving || editedBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .pressScale(scale: 0.96, opacity: 0.9,
                            animation: .spring(response: 0.2, dampingFraction: 0.7))
                .accessibilityIdentifier("memo.detail.body.save")
            }
        }
        .padding(.bottom, 14)
    }

    func startEditing() {
        Haptics.soft()
        editedBody = memo.body
        withAnimation(.easeOut(duration: 0.18)) { isEditing = true }
    }

    private func cancelEditing() {
        Haptics.soft()
        dismissKeyboard()
        editedBody = memo.body
        withAnimation(.easeOut(duration: 0.18)) { isEditing = false }
    }

    private func save() {
        guard !isSaving else { return }
        Haptics.tapConfirm()
        dismissKeyboard()
        isSaving = true
        Task {
            let succeeded = await onSave(editedBody)
            isSaving = false
            if succeeded {
                withAnimation(.easeOut(duration: 0.18)) { isEditing = false }
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }
}
