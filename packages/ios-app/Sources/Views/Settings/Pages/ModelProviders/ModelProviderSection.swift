import SwiftUI

struct ModelProviderSection: View {
    let provider: ProviderInfo
    let providerAuth: ProviderAuthInfo?
    let onSetActive: (ActiveCredentialParam) async -> Void
    let onRemoveAccount: (String) async -> Void
    let onRemoveApiKey: (String) async -> Void
    let onAddApiKey: (String, String) async -> Void
    let onOAuthLogin: () -> Void
    let onSaveProvider: (AuthUpdateParams) async -> Void
    let onClear: () async -> Void

    @State private var showAddApiKey = false

    private var isConfigured: Bool {
        ProviderStatusHelpers.isProviderConfigured(providerAuth)
    }

    private var accounts: [AccountInfo] { providerAuth?.accounts ?? [] }
    private var apiKeys: [ApiKeyInfo] { providerAuth?.apiKeys ?? [] }
    private var hasAnyCredential: Bool { !accounts.isEmpty || !apiKeys.isEmpty }
    private var oauthLoginDisabled: Bool {
        provider.supportsOAuth && ProviderStatusHelpers.hasRefreshableOAuth(providerAuth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSectionHeader(provider: provider, isConfigured: isConfigured)

            SettingsCard(interactive: false) {
                cardContents
            }
        }
    }

    @ViewBuilder
    private var cardContents: some View {
        if provider.supportsOAuth {
            ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                ProviderCredentialRow(
                    isActive: ProviderStatusHelpers.isAccountActive(providerAuth, label: account.label),
                    icon: "lock.shield.fill",
                    label: account.label,
                    status: ProviderStatusHelpers.accountStatus(account),
                    statusColor: ProviderStatusHelpers.accountStatusColor(account),
                    onSelect: {
                        await onSetActive(ActiveCredentialParam(type: "oauth", label: account.label))
                    },
                    onDelete: { await onRemoveAccount(account.label) }
                )
                SettingsRowDivider()
            }
        }

        ForEach(Array(apiKeys.enumerated()), id: \.offset) { _, key in
            ProviderCredentialRow(
                isActive: ProviderStatusHelpers.isApiKeyActive(providerAuth, label: key.label),
                icon: "key.horizontal",
                label: key.label,
                status: key.keyHint,
                statusColor: .tronTextSecondary,
                onSelect: {
                    await onSetActive(ActiveCredentialParam(type: "apiKey", label: key.label))
                },
                onDelete: { await onRemoveApiKey(key.label) }
            )
            SettingsRowDivider()
        }

        if provider.supportsOAuth {
            actionRow(
                icon: "lock.shield",
                label: "OAuth Login",
                disabled: oauthLoginDisabled,
                accessibility: "Sign in with OAuth",
                onTap: onOAuthLogin
            )
            SettingsRowDivider()
        }

        actionRow(
            icon: showAddApiKey ? "chevron.up" : "plus",
            label: showAddApiKey ? "Hide Form" : "Add API Key",
            disabled: false,
            accessibility: "Add API key",
            onTap: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showAddApiKey.toggle()
                }
            }
        )

        if showAddApiKey {
            SettingsRowDivider()
            AddApiKeyForm(
                onAdd: { label, key in
                    await onAddApiKey(label, key)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showAddApiKey = false
                    }
                },
                onCancel: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showAddApiKey = false
                    }
                }
            )
        }

        if provider.id == "google" {
            SettingsRowDivider()
            GoogleCloudRows(
                providerInfo: providerAuth,
                onSave: { params in await onSaveProvider(params) },
                onClear: { await onClear() }
            )
        }
    }

    private func actionRow(
        icon: String,
        label: String,
        disabled: Bool,
        accessibility: String,
        onTap: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibility)
        .opacity(disabled ? 0.5 : 1.0)
        .onTapGesture {
            guard !disabled else { return }
            onTap()
        }
    }

}

struct ProviderSectionHeader: View {
    let provider: ProviderInfo
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(provider.assetIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(provider.color)
                .frame(width: 18, height: 18)
            Text(provider.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(provider.color)
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
