import SwiftUI

struct ModuleActivitySummaryCard: View {
    let activity: ModuleActivityOverviewDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
            HStack(spacing: 8) {
                summaryMetric("Active", activity.summary.active, .tronCyan)
                summaryMetric("Waiting", activity.summary.waiting, .tronWarning)
                summaryMetric("Blocked", activity.summary.blocked, .tronError)
                summaryMetric("Degraded", degradedCount, .tronWarning)
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

    private var title: String {
        activity.summary.total == 0 ? "No engine work" : activity.summary.title
    }

    private var detail: String {
        activity.summary.total == 0
            ? "No engine or module work is running, waiting, or blocked."
            : activity.summary.detail
    }

    private var degradedCount: Int {
        activity.summary.degraded ?? activity.timeline.filter {
            AgentCockpitProjection.normalized($0.status) == "degraded"
        }.count
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
