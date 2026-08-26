import SwiftUI
import MapKit
import DayPageModels
import DayPageStorage
import DayPageServices

struct MemoDetailAttachmentsSection: View {
    let memo: Memo
    let derivedData: MemoDetailDerivedData
    let onOpenPhoto: (MemoPhotoViewerItem) -> Void
    let onOpenPlace: (String) -> Void

    private var audio: [Memo.Attachment] { memo.attachments.filter { $0.kind == "audio" } }
    private var photos: [Memo.Attachment] { memo.attachments.filter { $0.kind == "photo" } }
    private var files: [Memo.Attachment] { memo.attachments.filter { $0.kind == "file" } }
    private var hasLocation: Bool { memo.location?.presentationCoordinate != nil }

    var body: some View {
        if !audio.isEmpty || !photos.isEmpty || !files.isEmpty || hasLocation {
            Divider()
                .background(DSColor.inkFaint)
                .padding(.vertical, DSSpacing.xl)

            LazyVStack(alignment: .leading, spacing: DSSpacing.xl) {
                ForEach(Array(audio.enumerated()), id: \.offset) { _, attachment in
                    MemoDetailVoiceSection(attachment: attachment)
                }
                ForEach(Array(photos.enumerated()), id: \.offset) { _, attachment in
                    MemoDetailPhotoSection(
                        attachment: attachment,
                        metadata: derivedData.photoMetadataByFile[attachment.file],
                        onOpen: onOpenPhoto
                    )
                }
                if let location = memo.location, hasLocation {
                    MemoDetailLocationSection(
                        location: location,
                        memoDateString: DateFormatters.isoDate.string(from: memo.created),
                        onOpenPlace: onOpenPlace
                    )
                }
                if !files.isEmpty {
                    MemoDetailFilesSection(attachments: files)
                }
            }
        }
    }
}

private struct MemoDetailVoiceSection: View {
    let attachment: Memo.Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            memoDetailSectionLabel(NSLocalizedString("memo.detail.section.voice", comment: ""))
            if let relativePath = attachment.presentationFile {
                VoiceMemoPlayerRow(
                    fileURL: VaultInitializer.vaultURL.appendingPathComponent(relativePath),
                    duration: attachment.presentationDuration ?? 0,
                    transcript: attachment.transcript,
                    transcriptionStatus: attachment.transcriptionStatus
                )
                .frame(maxWidth: .infinity)
                .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
            } else {
                MemoDetailAttachmentUnavailable(icon: "waveform.badge.exclamationmark")
            }
        }
    }
}

private struct MemoDetailLocationSection: View {
    let location: Memo.Location
    let memoDateString: String
    let onOpenPlace: (String) -> Void

    @State private var visitLine: String?
    @State private var placeSlug: String?

