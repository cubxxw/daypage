import SwiftUI
import PhotosUI

// MARK: - InlineLensStrip (US-016)

/// Keeps photo attachment available inside the expanded composer while making
/// selection an explicit user action. `PhotosPicker` only returns the items the
/// user chooses; this view never asks for broad photo-library access or scans
/// recent assets in the background.
struct InlineLensStrip: View {

    @Binding var selection: [PhotosPickerItem]

    var body: some View {
        PhotosPicker(
            selection: $selection,
            maxSelectionCount: 4,
            matching: .images,
            photoLibrary: .shared()
        ) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "photo.badge.plus")
                    .font(DSType.titleSM)
                    .foregroundStyle(DSColor.amberAccent)

                Text(NSLocalizedString("input.a11y.photo_library", comment: ""))
                    .font(DSType.label)
                    .foregroundStyle(DSColor.inkPrimary)

                Spacer(minLength: DSSpacing.sm)

                Image(systemName: "chevron.right")
                    .font(DSType.caption)
                    .foregroundStyle(DSColor.inkMuted)
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(minHeight: 44)
            .background {
                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                    .fill(DSColor.glassLo)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .accessibilityLabel(NSLocalizedString("input.a11y.photo_library", comment: ""))
    }
}
