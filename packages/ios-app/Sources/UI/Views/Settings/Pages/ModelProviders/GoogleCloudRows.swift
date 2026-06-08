import SwiftUI

struct GoogleCloudRows: View {
    let providerInfo: ProviderAuthInfo?
    let onSave: (AuthUpdateParams) async -> ProviderAuthActionResult
    let onClear: () async -> ProviderAuthActionResult

    @State private var isEditing = false
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var projectId = ""
    @State private var isSaving = false

    private var hasClientId: Bool { providerInfo?.hasClientId == true }
    private var hasClientSecret: Bool { providerInfo?.hasClientSecret == true }
    private var savedProjectId: String? { providerInfo?.projectId }
    private var isConfigured: Bool { hasClientId }
    private var canSave: Bool {
        !clientId.isEmpty || !clientSecret.isEmpty || !projectId.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "gearshape.2")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 18)
                Text("Google Cloud")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Spacer()
                if isConfigured && !isEditing {
                    Button {
                        enterEditMode()
                    } label: {
                        Text("Edit")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            if isEditing || !isConfigured {
                editFields
                actionButtons
            } else {
                savedDisplay
            }
        }
    }

    private var editFields: some View {
        VStack(spacing: 0) {
            SettingsRowDivider()
            fieldRow(icon: "number", label: "Client ID", placeholder: "OAuth client ID", text: $clientId, secure: false)
            SettingsRowDivider()
            fieldRow(icon: "lock.fill", label: "Client Secret", placeholder: "OAuth secret", text: $clientSecret, secure: true)
            SettingsRowDivider()
            fieldRow(icon: "folder.fill", label: "Project ID", placeholder: "GCP project", text: $projectId, secure: false)
        }
    }

    private func fieldRow(icon: String, label: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextSecondary)
            Spacer()
            if secure {
                SecureField(placeholder, text: text)
                    .font(TronTypography.codeCaption)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            } else {
                TextField(placeholder, text: text)
                    .font(TronTypography.codeCaption)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                save()
            } label: {
                Text("Save")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .disabled(isSaving || !canSave)
            .buttonStyle(.borderedProminent)
            .tint((!isSaving && canSave) ? .tronEmerald : .tronTextMuted.opacity(0.25))
            .opacity((!isSaving && canSave) ? 1 : 0.55)

            if isEditing {
                Button {
                    cancelEdit()
                } label: {
                    Text("Cancel")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if isConfigured && isEditing {
                Button(role: .destructive) {
                    clear()
                } label: {
                    Text("Clear All")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var savedDisplay: some View {
        VStack(spacing: 0) {
            SettingsRowDivider()
            savedRow(icon: "number", label: "Client ID", value: "Configured", valueColor: .tronSuccess)
            SettingsRowDivider()
            savedRow(
                icon: "lock.fill",
                label: "Client Secret",
                value: hasClientSecret ? "Configured" : "Not set",
                valueColor: hasClientSecret ? .tronSuccess : .tronTextMuted
            )
            SettingsRowDivider()
            savedRow(
                icon: "folder.fill",
                label: "Project ID",
                value: savedProjectId ?? "Not set",
                valueColor: savedProjectId != nil ? .tronSuccess : .tronTextMuted
            )
        }
    }

    private func savedRow(icon: String, label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextSecondary)
            Spacer()
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func enterEditMode() {
        clientId = ""
        clientSecret = ""
        projectId = savedProjectId ?? ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = true }
    }

    private func cancelEdit() {
        clientId = ""
        clientSecret = ""
        projectId = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = false }
    }

    private func clear() {
        Task { @MainActor in
            let result = await onClear()
            guard result.shouldCommitLocalFormChanges else { return }
            clientId = ""
            clientSecret = ""
            projectId = ""
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = false }
        }
    }

    private func save() {
        Task { @MainActor in
            isSaving = true
            var params = AuthUpdateParams(provider: "google")
            if !clientId.isEmpty { params.clientId = clientId }
            if !clientSecret.isEmpty { params.clientSecret = clientSecret }
            if !projectId.isEmpty { params.projectId = projectId }
            let result = await onSave(params)
            isSaving = false
            guard result.shouldCommitLocalFormChanges else { return }
            clientId = ""
            clientSecret = ""
            projectId = ""
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isEditing = false }
        }
    }
}

#Preview("Unconfigured") {
    GoogleCloudRows(providerInfo: nil, onSave: { _ in .succeeded }, onClear: { .succeeded })
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding()
}