    private var coordinate: CLLocationCoordinate2D? {
        location.presentationCoordinate.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            memoDetailSectionLabel(NSLocalizedString("memo.detail.section.location", comment: ""))

            VStack(alignment: .leading, spacing: 0) {
                if let coordinate {
                    MapPreviewView(coordinate: coordinate)
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: DSRadius.md,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: DSRadius.md,
                            style: .continuous
                        ))
                }

                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    if let name = location.name, !name.isEmpty {
                        Button(action: openPlace) {
                            HStack(spacing: 6) {
                                Text(name)
                                    .font(DSType.serifBody16)
                                    .foregroundColor(DSColor.inkPrimary)
                                if placeSlug != nil {
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(DSColor.accentOnBg.opacity(0.65))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(placeSlug == nil)
                    }
                    if let coordinate {
                        Text(String(format: "%.5f°, %.5f°", coordinate.latitude, coordinate.longitude))
                            .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                            .foregroundColor(DSColor.inkMuted)
                    }
                    if let visitLine {
                        Text(visitLine)
                            .font(DSFonts.jetBrainsMono(size: 10))
                            .tracking(0.6)
                            .foregroundColor(DSColor.accentOnBg.opacity(0.75))
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, DSSpacing.md)

                Divider().background(DSColor.glassRim).padding(.horizontal, 14)

                Button(action: openInMaps) {
                    HStack(spacing: 10) {
                        Image(systemName: "map.fill")
                        Text(NSLocalizedString("memo.detail.location.open_maps", comment: ""))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(DSType.bodySM)
                    .foregroundColor(DSColor.accentOnBg)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .pressScale(scale: 0.98,
                            animation: .spring(response: 0.22, dampingFraction: 0.72))
                .disabled(coordinate == nil)
            }
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
        }
        .task(id: memoDateString) { await loadPlaceStory() }
    }

    private func loadPlaceStory() async {
        guard let name = location.name, !name.isEmpty else { return }
        if let documents = SearchIndex.shared.documentsIfBuilt() {
            let folded = SearchService.foldForSearch(name)
            let priorDays = documents
                .filter { day in day.memos.contains { $0.foldedLocationName == folded } }
                .map(\.dateString)
                .filter { $0 < memoDateString }
                .sorted()
            if priorDays.isEmpty {
                visitLine = "FIRST VISIT HERE"
            } else if let previous = priorDays.last {
                visitLine = "\(Self.ordinal(priorDays.count + 1)) VISIT · LAST \(previous)"
            }
        }

        let slug = EntityPageService.sanitizeSlug(name)
        let url = VaultInitializer.vaultURL.appendingPathComponent("wiki/places/\(slug).md")
        if FileManager.default.fileExists(atPath: url.path) { placeSlug = slug }
    }

    private func openPlace() {
        guard let placeSlug else { return }
        Haptics.soft()
        onOpenPlace(placeSlug)
    }

    private func openInMaps() {
        guard let coordinate,
              let url = URL(string: "maps://?ll=\(coordinate.latitude),\(coordinate.longitude)")
        else { return }
        UIApplication.shared.open(url)
    }

    private static func ordinal(_ number: Int) -> String {
        if [11, 12, 13].contains(number % 100) { return "\(number)TH" }
        switch number % 10 {
        case 1: return "\(number)ST"
        case 2: return "\(number)ND"
        case 3: return "\(number)RD"
        default: return "\(number)TH"
        }
    }
}

private struct MemoDetailFilesSection: View {
    let attachments: [Memo.Attachment]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            memoDetailSectionLabel("Files")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { index, attachment in
                    if index > 0 {
                        Divider().background(DSColor.glassRim).padding(.leading, 44)
                    }
                    MemoDetailFileRow(attachment: attachment)
                }
            }
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
        }
    }
}

private struct MemoDetailFileRow: View {
    let attachment: Memo.Attachment
    @State private var fileSize = ""
    @State private var previewItem: PreviewFileItem?

    private var fileURL: URL? {
        attachment.presentationFile.map { VaultInitializer.vaultURL.appendingPathComponent($0) }
    }

    private var fileName: String {
        attachment.transcript ?? fileURL?.lastPathComponent ?? "Unavailable file"
    }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Image(systemName: fileIcon)
                .font(.system(size: 14))
                .foregroundColor(DSColor.accentOnBg)
                .frame(width: 32, height: 32)
                .amberPillSurface(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(DSFonts.jetBrainsMono(size: 11, relativeTo: .caption))
                    .foregroundColor(DSColor.inkPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !fileSize.isEmpty {
                    Text(fileSize)
                        .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                        .foregroundColor(DSColor.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open", action: openFile)
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .disabled(fileURL == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, DSSpacing.md)
        .task(id: fileURL) { loadFileSize() }
        .sheet(item: $previewItem) { FilePreviewSheet(url: $0.url).ignoresSafeArea() }
    }

    private var fileIcon: String {
        switch fileURL?.pathExtension.lowercased() {
        case "pdf": return "doc.richtext.fill"
        case "jpg", "jpeg", "png", "heic": return "photo.fill"
        case "mp4", "mov", "m4v": return "video.fill"
        case "mp3", "m4a", "wav", "aac": return "music.note"
        case "zip", "tar", "gz": return "archivebox.fill"
        case "xls", "xlsx", "csv": return "tablecells.fill"
        default: return "doc.fill"
        }
    }

    private func loadFileSize() {
        guard let fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let bytes = attributes[.size] as? NSNumber else { return }
        fileSize = ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
    }

    private func openFile() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        previewItem = PreviewFileItem(url: fileURL)
    }
}

private struct MemoDetailAttachmentUnavailable: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 24, weight: .light))
            .foregroundColor(DSColor.inkMuted)
            .frame(maxWidth: .infinity, minHeight: 84)
            .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
    }
}
