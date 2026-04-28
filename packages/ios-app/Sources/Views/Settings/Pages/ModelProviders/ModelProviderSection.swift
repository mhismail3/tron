import SwiftUI

struct ModelProviderSection: View {
    let provider: ProviderInfo
    let providerAuth: ProviderAuthInfo?
    let onSetActive: (ActiveCredentialParam) async -> ProviderAuthActionResult
    let onRemoveAccount: (String) async -> ProviderAuthActionResult
    let onRemoveApiKey: (String) async -> ProviderAuthActionResult
    let onAddApiKey: (String, String) async -> ProviderAuthActionResult
    let onOAuthLogin: () -> Void
    let onSaveProvider: (AuthUpdateParams) async -> ProviderAuthActionResult
    let onClear: () async -> ProviderAuthActionResult

    @State private var showAddApiKey = false

    private var isConfigured: Bool {
        ProviderStatusHelpers.isProviderConfigured(providerAuth)
    }

    private var accounts: [AccountInfo] { providerAuth?.accounts ?? [] }
    private var apiKeys: [ApiKeyInfo] { providerAuth?.apiKeys ?? [] }
    private var accountRows: [ProviderAccountCredentialRow] {
        accounts.map { ProviderAccountCredentialRow(account: $0) }
    }
    private var apiKeyRows: [ProviderApiKeyCredentialRow] {
        apiKeys.map { ProviderApiKeyCredentialRow(key: $0) }
    }
    private var oauthLoginDisabled: Bool {
        provider.supportsOAuth && ProviderStatusHelpers.hasRefreshableOAuth(providerAuth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSectionHeader(provider: provider, isConfigured: isConfigured)

            SettingsCard {
                cardContents
            }
        }
    }

    @ViewBuilder
    private var cardContents: some View {
        if provider.supportsOAuth {
            ForEach(accountRows) { row in
                ProviderCredentialRow(
                    isActive: ProviderStatusHelpers.isAccountActive(providerAuth, label: row.account.label),
                    icon: "lock.shield.fill",
                    label: row.account.label,
                    status: ProviderStatusHelpers.accountStatus(row.account),
                    statusColor: ProviderStatusHelpers.accountStatusColor(row.account),
                    onSelect: {
                        _ = await onSetActive(ActiveCredentialParam(type: "oauth", label: row.account.label))
                    },
                    onDelete: { _ = await onRemoveAccount(row.account.label) }
                )
                SettingsRowDivider()
            }
        }

        ForEach(apiKeyRows) { row in
            ProviderCredentialRow(
                isActive: ProviderStatusHelpers.isApiKeyActive(providerAuth, label: row.key.label),
                icon: "key.horizontal",
                label: row.key.label,
                status: row.key.keyHint,
                statusColor: .tronTextSecondary,
                onSelect: {
                    _ = await onSetActive(ActiveCredentialParam(type: "apiKey", label: row.key.label))
                },
                onDelete: { _ = await onRemoveApiKey(row.key.label) }
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
            label: showAddApiKey ? "Hide" : "Add API Key",
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
                    let result = await onAddApiKey(label, key)
                    guard result.shouldCommitLocalFormChanges else { return result }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showAddApiKey = false
                    }
                    return result
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

private struct ProviderAccountCredentialRow: Identifiable {
    let item: ProviderCredentialRowItem
    let account: AccountInfo

    init(account: AccountInfo) {
        self.account = account
        item = .oauth(account)
    }

    var id: String {
        item.id
    }
}

private struct ProviderApiKeyCredentialRow: Identifiable {
    let item: ProviderCredentialRowItem
    let key: ApiKeyInfo

    init(key: ApiKeyInfo) {
        self.key = key
        item = .apiKey(key)
    }

    var id: String {
        item.id
    }
}
