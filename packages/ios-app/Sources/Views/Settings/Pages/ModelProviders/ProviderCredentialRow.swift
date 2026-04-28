import SwiftUI

struct ProviderCredentialRow: View {
    let isActive: Bool
    let label: String
    let status: String
    let statusColor: Color
    let onSelect: () async -> Void
    let onDelete: () async -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(isActive ? .tronEmerald : .tronTextMuted)
                .frame(width: 18)

            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(status)
                .font(TronTypography.code(size: TronTypography.sizeCaption))
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .trailing)

            Button {
                showDeleteConfirm = true
            } label: {
                Text(ProviderCredentialStatusAction.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronError)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ProviderCredentialStatusAction.title) \(label)")
            .confirmationDialog(ProviderCredentialStatusAction.confirmationTitle, isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button(ProviderCredentialStatusAction.confirmationButtonTitle, role: .destructive) {
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
            label: "work",
            status: "Logged in with OAuth",
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
        label: "personal",
        status: "OAuth will refresh",
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
