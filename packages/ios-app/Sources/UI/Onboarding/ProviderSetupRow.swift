import SwiftUI
import TronMobileCore

struct ProviderSetupRow: View {
    var surfaceStyle: ProviderSetupRowSurfaceStyle = .standalone
    let provider: ProviderSummary
    var sessionID: String? = nil
    var usageSnapshot: ProviderUsageSnapshot? = nil
    var isUsageLoading: Bool = false
    @PresentationState private var showsConfiguration: Bool
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        surfaceStyle: ProviderSetupRowSurfaceStyle = .standalone,
        provider: ProviderSummary,
        sessionID: String? = nil,
        usageSnapshot: ProviderUsageSnapshot? = nil,
        isUsageLoading: Bool = false
    ) {
        self.surfaceStyle = surfaceStyle
        self.provider = provider
        self.sessionID = sessionID
        self.usageSnapshot = usageSnapshot
        self.isUsageLoading = isUsageLoading
        _showsConfiguration = PresentationState(wrappedValue: false, key: "\(sessionID ?? "global"):\(provider.id)")
    }

    private var providerTarget: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        surfacedRow
        .tronManagedSheet(
            isPresented: $showsConfiguration,
            identity: "onboarding.provider.\(provider.id)"
        ) {
            ProviderConfigurationSheet(
                provider: provider,
                target: providerTarget
            )
        }
    }

    @ViewBuilder
    private var surfacedRow: some View {
        if surfaceStyle == .standalone {
            row
                .tronScrollSurface(
                    accent: .tronPrimary,
                    cornerRadius: 12,
                    tintOpacity: provider.configured ? 0.14 : 0.08
                )
        } else {
            row
        }
    }

    private var row: some View {
        Group {
            if provider.configured {
                Button { showsConfiguration = true } label: {
                    rowContents {
                        detailsPill
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(provider.displayName)")
                .accessibilityValue(usageAccessibilityValue)
            } else {
                rowContents {
                    Button { showsConfiguration = true } label: {
                        TronInlineActionLabel("Connect", accent: settingsTheme?.accent ?? .tronPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Connect \(provider.displayName)")
                }
            }
        }
        .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? TronSpacing.md : TronSpacing.sm)
        .frame(maxWidth: .infinity, minHeight: TronSettingsLayoutPolicy.rowMinimumHeight, alignment: .leading)
    }

    private var detailsPill: some View {
        TronInlineActionLabel("Details", accent: settingsTheme?.accent ?? .tronPrimary)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func rowContents<Trailing: View>(@ViewBuilder trailing: () -> Trailing) -> some View {
        let rowAccent = settingsTheme?.accent
            ?? (provider.configured ? Color.tronEmerald : Color.tronTextSecondary)
        HStack(alignment: .center, spacing: TronSpacing.xl) {
            providerIcon(rowAccent)
            providerLabels.frame(maxWidth: .infinity, alignment: .leading)
            trailing().fixedSize(horizontal: true, vertical: true)
        }
    }

    private func providerIcon(_ accent: Color) -> some View {
        Image(systemName: provider.configured ? "checkmark.seal.fill" : "key")
            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
            .foregroundStyle(accent)
            .frame(width: TronSettingsLayoutPolicy.iconSize, height: TronSettingsLayoutPolicy.iconSize)
            .accessibilityHidden(true)
    }

    private var providerLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ProviderConfigurationPresentation.connectionDetail(for: provider))
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            usageLine
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: usageLineIdentity)
    }

    @ViewBuilder
    private var usageLine: some View {
        if let usageSnapshot {
            Text(ProviderUsagePresentation.styledSummary(usageSnapshot))
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                .foregroundStyle(usageSnapshot.status == .available ? Color.tronEmerald : Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Account usage: \(ProviderUsagePresentation.summary(usageSnapshot))")
                .transition(.opacity)
        } else if showsLocalUnlimitedIndicator {
            Image(systemName: "infinity")
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
                .transition(.opacity)
                .accessibilityLabel("Local models, no usage limits")
        } else if isUsageLoading {
            ProviderUsageLoadingLine()
                .transition(.opacity)
        }
    }

    private var showsLocalUnlimitedIndicator: Bool {
        ProviderUsagePresentation.showsLocalUnlimited(
            configured: provider.configured,
            localOnly: provider.isLocalOnly,
            snapshot: usageSnapshot,
            isLoading: isUsageLoading
        )
    }

    private var usageLineIdentity: String {
        if let usageSnapshot {
            return "usage:\(usageSnapshot.providerId):\(usageSnapshot.updatedAt ?? "")"
        }
        if showsLocalUnlimitedIndicator { return "local" }
        return isUsageLoading ? "loading" : "none"
    }

    private var usageAccessibilityValue: String {
        if let usageSnapshot {
            return "Account usage: \(ProviderUsagePresentation.summary(usageSnapshot))"
        }
        if showsLocalUnlimitedIndicator { return "Local models, no usage limits" }
        return isUsageLoading ? "Account usage is loading" : "Account usage unavailable"
    }
}
