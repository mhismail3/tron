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
    private var credentialRows: [ProviderCredentialDisplayRow] {
        accountRows.map { .account($0.account) } + apiKeyRows.map { .apiKey($0.key) }
    }
    private var actionItems: [ProviderAuthActionItem] {
        ProviderAuthActionItem.items(for: provider)
    }
    private var oauthLoginDisabled: Bool {
        provider.supportsOAuth && ProviderStatusHelpers.hasRefreshableOAuth(providerAuth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProviderSectionHeader(provider: provider, isConfigured: isConfigured)

            VStack(alignment: .leading, spacing: 8) {
                providerStatusCard
                providerActionsCard

                if ProviderSettingsContainer.containers(for: provider).contains(.googleCloud) {
                    googleCloudCard
                }
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

    private var providerActionsCard: some View {
        SettingsCard {
            ForEach(Array(actionItems.enumerated()), id: \.element.id) { index, item in
                actionRow(item)
                if index < actionItems.count - 1 || (item == .addApiKey && showAddApiKey) {
                    SettingsRowDivider()
                }
            }

            if showAddApiKey {
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

    private func actionRow(_ item: ProviderAuthActionItem) -> some View {
        let disabled = item == .oauthLogin && oauthLoginDisabled
        let title = item == .addApiKey && showAddApiKey ? "Hide API Key" : item.title
        let icon = item == .addApiKey && showAddApiKey ? "chevron.up" : item.icon

        return HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
            Spacer()
            Image(systemName: item == .addApiKey && showAddApiKey ? "chevron.up" : "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.accessibilityLabel)
        .opacity(disabled ? 0.5 : 1.0)
        .onTapGesture {
            guard !disabled else { return }
            switch item {
            case .oauthLogin:
                onOAuthLogin()
            case .addApiKey:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showAddApiKey.toggle()
                }
            }
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
