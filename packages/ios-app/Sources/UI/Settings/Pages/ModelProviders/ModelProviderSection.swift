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

    @State private var showAddApiKeyPrompt = false

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
    private var credentialRows: [ProviderCredentialDisplayRow] {
        accountRows.map { .account($0.account) } + apiKeyRows.map { .apiKey($0.key) }
    }
    private var actionItems: [ProviderAuthActionItem] {
        ProviderAuthActionItem.visibleItems(for: provider, providerAuth: providerAuth)
    }
    private var apiKeyPromptScope: ProviderApiKeyPromptScope {
        .provider(id: provider.id, displayName: provider.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSectionHeader(provider: provider, isConfigured: isConfigured)

            VStack(alignment: .leading, spacing: 8) {
                providerStatusCard

                if ProviderSettingsContainer.containers(for: provider).contains(.googleCloud) {
                    googleCloudCard
                }

                providerActionButtons
            }
        }
    }

    private var providerStatusCard: some View {
        SettingsCard {
            if credentialRows.isEmpty {
                emptyStatusRow
            } else {
                ForEach(Array(credentialRows.enumerated()), id: \.element.id) { index, row in
                    credentialStatusRow(row)
                    if index < credentialRows.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }

    private var googleCloudCard: some View {
        SettingsCard {
            GoogleCloudRows(
                providerInfo: providerAuth,
                onSave: { params in await onSaveProvider(params) },
                onClear: { await onClear() }
            )
        }
    }

    private var providerActionButtons: some View {
        ProviderAuthActionButtons(
            items: actionItems,
            onSelect: { item in
                switch item {
                case .oauthLogin:
                    onOAuthLogin()
                case .addApiKey:
                    showAddApiKeyPrompt = true
                }
            }
        )
        .providerApiKeyAlert(isPresented: $showAddApiKeyPrompt, scope: apiKeyPromptScope) { draft in
            await onAddApiKey(draft.saveLabel(for: apiKeyPromptScope), draft.apiKey)
        }
    }

    private var emptyStatusRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted.opacity(0.45))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Text(provider.supportsOAuth ? "Use OAuth or an API key to connect \(provider.displayName)." : "Add an API key to connect \(provider.displayName).")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func credentialStatusRow(_ row: ProviderCredentialDisplayRow) -> some View {
        switch row {
        case .account(let account):
            ProviderCredentialRow(
                isActive: ProviderStatusHelpers.isAccountActive(providerAuth, label: account.label),
                label: account.label,
                status: ProviderStatusHelpers.accountDetail(account),
                statusColor: ProviderStatusHelpers.accountStatusColor(account),
                onSelect: {
                    _ = await onSetActive(ActiveCredentialParam(type: "oauth", label: account.label))
                },
                onDelete: { _ = await onRemoveAccount(account.label) }
            )
        case .apiKey(let key):
            ProviderCredentialRow(
                isActive: ProviderStatusHelpers.isApiKeyActive(providerAuth, label: key.label),
                label: key.label,
                status: key.keyHint,
                statusColor: .tronTextSecondary,
                onSelect: {
                    _ = await onSetActive(ActiveCredentialParam(type: "apiKey", label: key.label))
                },
                onDelete: { _ = await onRemoveApiKey(key.label) }
            )
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

struct ProviderAuthActionButtons: View {
    let items: [ProviderAuthActionItem]
    let onSelect: (ProviderAuthActionItem) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items) { item in
                Button {
                    onSelect(item)
                } label: {
                    ProviderAuthActionButtonLabel(item: item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.accessibilityLabel)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

private struct ProviderAuthActionButtonLabel: View {
    let item: ProviderAuthActionItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
            Text(item.title)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
        }
        .foregroundStyle(.tronEmerald)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.tronEmerald.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.tronEmerald.opacity(0.2), lineWidth: 1)
        }
        .contentShape(Capsule())
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

private enum ProviderCredentialDisplayRow: Identifiable {
    case account(AccountInfo)
    case apiKey(ApiKeyInfo)

    var id: String {
        switch self {
        case .account(let account):
            return ProviderCredentialRowItem.oauth(account).id
        case .apiKey(let key):
            return ProviderCredentialRowItem.apiKey(key).id
        }
    }
}
