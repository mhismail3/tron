import SwiftUI

struct ProviderServiceCard: View {
    let service: ProviderInfo
    let serviceAuth: ServiceAuthInfo?
    let onSave: (AuthUpdateParams) async -> ProviderAuthActionResult
    let onClear: () async -> ProviderAuthActionResult

    @State private var showAddApiKeyPrompt = false

    private var isConfigured: Bool { serviceAuth?.hasApiKey == true }
    private var apiKeyPromptScope: ProviderApiKeyPromptScope {
        .service(id: service.id, displayName: service.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderServiceSectionHeader(service: service, isConfigured: isConfigured)

            VStack(alignment: .leading, spacing: 8) {
                statusCard
                serviceActionButtons
            }
        }
    }

    private var statusCard: some View {
        SettingsCard {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(isConfigured ? .tronEmerald : .tronTextMuted.opacity(0.45))
                    .frame(width: 18)

                Text(isConfigured ? "API key configured" : "No API key")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if isConfigured {
                    Text(serviceAuth?.apiKeyHint ?? "")
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 170, alignment: .trailing)

                    Button(role: .destructive) {
                        Task { _ = await onClear() }
                    } label: {
                        ProviderCredentialClearPillLabel()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(service.displayName) API key")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var serviceActionButtons: some View {
        ProviderAuthActionButtons(
            items: [.addApiKey],
            onSelect: { _ in showAddApiKeyPrompt = true }
        )
        .providerApiKeyAlert(isPresented: $showAddApiKeyPrompt, scope: apiKeyPromptScope) { draft in
            await onSave(AuthUpdateParams(service: service.id, apiKey: .value(draft.apiKey)))
        }
    }
}

private struct ProviderServiceSectionHeader: View {
    let service: ProviderInfo
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: service.serviceSystemIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(service.color)
                .frame(width: 18, height: 18)
            Text(service.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(service.color)
            if isConfigured {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronEmerald)
            }
            Spacer()
        }
        .padding(.bottom, 8)
    }
}
