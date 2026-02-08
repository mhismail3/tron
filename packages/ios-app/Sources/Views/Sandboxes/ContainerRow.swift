import SwiftUI

@available(iOS 26.0, *)
struct ContainerRow: View {
    let container: ContainerDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Row 1: Name + status badge + relative date
            HStack(spacing: 6) {
                Text(container.name)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronIndigo)
                    .lineLimit(1)

                statusBadge

                Spacer()

                Text(relativeDate(container.createdAt))
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Row 2: Image name
            Text(container.image)
                .font(TronTypography.mono(size: TronTypography.sizeBody3))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)

            // Row 3: Ports + purpose
            if !container.ports.isEmpty || container.purpose != nil {
                HStack(spacing: 6) {
                    ForEach(container.ports, id: \.self) { port in
                        Text(port)
                            .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                            .foregroundStyle(.tronIndigo.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.tronIndigo.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    if let purpose = container.purpose {
                        Text(purpose)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }

                    Spacer()
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .regular.tint(Color.tronIndigo.opacity(0.12)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        Text(container.status)
            .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch container.status {
        case "running": .green
        case "stopped": .gray
        case "gone": .red
        default: .white.opacity(0.5)
        }
    }

    // MARK: - Helpers

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
