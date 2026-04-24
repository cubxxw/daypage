import SwiftUI

// MARK: - AttachmentMenuPopover
//
// Bottom-sheet style attachment picker with a 2×2 grid of large icon buttons.
// Presented via .sheet instead of .popover so it slides up from the bottom on iPhone.

struct AttachmentMenuPopover: View {

    let onCapturePhoto: () -> Void
    let onPickPhoto: () -> Void
    let onAddFile: () -> Void
    let onAddLocation: () -> Void

    let isLocating: Bool
    let hasPendingLocation: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            RoundedRectangle(cornerRadius: 2)
                .fill(DSColor.borderDefault)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 22)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                AttachmentActionButton(
                    icon: "camera.fill",
                    label: "拍照",
                    bgColor: Color(hex: "4A6FE3"),
                    action: onCapturePhoto
                )
                AttachmentActionButton(
                    icon: "photo.fill",
                    label: "从相册选",
                    bgColor: Color(hex: "3DAD74"),
                    action: onPickPhoto
                )
                AttachmentActionButton(
                    icon: "paperclip",
                    label: "附件",
                    bgColor: Color(hex: "E09030"),
                    action: onAddFile
                )
                AttachmentActionButton(
                    icon: hasPendingLocation ? "mappin.and.ellipse" : "mappin.circle.fill",
                    label: hasPendingLocation ? "更新位置" : "位置",
                    bgColor: Color(hex: "D95050"),
                    isLoading: isLocating,
                    action: onAddLocation
                )
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
        .background(DSColor.backgroundWarm)
        .presentationDetents([.height(210)])
        .presentationDragIndicator(.hidden)
        .modifier(AttachmentSheetPresentation())
    }
}

// MARK: - AttachmentActionButton

private struct AttachmentActionButton: View {
    let icon: String
    let label: String
    let bgColor: Color
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(bgColor)
                        .frame(width: 54, height: 54)
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .scaleEffect(isPressed ? 0.93 : 1.0)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isPressed)

                Text(label)
                    .font(.custom("SpaceGrotesk-Medium", size: 13))
                    .foregroundStyle(DSColor.onBackgroundMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isPressed ? DSColor.surfaceSunken : DSColor.surfaceWhite)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(DSColor.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        ._onButtonGesture(pressing: { isPressed = $0 }, perform: {})
    }
}

// MARK: - AttachmentSheetPresentation

private struct AttachmentSheetPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationBackground(DSColor.backgroundWarm)
                .presentationCornerRadius(20)
        } else {
            content
        }
    }
}
