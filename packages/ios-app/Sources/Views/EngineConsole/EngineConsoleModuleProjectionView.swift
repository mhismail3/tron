import SwiftUI

struct EngineConsoleModuleProjectionCard: View {
    let projection: EngineConsoleModuleOperatorProjection

    var body: some View {
        EngineConsoleCard {
            EngineConsoleCardHeader(
                symbol: "shippingbox",
                title: "Modules",
                subtitle: "Package, config, activation, trust, health, evidence, and action projection."
            )

            if projection.isEmpty {
                EngineConsoleEmptyState(
                    symbol: "shippingbox",
                    title: "No modules",
                    message: "Registered packages and activation records will appear here after module capabilities run."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    EngineConsoleBadgeRow(values: [
                        "\(projection.packages.count) packages",
                        "\(projection.configs.count) configs",
                        "\(projection.activations.count) activations",
                        "\(projection.sourceTrust.count) trust rows",
                        "\(projection.health.count) health rows",
                        "\(projection.actions.count) actions",
                        "\(projection.evidenceRefCount) evidence refs"
                    ])

                    resourceSection
                    trustSection
                    healthSection
                    actionSection
                }
            }
        }
    }

    @ViewBuilder
    private var resourceSection: some View {
        if !projection.packages.isEmpty || !projection.configs.isEmpty || !projection.activations.isEmpty {
            moduleSectionTitle("Resources")
            ForEach(Array(projection.packages.prefix(4)), id: \.id) { package in
                EngineConsoleKeyValueRow(
                    package.resourceId,
                    [package.lifecycle, package.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
            ForEach(Array(projection.configs.prefix(3)), id: \.id) { config in
                EngineConsoleKeyValueRow(
                    config.resourceId,
                    [config.lifecycle, config.versionId].compactMap { $0 }.joined(separator: " / ")
                )
            }
            ForEach(Array(projection.activations.prefix(3)), id: \.id) { activation in
                EngineConsoleKeyValueRow(
                    activation.resourceId,
                    [activation.lifecycle, activation.versionId].compactMap { $0 }.joined(separator: " / ")
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
                        trust.sourceTrustStatus,
                        trust.effectiveTrustTier,
                        evidenceText("source", trust.sourceEvidenceRefs.count),
                        evidenceText("approval", trust.sourceApprovalRefs.count),
                        evidenceText("conformance", trust.conformanceEvidenceRefs.count)
                    ]
                    .compactMap { $0 }
                    .joined(separator: " / ")
                )
                if !trust.approvalWarningCodes.isEmpty || !trust.trustWarningCodes.isEmpty {
                    EngineConsoleBadgeRow(values: trust.approvalWarningCodes + trust.trustWarningCodes)
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
            moduleSectionTitle("Actions")
            ForEach(Array(projection.actions.prefix(12)), id: \.id) { action in
                EngineConsoleKeyValueRow(
                    action.functionId,
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

    private func evidenceText(_ label: String, _ count: Int) -> String? {
        count > 0 ? "\(label) \(count)" : nil
    }
}
