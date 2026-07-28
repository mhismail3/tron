import SwiftUI

struct ForkSessionConfirmationSheet: View {
    let isFork: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: 34, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 62, height: 62)
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.14)), in: .circle)

                VStack(spacing: 5) {
                    Text(isFork ? "Fork again from here?" : "Fork from this point?")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("A new session branch is created. This session remains unchanged.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .glassEffect(.regular, in: .capsule)

                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        Label("Create fork", systemImage: "arrow.triangle.branch")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.24)), in: .capsule)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            }
            .padding(20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Fork Session", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents(
            [.medium],
            ipadSizing: .compactForm,
            phoneSizing: .unchanged
        )
        .tint(.tronEmerald)
    }
}
