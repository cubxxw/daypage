import SwiftUI

// MARK: - MemoDetailView

struct MemoDetailView: View {

    let memo: Memo
    let vm: TodayViewModel

    @Environment(\.dismiss) private var dismiss

    private var kickerText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd  HH:mm"
        return f.string(from: memo.created).uppercased()
    }

    var body: some View {
        ZStack(alignment: .top) {
            AmbientBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // MARK: Back Button
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .medium))
                            Text("Today")
                                .font(DSType.bodySM)
                        }
                        .foregroundColor(DSColor.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                    // MARK: Kicker — mono date + time
                    Text(kickerText)
                        .font(DSType.mono10)
                        .foregroundColor(DSColor.inkSubtle)
                        .tracking(1.2)
                        .padding(.bottom, 14)

                    // MARK: Serif Body
                    Text(memo.body.isEmpty ? "—" : memo.body)
                        .font(DSType.serifBody16)
                        .foregroundColor(DSColor.inkPrimary)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // MARK: Attachment / Metadata Sections (placeholder)
                    if !memo.attachments.isEmpty || memo.location != nil || memo.weather != nil {
                        Divider()
                            .background(DSColor.inkFaint)
                            .padding(.vertical, 20)

                        Text("ATTACHMENTS & METADATA")
                            .font(DSType.mono10)
                            .foregroundColor(DSColor.inkSubtle)
                            .tracking(1.2)
                            .padding(.bottom, 8)

                        Text("Coming soon")
                            .font(DSType.bodySM)
                            .foregroundColor(DSColor.inkMuted)
                    }

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationBarHidden(true)
    }
}
