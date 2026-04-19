import SwiftUI

// MARK: - AccountSheet

struct AccountSheet: View {

    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(DSColor.outline)
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 24)

            // Email
            Text(authService.session?.user.email ?? "")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "6B6B6B"))
                .padding(.bottom, 24)

            Divider()

            // Sign Out
            Button {
                Task {
                    try? await authService.signOut()
                    UserDefaults.standard.set(false, forKey: "authSkipped")
                    dismiss()
                }
            } label: {
                Text("Sign Out")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(hex: "E05A5A"))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }

            Spacer()
        }
        .presentationDetents([.fraction(0.3)])
        .presentationDragIndicator(.hidden)
    }
}
