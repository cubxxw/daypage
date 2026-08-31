import SwiftUI

struct MemoDetailEchoesSection: View {
    let echoes: [MemoEcho]
    let onOpen: (String) -> Void

    var body: some View {
        if !echoes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                memoDetailSectionLabel(NSLocalizedString(
                    "memo.detail.section.echoes", value: "Echoes",
                    comment: "Detail view — related-memories section label"
                ))

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(echoes.enumerated()), id: \.element.id) { index, echo in
                        if index > 0 {
                            Divider().background(DSColor.glassRim).padding(.leading, 14)
                        }
                        Button { onOpen(echo.dateString) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(echo.dateString)
                                    .font(DSFonts.jetBrainsMono(size: 10))
                                    .tracking(0.4)
                                    .foregroundColor(DSColor.inkSubtle)
                                    .layoutPriority(1)
                                Text(echo.snippet)
                                    .font(DSFonts.serif(size: 14, weight: .regular, relativeTo: .subheadline))
                                    .foregroundColor(DSColor.inkMuted)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(DSColor.inkSubtle.opacity(0.6))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .liquidGlassCard(cornerRadius: DSRadius.md, tone: .lo)
            }
            .padding(.top, 28)
        }
    }
}

func memoDetailSectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
        .font(DSType.mono10)
        .foregroundColor(DSColor.inkMuted)
        .tracking(1.2)
        .accessibilityAddTraits(.isHeader)
}
