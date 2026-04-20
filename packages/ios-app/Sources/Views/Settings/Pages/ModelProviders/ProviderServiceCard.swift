import SwiftUI

struct ProviderServiceCard: View {
    let service: ProviderInfo
    let serviceAuth: ServiceAuthInfo?
    let onSave: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var apiKey = ""
    @State private var isSaving = false

    private var isConfigured: Bool { serviceAuth?.hasApiKey == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard {
                headerRow
                SettingsRowDivider()
                keyEntryRow
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Image(systemName: service.serviceSystemIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(service.color)
                .frame(width: 18)
            Text(service.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
            Spacer()
            if let hint = serviceAuth?.apiKeyHint {
                Text(hint)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(isConfigured ? .tronEmerald : .tronTextMuted.opacity(0.3))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var keyEntryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.horizontal")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            SecureField("API Key", text: $apiKey)
                .font(TronTypography.codeCaption)
                .textContentType(.password)
                .autocorrectionDisabled()

            Button {
                save()
            } label: {
                Text("Save")
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            }
            .disabled(apiKey.isEmpty || isSaving)
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)

            if isConfigured {
                Button(role: .destructive) {
                    Task { await onClear() }
                } label: {
                    Text("Clear")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func save() {
        guard !apiKey.isEmpty else { return }
        isSaving = true
        Task {
            await onSave(AuthUpdateParams(service: service.id, apiKey: .value(apiKey)))
            apiKey = ""
            isSaving = false
        }
    }
}
