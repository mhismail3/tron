import SwiftUI

@available(iOS 26.0, *)
struct CapabilityDetailHeader: View {
    let data: CapabilityInvocationData

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var accent: Color {
        CapabilityPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(display.capabilityName)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    CapabilityStatusBadge(status: data.status)
                    if let duration = data.formattedDuration {
                        CapabilityHeaderDurationBadge(duration: duration, color: accent)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(summaryLine)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let plugin = CapabilityPresentation.pluginLabel(for: data.identity) {
                CapabilityHeaderMetric(label: "Plugin", value: plugin, tint: tint)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(accent.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }

    private var summaryLine: String {
        var parts = [display.primitiveTitle]
        if let target = display.targetId?.nilIfEmpty {
            parts.append(target)
        }
        return parts.joined(separator: " via ")
    }
}
@available(iOS 26.0, *)
struct CapabilityExecutionGroupView: View {
    let group: CapabilityDisplayGroup
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .foregroundStyle(tint.accent)
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                            .fill(tint.accent.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(.tronTextPrimary)

                    if let summary {
                        Text(summary)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(tint.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !detailRows.isEmpty {
                Divider()
                    .overlay(tint.accent.opacity(0.16))

                CapabilityReadableRows(rows: detailRows, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronSurface.opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.accent.opacity(0.16), lineWidth: 1)
                }
        }
    }

    private var iconName: String {
        switch group.title {
        case "Resolution":
            return "point.topleft.down.curvedto.point.bottomright.up"
        case "Preparation":
            return "checklist.checked"
        case "Run":
            return "play.circle"
        case "Discovery":
            return "magnifyingglass"
        case "Corrections":
            return "wand.and.sparkles"
        default:
            return "circle.grid.cross"
        }
    }

    private var summary: String? {
        switch group.title {
        case "Resolution":
            return [value("Mode"), value("Target").map(humanizeCapability)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "Preparation":
            return [value("Payload"), value("Approval"), value("Corrections")].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "Run":
            return [value("Status"), value("Duration")].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "Discovery":
            return [value("Search"), value("Vector index")].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case "Corrections":
            return value("Applied")
        default:
            return nil
        }
    }

    private var detailRows: [CapabilityDisplayRow] {
        let summarized = Set(summaryLabels)
        return group.rows.filter { !summarized.contains($0.label) }
    }

    private var summaryLabels: [String] {
        switch group.title {
        case "Resolution":
            return ["Mode", "Target"]
        case "Preparation":
            return ["Payload", "Approval", "Corrections"]
        case "Run":
            return ["Status", "Duration"]
        case "Discovery":
            return ["Search", "Vector index"]
        case "Corrections":
            return ["Applied"]
        default:
            return []
        }
    }

    private func value(_ label: String) -> String? {
        group.rows.first { $0.label == label }?.value.nilIfEmpty
    }

    private func humanizeCapability(_ id: String) -> String {
        id.split(separator: "::").last?
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ") ?? id
    }
}

@available(iOS 26.0, *)
struct CapabilityHeaderDurationBadge: View {
    let duration: String
    let color: Color

    var body: some View {
        Text(duration)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(color)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(color.opacity(0.20)), in: Capsule())
            }
            .fixedSize(horizontal: true, vertical: false)
    }
}

@available(iOS 26.0, *)
struct CapabilityHeaderMetric: View {
    let label: String
    let value: String
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 26.0, *)
struct CapabilitySourceBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(TronTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(color.opacity(0.14))
            }
    }
}

@available(iOS 26.0, *)
struct CapabilityArtifactRow: View {
    let artifact: CapabilityArtifactData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: artifactIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronPurple)

                Text(artifact.label?.nilIfEmpty ?? artifact.id)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let mimeType = artifact.mimeType?.nilIfEmpty {
                Text(mimeType)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
            }

            if let url = artifact.url?.nilIfEmpty {
                Text(url)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tronSurface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var artifactIcon: String {
        if artifact.mimeType?.hasPrefix("image/") == true { return "photo" }
        if artifact.mimeType?.contains("json") == true { return "curlybraces" }
        if artifact.mimeType?.contains("text") == true { return "doc.text" }
        return "paperclip"
    }
}

@available(iOS 26.0, *)
struct CapabilityReadableRows: View {
    let rows: [CapabilityDisplayRow]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                CapabilityReadableRow(row: row, tint: tint)
            }
        }
    }
}

@available(iOS 26.0, *)
struct CapabilityReadableRow: View {
    let row: CapabilityDisplayRow
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
            Text(row.value)
                .font(row.isTechnical ? TronTypography.code(size: TronTypography.sizeCaption, weight: .regular) : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(row.isTechnical ? tint.body : .tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 26.0, *)
struct CapabilityRawDisclosure: View {
    let title: String
    let text: String
    let tint: TintedColors

    var body: some View {
        DisclosureGroup {
            CapabilityInvocationCodeBlock(text: text)
                .padding(.top, 8)
        } label: {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)
        }
    }
}
