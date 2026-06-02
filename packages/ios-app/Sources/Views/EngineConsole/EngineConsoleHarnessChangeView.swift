import SwiftUI

struct EngineConsoleHarnessChangeCard: View {
    let projection: EngineConsoleHarnessChangeProjection

    var body: some View {
        if !projection.isEmpty {
            EngineConsoleCard {
                EngineConsoleCardHeader(
                    symbol: "wand.and.sparkles",
                    title: "Harness Changes",
                    subtitle: "Session-created capability evidence."
                )

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(projection.changes.prefix(6)), id: \.id) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            EngineConsoleActionRow(
                                symbol: "function",
                                title: change.title,
                                subtitle: change.subtitle,
                                tint: .tronPurple
                            )
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

    private func evidenceGrid(for change: EngineConsoleHarnessChangeSummary) -> some View {
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

    private func generatedSurfaceText(for change: EngineConsoleHarnessChangeSummary) -> String {
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
