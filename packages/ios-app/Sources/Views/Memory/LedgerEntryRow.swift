import SwiftUI

@available(iOS 26.0, *)
struct LedgerEntryRow: View {
    let entry: LedgerEntryDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Title + type badge + date
            HStack(spacing: 6) {
                Text(entry.title ?? "Untitled")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.purple)
                    .lineLimit(1)

                if let entryType = entry.entryType {
                    Text(entryType)
                        .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(colorForType(entryType))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(colorForType(entryType).opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()

                Text(relativeDate(entry.timestamp))
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Row 2: Input text
            if let input = entry.input, !input.isEmpty {
                Text(input)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            }

            // Row 3: Tags
            if !entry.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entry.tags, id: \.self) { tag in
                            Text(tag)
                                .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                                .foregroundStyle(.purple.opacity(0.8))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.purple.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Row 4: Model + action count
            HStack(spacing: 12) {
                if let model = entry.model {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text(formatModelDisplayName(model))
                            .font(TronTypography.codeSM)
                    }
                    .foregroundStyle(.white.opacity(0.4))
                }

                if !entry.actions.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text("\(entry.actions.count) action\(entry.actions.count == 1 ? "" : "s")")
                            .font(TronTypography.codeSM)
                    }
                    .foregroundStyle(.white.opacity(0.4))
                }

                if !entry.files.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        Text("\(entry.files.count) file\(entry.files.count == 1 ? "" : "s")")
                            .font(TronTypography.codeSM)
                    }
                    .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .regular.tint(Color.purple.opacity(0.12)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
    }

    // MARK: - Helpers

    private func colorForType(_ type: String) -> Color {
        switch type.lowercased() {
        case "feature": .green
        case "bugfix": .red
        case "refactor": .cyan
        case "docs": .blue
        case "config": .orange
        case "research": .yellow
        case "conversation": .purple
        default: .white.opacity(0.6)
        }
    }

    private func relativeDate(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp) else {
            return timestamp
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
