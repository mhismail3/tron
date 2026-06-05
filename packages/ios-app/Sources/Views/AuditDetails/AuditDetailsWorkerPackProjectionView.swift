import SwiftUI

struct AuditDetailsWorkerPackProjectionCard: View {
    let projection: AuditDetailsWorkerPackOperatorProjection
    let mutatingDisabled: Bool
    var canOpenSurface: (AuditDetailsWorkerPackSurfaceTarget) -> Bool
    var openSurface: (AuditDetailsWorkerPackSurfaceTarget) -> Void

    var body: some View {
        AuditDetailsCard {
            AuditDetailsCardHeader(
                symbol: "shippingbox",
                title: projection.cardTitle,
                subtitle: projection.cardSubtitle
            )

            if projection.isEmpty {
                AuditDetailsEmptyState(
                    symbol: "shippingbox",
                    title: projection.emptyTitle,
                    message: projection.emptyMessage
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    AuditDetailsBadgeRow(values: [
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
                    AuditDetailsActionRow(
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
                AuditDetailsKeyValueRow(
                    package.displayName,
                    [package.lifecycleLabel, package.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
            ForEach(Array(projection.configs.prefix(3)), id: \.id) { config in
                AuditDetailsKeyValueRow(
                    config.displayName,
                    [config.lifecycleLabel, config.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
            ForEach(Array(projection.activations.prefix(3)), id: \.id) { activation in
                AuditDetailsKeyValueRow(
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
                AuditDetailsKeyValueRow(
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
                    AuditDetailsBadgeRow(values: trust.presentation.warningLabels)
                }
            }
        }
    }

    @ViewBuilder
    private var healthSection: some View {
        if !projection.health.isEmpty {
            moduleSectionTitle("Health")
            ForEach(Array(projection.health.prefix(4)), id: \.id) { health in
                AuditDetailsKeyValueRow(
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
                AuditDetailsKeyValueRow(
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
