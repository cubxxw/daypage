import SwiftUI
import DayPageModels
import DayPageServices

struct MemoDetailMetadataSection: View {
    let memo: Memo
    let photoMetadataByFile: [String: PhotoMetadata]

    private struct BodyStats {
        let wordCount: Int
        let characterCount: Int
        let readingMinutes: Int
    }

    private var createdFull: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: memo.created)
    }

    private var bodyStats: BodyStats {
        var cjkCount = 0
        var latinWords = 0
        var inLatinRun = false
        for scalar in memo.body.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) ||
                (0x3400...0x4DBF).contains(scalar.value) ||
                (0x3040...0x30FF).contains(scalar.value) {
                cjkCount += 1
                inLatinRun = false
            } else if scalar.properties.isWhitespace {
                inLatinRun = false
            } else {
                if !inLatinRun { latinWords += 1 }
                inLatinRun = true
            }
        }
        let minutes = Double(cjkCount) / 300 + Double(latinWords) / 220
        return BodyStats(
            wordCount: TextCount.words(memo.body),
            characterCount: memo.body.count,
            readingMinutes: MemoPresentationSafety.roundedInt(minutes) ?? 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            memoDetailSectionLabel(NSLocalizedString("memo.detail.section.metadata", comment: ""))
                .padding(.bottom, DSSpacing.xs)

            row(NSLocalizedString("memo.detail.meta.created", comment: ""), createdFull)
            row(NSLocalizedString("memo.detail.meta.file", comment: ""), "vault/raw/\(DateFormatters.isoDate.string(from: memo.created)).md")
            row(NSLocalizedString("memo.detail.meta.kind", comment: ""), memo.type.rawValue.capitalized)

            if !memo.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if bodyStats.wordCount != bodyStats.characterCount {
                    row(NSLocalizedString("memo.detail.meta.words", comment: ""), "\(bodyStats.wordCount)")
                }
                row(NSLocalizedString("memo.detail.meta.characters", comment: ""), "\(bodyStats.characterCount)")
                row(NSLocalizedString("memo.detail.meta.reading", comment: ""), readingTime)
            }

            kindSpecificRows
        }
    }

    private var readingTime: String {
        bodyStats.readingMinutes < 1
            ? NSLocalizedString("memo.detail.meta.reading.less_than_1", comment: "")
            : String(format: NSLocalizedString("memo.detail.meta.reading.min", comment: ""), bodyStats.readingMinutes)
    }

    @ViewBuilder
    private var kindSpecificRows: some View {
        if let audio = memo.attachments.first(where: { $0.kind == "audio" }) {
            if let duration = audio.presentationDuration {
                row(NSLocalizedString("memo.detail.meta.duration", comment: ""), duration.mmss)
            }
            row(
                NSLocalizedString("memo.detail.meta.transcription", comment: ""),
                audio.transcript?.isEmpty == false
                    ? NSLocalizedString("memo.detail.meta.transcription.provider", comment: "")
                    : NSLocalizedString("memo.detail.meta.transcription.pending", comment: "")
            )
        }

        if let photo = memo.attachments.first(where: { $0.kind == "photo" }),
           let metadata = photoMetadataByFile[photo.file] {
            ForEach(metadata.rows) { metadataRow in
                row(metadataRow.label, metadataRow.value)
            }
        }

        if let location = memo.location {
            if let coordinate = location.presentationCoordinate {
                row(NSLocalizedString("memo.detail.meta.coordinates", comment: ""), String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude))
            }
            if let name = location.name, !name.isEmpty {
                row(NSLocalizedString("memo.detail.meta.place", comment: ""), name)
            }
        }

        if let weather = memo.weather, !weather.isEmpty {
            row(NSLocalizedString("memo.detail.meta.weather", comment: ""), weather)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Text(label.uppercased())
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .tracking(0.6)
                .foregroundColor(DSColor.inkMuted)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(DSFonts.jetBrainsMono(size: 10, relativeTo: .caption2))
                .tracking(0.4)
                .foregroundColor(DSColor.inkMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
