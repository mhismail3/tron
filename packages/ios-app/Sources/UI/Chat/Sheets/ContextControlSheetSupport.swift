import SwiftUI

extension ContextControlSheet {
enum SessionBriefingMutation {
    case compact
    case clear
}

struct SessionBriefingSection<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionBriefingGlassCard<Content: View>: View {
    let color: Color
    var subtle = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .sectionFill(color, cornerRadius: 12, subtle: subtle, interactive: false)
    }
}

struct SessionBriefingToolbarButton: View {
    let icon: String
    let color: Color
    var isBusy = false
    var isEnabled = true
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBusy {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(color)
            } else {
                Image(systemName: icon)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(isEnabled ? color : .tronTextDisabled)
            }
        }
        .disabled(!isEnabled || isBusy)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SessionBriefingMetricStrip: View {
    let metrics: [ContextControlMetric]
    var tint: Color = .tronEmerald

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(metrics.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.opacity(0.16))
                        .padding(.vertical, 2)
                }
                SessionBriefingMetricStripItem(metric: metrics[index], tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionBriefingMetricStripItem: View {
    let metric: ContextControlMetric
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metric.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.opacity(0.72))
                .lineLimit(1)
            Text(metric.value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

struct SessionBriefingInlineRows: View {
    let rows: [ContextControlMetric]
    var tint: Color = .tronEmerald

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.opacity(0.13))
                }
                SessionBriefingInlineRow(metric: rows[index], tint: tint)
            }
        }
    }
}

private struct SessionBriefingInlineRow: View {
    let metric: ContextControlMetric
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.opacity(0.72))
            Text(metric.value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(4)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct SessionBriefingEmptyLine: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum SessionBriefingSupport {
    static func removingDuplicates(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
}
