import SwiftUI

struct ModelProviderSection: View {
    let provider: ProviderInfo
    let providerAuth: ProviderAuthSnapshot?
    let onSetActive: (AuthCredentialSelection) async -> ProviderAuthActionResult
    let onRemoveAccount: (String) async -> ProviderAuthActionResult
    let onRemoveApiKey: (String) async -> ProviderAuthActionResult
    let onAddApiKey: (String, String) async -> ProviderAuthActionResult
    let onOAuthLogin: () -> Void
    let onSaveProvider: (AuthMutation) async -> ProviderAuthActionResult
    let onClear: () async -> ProviderAuthActionResult

    @State private var showAddApiKeyPrompt = false

    private var isConfigured: Bool {
        ProviderStatusHelpers.isProviderConfigured(providerAuth)
    }

    private var accounts: [ProviderAccountSnapshot] { providerAuth?.accounts ?? [] }
    private var apiKeys: [ProviderApiKeySnapshot] { providerAuth?.apiKeys ?? [] }
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
        VStack(alignment: .leading, spacing: 8) {
            providerStatusCard

            if ProviderSettingsContainer.containers(for: provider).contains(.googleCloud) {
                googleCloudCard
            }
        }
        .providerApiKeyAlert(isPresented: $showAddApiKeyPrompt, scope: apiKeyPromptScope) { draft in
            await onAddApiKey(draft.saveLabel(for: apiKeyPromptScope), draft.apiKey)
        }
    }

    private var providerStatusCard: some View {
        SettingsCard {
            ProviderSectionHeader(
                provider: provider,
                isConfigured: isConfigured,
                actionItems: actionItems,
                onSelect: handleAction
            )

            SettingsRowDivider()

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

    private func handleAction(_ item: ProviderAuthActionItem) {
        switch item {
        case .oauthLogin:
            onOAuthLogin()
        case .addApiKey:
            showAddApiKeyPrompt = true
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
                    _ = await onSetActive(AuthCredentialSelection(kind: .oauth, label: account.label))
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
                    _ = await onSetActive(AuthCredentialSelection(kind: .apiKey, label: key.label))
                },
                onDelete: { _ = await onRemoveApiKey(key.label) }
            )
        }
    }

}

struct ProviderSectionHeader: View {
    let provider: ProviderInfo
    let isConfigured: Bool
    let actionItems: [ProviderAuthActionItem]
    let onSelect: (ProviderAuthActionItem) -> Void

    var body: some View {
        HStack(spacing: 6) {
            providerIcon
            Text(provider.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            if isConfigured {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronEmerald)
            }
            Spacer()

            Menu {
                ForEach(actionItems) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(provider.color)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Add \(provider.displayName) credential")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let systemIcon = provider.systemIcon {
            Image(systemName: systemIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(provider.color)
                .frame(width: 20, height: 20)
        } else {
            Image(provider.assetIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(provider.color)
                .frame(width: 20, height: 20)
        }
    }
}

private struct ProviderAccountCredentialRow: Identifiable {
    let item: ProviderCredentialRowItem
    let account: ProviderAccountSnapshot

    init(account: ProviderAccountSnapshot) {
        self.account = account
        item = .oauth(account)
    }

    var id: String {
        item.id
    }
}

private struct ProviderApiKeyCredentialRow: Identifiable {
    let item: ProviderCredentialRowItem
    let key: ProviderApiKeySnapshot

    init(key: ProviderApiKeySnapshot) {
        self.key = key
        item = .apiKey(key)
    }

    var id: String {
        item.id
    }
}

private enum ProviderCredentialDisplayRow: Identifiable {
    case account(ProviderAccountSnapshot)
    case apiKey(ProviderApiKeySnapshot)

    var id: String {
        switch self {
        case .account(let account):
            return ProviderCredentialRowItem.oauth(account).id
        case .apiKey(let key):
            return ProviderCredentialRowItem.apiKey(key).id
        }
    }
}
