import SwiftUI

struct EngineConsoleModuleProjectionCard: View {
    let projection: EngineConsoleModuleOperatorProjection
    let mutatingDisabled: Bool
    var canOpenSurface: (EngineConsoleModuleSurfaceTarget) -> Bool
    var openSurface: (EngineConsoleModuleSurfaceTarget) -> Void

    var body: some View {
        EngineConsoleCard {
            EngineConsoleCardHeader(
                symbol: "shippingbox",
                title: projection.cardTitle,
                subtitle: projection.cardSubtitle
            )

            if projection.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "shippingbox",
                    title: projection.emptyTitle,
                    message: projection.emptyMessage
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    EngineConsoleBadgeRow(values: [
                        "\(projection.packages.count) packs",
                        "\(projection.configs.count) configs",
                        "\(projection.activations.count) activations",
                        "\(projection.sourceTrust.count) trust rows",
                        "\(projection.health.count) health rows",
                        "\(projection.actions.count) actions",
                        "\(projection.evidenceRefCount) evidence refs"
                    ])

                    surfaceSection
                    resourceSection
                    trustSection
                    healthSection
                    actionSection
                }
            }
        }
    }

    @ViewBuilder
    private var surfaceSection: some View {
        if !projection.surfaceTargets.isEmpty {
            moduleSectionTitle("Pack Surfaces")
            ForEach(Array(projection.surfaceTargets.prefix(6)), id: \.id) { target in
                Button {
                    openSurface(target)
                } label: {
                    EngineConsoleActionRow(
                        symbol: target.symbol,
                        title: target.title,
                        subtitle: target.subtitle,
                        tint: .tronEmerald
                    )
                }
                .buttonStyle(.plain)
                .disabled(mutatingDisabled || !canOpenSurface(target))
            }
        }
    }

    @ViewBuilder
    private var resourceSection: some View {
        if !projection.packages.isEmpty || !projection.configs.isEmpty || !projection.activations.isEmpty {
            moduleSectionTitle("Pack Resources")
            ForEach(Array(projection.packages.prefix(4)), id: \.id) { package in
                EngineConsoleKeyValueRow(
                    package.displayName,
                    [package.lifecycleLabel, package.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
            ForEach(Array(projection.configs.prefix(3)), id: \.id) { config in
                EngineConsoleKeyValueRow(
                    config.displayName,
                    [config.lifecycleLabel, config.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
            ForEach(Array(projection.activations.prefix(3)), id: \.id) { activation in
                EngineConsoleKeyValueRow(
                    activation.displayName,
                    [activation.lifecycleLabel, activation.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
        }
    }

    @ViewBuilder
    private var trustSection: some View {
        if !projection.sourceTrust.isEmpty {
            moduleSectionTitle("Trust")
            ForEach(Array(projection.sourceTrust.prefix(4)), id: \.id) { trust in
                EngineConsoleKeyValueRow(
                    trust.packageId ?? trust.packageResourceId,
                    [
                        trust.presentation.statusLabel,
                        trust.presentation.summary,
                        trust.presentation.sourceLabel,
                        trust.presentation.approvalLabel,
                        trust.presentation.conformanceLabel,
                        trust.presentation.cleanupLabel
                    ]
                    .compactMap { $0 }
                    .joined(separator: " / ")
                )
                if !trust.presentation.warningLabels.isEmpty {
                    EngineConsoleBadgeRow(values: trust.presentation.warningLabels)
                }
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        if !projection.health.isEmpty {
            moduleSectionTitle("Health")
            ForEach(Array(projection.health.prefix(4)), id: \.id) { health in
                EngineConsoleKeyValueRow(
                    health.activationResourceId,
                    [
                        health.activationStatus,
                        health.healthSummary,
                        health.healthEvidenceRef
                    ]
                    .compactMap { $0 }
                    .joined(separator: " / ")
                )
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if !projection.actions.isEmpty {
            moduleSectionTitle("Pack Actions")
            ForEach(Array(projection.actions.prefix(12)), id: \.id) { action in
                EngineConsoleKeyValueRow(
                    action.displayLabel,
                    action.detailText.isEmpty ? "available" : action.detailText
                )
            }
        }
    }

    private func moduleSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(.tronTextSecondary)
            .padding(.top, 2)
    }

}
