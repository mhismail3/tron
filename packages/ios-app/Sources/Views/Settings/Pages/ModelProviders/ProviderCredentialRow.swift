import SwiftUI

struct ProviderCredentialRow: View {
    let isActive: Bool
    let icon: String
    let label: String
    let status: String
    let statusColor: Color
    let onSelect: () async -> Void
    let onDelete: () async -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeXL))
                .foregroundStyle(isActive ? .tronEmerald : .tronTextMuted)

            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
            .confirmationDialog("Remove credential?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    Task { await onDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .onTapGesture { Task { await onSelect() } }
    }
}

#Preview("Active OAuth account") {
    VStack(spacing: 0) {
        ProviderCredentialRow(
            isActive: true,
            icon: "lock.shield.fill",
            label: "work",
            status: "Active",
            statusColor: .tronSuccess,
            onSelect: {},
            onDelete: {}
        )
    }
    .sectionFill(.tronEmerald)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding()
}

#Preview("Expired with refresh") {
    ProviderCredentialRow(
        isActive: false,
        icon: "lock.shield.fill",
        label: "personal",
        status: "Will refresh",
        statusColor: .tronAmber,
        onSelect: {},
        onDelete: {}
    )
    .sectionFill(.tronEmerald)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding()
}

#Preview("API key row") {
    ProviderCredentialRow(
        isActive: false,
        icon: "key.horizontal",
        label: "production-key-with-long-name",
        status: "sk-ant-...xyz",
        statusColor: .tronTextSecondary,
        onSelect: {},
        onDelete: {}
    )
    .sectionFill(.tronEmerald)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .padding()
}
