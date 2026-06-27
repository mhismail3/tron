import SwiftUI

struct ModuleActivitySummaryCard: View {
    let activity: ModuleActivityOverviewDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.summary.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(activity.summary.detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
            HStack(spacing: 8) {
                summaryMetric("Active", activity.summary.active, .tronCyan)
                summaryMetric("Waiting", activity.summary.waiting, .tronWarning)
                summaryMetric("Blocked", activity.summary.blocked, .tronError)
                summaryMetric("Total", activity.summary.total, .tronTextSecondary)
            }
            if !activity.resources.isEmpty {
                WrapRow(
                    items: activity.resources.prefix(4).map { "\($0.kind.replacingOccurrences(of: "_", with: " ")) \($0.total)" },
                    tint: .tronInfo
                )
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: false)
    }

    private func summaryMetric(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
