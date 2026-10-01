import SwiftUI
import TronMobileCore

/// Shared lightweight account/server row used by Connected Services and MCP.
struct IntegrationConfiguredRow: View {
    let title: String
    let account: String
    let status: String
    let usage: String?
    let isLoadingUsage: Bool
    let configured: Bool
    let actionTitle: String
    let accessibilityAction: String
    let accent: Color
    let action: () -> Void
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    private var connected: Bool { configured && status.hasPrefix("Connected ·") }

    var body: some View {
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            Image(systemName: connected ? "checkmark.seal.fill" : (configured ? "exclamationmark.circle" : "link"))
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(connected ? Color.tronEmerald : (configured ? Color.tronAmber : accent))
                .frame(width: TronSettingsLayoutPolicy.iconSize, height: TronSettingsLayoutPolicy.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                if !account.isEmpty {
                    Text(account)
                        .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(1)
                }
                Text(status)
                    .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                    // Like Providers: an unconfigured service is neutral; only a
                    // configured account that needs attention is amber.
                    .foregroundStyle(connected ? Color.tronEmerald : (configured ? Color.tronAmber : Color.tronTextMuted))
                    .fixedSize(horizontal: false, vertical: true)
                if isLoadingUsage {
                    Text("Loading credits…")
                        .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                        .foregroundStyle(Color.tronTextMuted)
                        .accessibilityIdentifier("integration-credit-pending")
                } else if let usage {
                    Text(usage)
                        .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                        .foregroundStyle(Color.tronEmerald)
                        .accessibilityLabel(usage)
                }
            }
            Spacer(minLength: TronSpacing.md)
            Button(action: action) {
                TronInlineActionLabel(actionTitle, accent: configured ? .tronEmerald : accent)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityAction)
        }
        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
        .padding(.vertical, TronSpacing.xl)
        .frame(maxWidth: .infinity, minHeight: TronSettingsLayoutPolicy.rowMinimumHeight, alignment: .leading)
    }
}
