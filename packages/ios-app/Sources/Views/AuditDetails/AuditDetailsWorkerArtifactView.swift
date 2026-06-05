import SwiftUI

struct AuditDetailsWorkerArtifactCard: View {
    let projection: AuditDetailsWorkerArtifactProjection

    var body: some View {
        if !projection.isEmpty {
            AuditDetailsCard {
                AuditDetailsCardHeader(
                    symbol: "wand.and.sparkles",
                    title: "Worker Artifacts",
                    subtitle: "Worker history and evidence."
                )

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(projection.changes.prefix(6)), id: \.id) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            AuditDetailsActionRow(
                                symbol: "sparkle.magnifyingglass",
                                title: change.shelfTitle,
                                subtitle: change.shelfSubtitle,
                                tint: .tronPurple
                            )
                            historyStrip(for: change)
                            evidenceGrid(for: change)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(change.accessibilityLabel)
                        .accessibilityValue(change.accessibilityValue)
                    }
                }
            }
        }
    }

    private func historyStrip(for change: AuditDetailsWorkerArtifactSummary) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(change.historyLabels, id: \.self) { label in
                    Label(label, systemImage: symbol(forHistoryLabel: label))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .labelStyle(.titleAndIcon)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(.tronSurfaceElevated.opacity(0.72), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("Worker history")
        .accessibilityValue(change.historyLabels.joined(separator: ", "))
    }

    private func evidenceGrid(for change: AuditDetailsWorkerArtifactSummary) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: 150), spacing: 8)
            ],
            alignment: .leading,
            spacing: 8
        ) {
            evidencePill("Provenance", change.provenanceText, symbol: "person.crop.circle.badge.checkmark")
            evidencePill("Tests", change.testText, symbol: "checkmark.shield")
            evidencePill(
                "Generated UI",
                generatedSurfaceText(for: change),
                symbol: "rectangle.3.group"
            )
            evidencePill("Promotion", change.promotionText, symbol: "arrow.up.forward.circle")
            evidencePill("Cleanup", change.cleanupText, symbol: "trash.circle")
            evidencePill(
                "Trace",
                change.traceIds.isEmpty ? "none" : change.traceIds.prefix(2).joined(separator: ", "),
                symbol: "waterfall"
            )
        }
    }

    private func symbol(forHistoryLabel label: String) -> String {
        switch label {
        case "Created": return "plus.circle"
        case "Updated": return "arrow.triangle.2.circlepath"
        case "Auto-repaired": return "wrench.and.screwdriver"
        case "Tested": return "checkmark.shield"
        case "Failed": return "exclamationmark.triangle"
        case "Promoted": return "arrow.up.forward.circle"
        case "Revoked": return "xmark.shield"
        case "Discarded": return "trash.circle"
        case "Reused": return "arrow.clockwise.circle"
        default: return "circle"
        }
    }

    private func generatedSurfaceText(for change: AuditDetailsWorkerArtifactSummary) -> String {
        let count = change.generatedSurfaceIds.count
        if count == 0 {
            return "none"
        }
        return count == 1 ? "1 surface" : "\(count) surfaces"
    }

    private func evidencePill(_ title: String, _ value: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tronEmerald)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeXXS, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text(value)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(.tronSurfaceElevated.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
