import SwiftUI
import UIKit
import ImageIO

// MARK: - MemoCardView

/// Displays a single Memo as a card in the Today timeline.
/// Shows time + content preview with expand/collapse for long text.
struct MemoCardView: View {

    let memo: Memo

    @State private var isExpanded: Bool = false

    // Maximum lines when collapsed
    private let previewLineLimit = 4

    var body: some View {
        // Location memos get their own dedicated card layout
        if memo.type == .location {
            locationCard
        } else {
            standardCard
        }
    }

    // MARK: - Location Card

    private var locationCard: some View {
        HStack(spacing: 0) {
            // Left 4pt accent line
            Rectangle()
                .fill(DSColor.primary)
                .frame(width: 4)

            // Time + content
            VStack(alignment: .leading, spacing: 0) {
                // Time chip
                TimeChip(time: memo.created.formatted(.dateTime.hour().minute()))
                    .padding(.horizontal, 12)
                    .padding(.top, 10)

                // Location name + coordinates row
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let name = memo.location?.name, !name.isEmpty {
                            Text(name.uppercased())
                                .font(.custom("SpaceGrotesk-Bold", size: 14))
                                .foregroundColor(DSColor.onSurface)
                        }

                        let coordText = coordinateString(memo.location)
                        if !coordText.isEmpty {
                            Text(coordText)
                                .font(.custom("JetBrainsMono-Regular", fixedSize: 11))
                                .foregroundColor(DSColor.onSurfaceVariant)
                        }
                    }

                    Spacer()

                    Image(systemName: "location.fill")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundColor(DSColor.primary)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainer)
            .contentShape(Rectangle())
            .onTapGesture {
                if let lat = memo.location?.lat, let lng = memo.location?.lng {
                    let urlStr = "maps://?ll=\(lat),\(lng)"
                    if let url = URL(string: urlStr) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .cornerRadius(0)
    }

    // MARK: - Standard Card

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: time chip + type icon
            HStack(alignment: .center, spacing: 8) {
                TimeChip(time: memo.created.formatted(.dateTime.hour().minute()))
                typeLabel
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Photo thumbnail row (for photo and mixed memos with photo attachments)
            if let photoThumb = firstPhotoThumbnail {
                Image(uiImage: photoThumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 160)
                    .clipped()
                    .padding(.top, 6)

                // EXIF metadata bar below photo
                if let exifText = photoExifText {
                    Text(exifText)
                        .font(.custom("JetBrainsMono-Regular", fixedSize: 10))
                        .foregroundColor(DSColor.onSurfaceVariant)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DSColor.surfaceContainer)
                }
            }

            // Body content (caption)
            if !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(memo.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .bodySMStyle()
                    .foregroundColor(DSColor.onSurface)
                    .lineLimit(isExpanded ? nil : previewLineLimit)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            // Bottom row: location label + expand toggle
            HStack(alignment: .center, spacing: 8) {
                if let locationName = memo.location?.name, !locationName.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "mappin")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Text(locationName)
                            .monoLabelStyle(size: 9)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                }

                Spacer()

                // Expand/collapse button for long content
                if needsExpansionButton {
                    Button(action: { isExpanded.toggle() }) {
                        Text(isExpanded ? "收起" : "展开")
                            .monoLabelStyle(size: 9)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColor.surfaceContainer)
        .overlay(
            Rectangle()
                .fill(borderColor)
                .frame(width: 3),
            alignment: .leading
        )
        .cornerRadius(0)
    }

    // MARK: - Subviews

    private var typeLabel: some View {
        Group {
            switch memo.type {
            case .voice:
                Label("语音", systemImage: "mic.fill")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .photo:
                Label("照片", systemImage: "photo")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .location:
                Label("位置", systemImage: "location.fill")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .mixed:
                Label("混合", systemImage: "square.stack")
                    .monoLabelStyle(size: 9)
                    .foregroundColor(DSColor.onSurfaceVariant)
            case .text:
                EmptyView()
            }
        }
    }

    // MARK: - Helpers

    /// Formats lat/lng as "45.52306° N, 122.67648° W"
    private func coordinateString(_ loc: Memo.Location?) -> String {
        guard let lat = loc?.lat, let lng = loc?.lng else { return "" }
        let latStr = String(format: "%.5f° %@", abs(lat), lat >= 0 ? "N" : "S")
        let lngStr = String(format: "%.5f° %@", abs(lng), lng >= 0 ? "E" : "W")
        return "\(latStr), \(lngStr)"
    }

    /// Builds EXIF annotation text for the first photo attachment.
    /// Format: "IMG_0001.HEIC // FOCUS: INFINITYmm"
    private var photoExifText: String? {
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        let filename = URL(fileURLWithPath: att.file).lastPathComponent.uppercased()
        // Try to read focal length from image metadata
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            return "\(filename) // FOCUS: \(Int(focalLength))mm"
        }
        return "\(filename)"
    }

    /// Loads a thumbnail for the first photo attachment (if any).
    private var firstPhotoThumbnail: UIImage? {
        guard memo.type == .photo || memo.type == .mixed else { return nil }
        guard let att = memo.attachments.first(where: { $0.kind == "photo" }) else { return nil }
        let fileURL = VaultInitializer.vaultURL.appendingPathComponent(att.file)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // Use CGImageSource thumbnail for efficiency
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 600
        ]
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return UIImage(cgImage: cgThumb)
        }
        return UIImage(data: data)
    }

    private var borderColor: Color {
        switch memo.type {
        case .text:    return DSColor.primary
        case .voice:   return DSColor.onSurfaceVariant
        case .photo:   return DSColor.secondaryFixed
        case .location: return DSColor.tertiaryFixed
        case .mixed:   return DSColor.amberArchival
        }
    }

    /// Whether the body is long enough to need an expand button.
    private var needsExpansionButton: Bool {
        let body = memo.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Approximate: if body has many newlines or is long
        let lineCount = body.components(separatedBy: "\n").count
        return lineCount > previewLineLimit || body.count > 200
    }
}

