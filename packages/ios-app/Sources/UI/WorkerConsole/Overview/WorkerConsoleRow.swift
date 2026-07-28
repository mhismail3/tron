import SwiftUI

/// Compact live-worker summary shared by the Worker Console inventory.
struct WorkerConsoleRow: View {
    let worker: WorkerSummaryDTO
    let surface: AvailableWorkerToolDTO?

    private var status: WorkerConsoleStatus {
        WorkerConsolePresentation.status(for: worker)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: status.systemImage)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(status.color)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(worker.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                    Text(status.title)
                        .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                        .foregroundStyle(status.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .glassEffect(.regular.tint(status.color.opacity(0.15)), in: .capsule)
                }

                Text(worker.description)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    compactMetadataLabel(
                        WorkerConsolePresentation.runnerLabel(worker.runnerKind),
                        systemImage: "cpu"
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
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)

                HStack(spacing: 7) {
                    if surface != nil {
                        workerSurfaceBadge("Available to agents", color: .tronSuccess)
                    } else if worker.enabled && !worker.retired {
                        workerSurfaceBadge("Tool unavailable", color: .tronWarning)
                    }
                    Text("Version \(WorkerConsolePresentation.compactIdentifier(worker.activeVersion, length: 8))")
                        .font(TronTypography.code(size: TronTypography.sizeSM))
                        .foregroundStyle(.tronTextMuted)
                }
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(status.color, cornerRadius: 12, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(worker.name), \(status.title), \(WorkerConsolePresentation.runnerLabel(worker.runnerKind))"
        )
    }

    private func workerSurfaceBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .glassEffect(.regular.tint(color.opacity(0.14)), in: .capsule)
    }

    private func compactMetadataLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
            Text(title)
        }
    }
}
