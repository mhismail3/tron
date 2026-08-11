import SwiftUI

/// Compact live-worker summary shared by the Worker Console inventory.
struct WorkerConsoleRow: View {
    let worker: WorkerSummaryDTO
    let surface: AvailableWorkerToolDTO?
    let architecture: WorkerArchitectureNodeDTO?

    private var status: WorkerConsoleStatus {
        WorkerConsolePresentation.status(for: worker)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(worker.name)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(worker.description)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(2)

            FlowLayout(spacing: 8) {
                compactMetadataLabel(
                    "Version \(WorkerConsolePresentation.compactIdentifier(worker.activeVersion, length: 8))",
                    systemImage: "number"
                )
                compactMetadataLabel(
                    WorkerConsolePresentation.triggerLabel(worker.triggerCount),
                    systemImage: "alarm"
                )
                if let surface {
                    compactMetadataLabel(
                        WorkerConsolePresentation.completedRunLabel(surface.completedRuns),
                        systemImage: "checkmark.circle"
                    )
                }
                if let architecture {
                    if !architecture.engineHooks.isEmpty {
                        compactMetadataLabel(
                            countLabel(architecture.engineHooks.count, singular: "hook"),
                            systemImage: "arrow.triangle.branch"
                        )
                    }
                    let boundaryCount = architecture.clientActions.count
                        + architecture.clientDeliveries.count
                    if boundaryCount > 0 {
                        compactMetadataLabel(
                            countLabel(boundaryCount, singular: "boundary"),
                            systemImage: "iphone.and.arrow.forward"
                        )
                    }
                    if !architecture.calls.isEmpty {
                        compactMetadataLabel(
                            countLabel(architecture.calls.count, singular: "connection"),
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                }
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)

            FlowLayout(spacing: 5) {
                workerTag(status.title, color: status.color)
                exposureTag
                if architecture?.hasIntegrationBoundary == true {
                    workerTag("Integrated worker", color: .tronPurple)
                }
                if architecture?.needsAgentRoleReview == true {
                    workerTag("Role review needed", color: .tronWarning)
                }
                workerTag(
                    WorkerConsolePresentation.runnerLabel(worker.runnerKind),
                    color: .tronInfo
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(status.color, cornerRadius: 12, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(worker.name), \(status.title), \(WorkerConsolePresentation.runnerLabel(worker.runnerKind))"
        )
    }

    @ViewBuilder
    private var exposureTag: some View {
        if let architecture {
            if architecture.modelExposure == "direct" {
                workerTag("Direct chat tool", color: .tronSuccess)
            } else {
                workerTag("Delegated worker", color: .tronInfo)
            }
        } else if surface != nil {
            workerTag("Direct chat tool", color: .tronSuccess)
        } else if worker.enabled && !worker.retired {
            workerTag("Exposure unavailable", color: .tronWarning)
        }
    }

    private func workerTag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .lineLimit(1)
    }

    private func compactMetadataLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
        }
    }

    private func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }
}