// MARK: - DailyPageEntryCard

/// Card shown at the top of the timeline when today's Daily Page has been compiled.
/// Full-width black card per design spec (Brutalist style).
struct DailyPageEntryCard: View {
    let summary: String?
    var onTap: (() -> Void)?

    @State private var arrowOffset: CGFloat = 0

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TODAY'S PAGE COMPILED")
                        .font(.custom("SpaceGrotesk-Bold", size: 14))
                        .foregroundColor(DSColor.onPrimary)
                        .kerning(1)

                    if let summary = summary, !summary.isEmpty {
                        Text(summary)
                            .bodySMStyle()
                            .foregroundColor(DSColor.onPrimary.opacity(0.7))
                            .lineLimit(2)
                    } else {
                        Text("Your daily digest is ready.")
                            .bodySMStyle()
                            .foregroundColor(DSColor.onPrimary.opacity(0.7))
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.forward")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DSColor.onPrimary)
                    .offset(x: arrowOffset)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(DSColor.primary)
            .cornerRadius(0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                arrowOffset = hovering ? 4 : 0
            }
        }
    }
}

// MARK: - CompilePromptCard

/// Placeholder card shown when today's Daily Page has not been compiled.
/// Supports a loading/compiling state that disables the button and shows progress text.
struct CompilePromptCard: View {
    let memoCount: Int
    var isCompiling: Bool = false
    var onCompile: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isCompiling ? DSColor.primary : DSColor.outlineVariant)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(isCompiling ? "正在编译..." : "今日还未编译")
                        .sectionLabelStyle()
                        .foregroundColor(isCompiling ? DSColor.onSurface : DSColor.onSurfaceVariant)

                    if isCompiling {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(DSColor.onSurfaceVariant)
                    }
                }

                if isCompiling {
                    Text("正在编译 \(memoCount) 条 memo...")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                } else if memoCount > 0 {
                    Text("已有 \(memoCount) 条记录，点击立即编译")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)

                    Button(action: { onCompile?() }) {
                        Text("立即编译")
                            .monoLabelStyle(size: 10)
                            .foregroundColor(DSColor.onPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(DSColor.primary)
                            .cornerRadius(0)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCompiling)
                } else {
                    Text("记录今天的想法，晚些时候将自动编译成日记")
                        .bodySMStyle()
                        .foregroundColor(DSColor.onSurfaceVariant)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSColor.surfaceContainer)
        }
        .cornerRadius(0)
        .animation(.easeInOut(duration: 0.2), value: isCompiling)
    }
}
