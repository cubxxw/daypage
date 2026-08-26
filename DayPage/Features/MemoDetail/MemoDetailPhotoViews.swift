import SwiftUI
import DayPageModels
import DayPageStorage

struct MemoPhotoViewerItem: Identifiable, Equatable {
    let relativePath: String
    var id: String { relativePath }
}

struct MemoDetailPhotoSection: View {
    let attachment: Memo.Attachment
    let metadata: PhotoMetadata?
    let onOpen: (MemoPhotoViewerItem) -> Void

    @State private var image: UIImage?
    @State private var didFinishLoading = false

    private var relativePath: String? { attachment.presentationFile }
    private var photoURL: URL? {
        relativePath.map { VaultInitializer.vaultURL.appendingPathComponent($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            memoDetailSectionLabel(NSLocalizedString("memo.detail.section.photo", comment: ""))

            ZStack(alignment: .bottom) {
                photoSurface

                if let text = metadata?.overlayText {
                    Text(text)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundColor(DSColor.bgWarm.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, DSSpacing.md)
                        .padding(.vertical, DSSpacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.48)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            .onTapGesture(perform: openPhoto)
            .task(id: relativePath) { await loadImage() }
            .onDisappear { image = nil }

            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                Text(NSLocalizedString("memo.detail.photo.tap_fullscreen", comment: ""))
                    .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                    .tracking(0.4)
            }
            .foregroundColor(image == nil ? DSColor.inkSubtle : DSColor.inkMuted)
            .textCase(.uppercase)
        }
    }

    @ViewBuilder
    private var photoSurface: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, minHeight: 240)
                .clipped()
        } else if didFinishLoading {
            Rectangle()
                .fill(DSColor.glassLo)
                .frame(maxWidth: .infinity, minHeight: 240)
                .overlay {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(DSColor.inkMuted)
                }
        } else {
            Rectangle()
                .fill(DSColor.glassLo)
                .frame(maxWidth: .infinity, minHeight: 240)
                .overlay { ProgressView().tint(DSColor.inkSubtle) }
        }
    }

    private func loadImage() async {
        image = nil
        didFinishLoading = false
        guard let photoURL else {
            didFinishLoading = true
            return
        }
        let displayPixels = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        image = await AttachmentImagePipeline.shared.image(
            at: photoURL,
            maxPixelSize: min(2_048, max(1_024, displayPixels))
        )
        if !Task.isCancelled { didFinishLoading = true }
    }

    private func openPhoto() {
        guard image != nil, let relativePath else { return }
        Haptics.tapConfirm()
        onOpen(MemoPhotoViewerItem(relativePath: relativePath))
    }
}

struct MemoPhotoFullscreenView: View {
    let item: MemoPhotoViewerItem

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var didFinishLoading = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if didFinishLoading {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.2), in: Circle())
                    }
                    .pressScale(scale: 0.92,
                                animation: .spring(response: 0.2, dampingFraction: 0.7))
                    .padding(DSSpacing.xl)
                }
                Spacer()
            }
        }
        .task(id: item.id) {
            let url = VaultInitializer.vaultURL.appendingPathComponent(item.relativePath)
            let screenPixels = Int(
                max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
                    * UIScreen.main.scale
            )
            image = await AttachmentImagePipeline.shared.image(
                at: url,
                maxPixelSize: min(4_096, max(2_048, screenPixels))
            )
            if !Task.isCancelled { didFinishLoading = true }
        }
    }
}
