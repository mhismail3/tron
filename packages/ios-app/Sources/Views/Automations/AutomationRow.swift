import SwiftUI

/// Row component for a cron job in the automations list.
@available(iOS 26.0, *)
struct AutomationRow: View {
    let job: CronJobDTO
    let runtimeState: CronRuntimeStateDTO?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Name + payload type badge
            HStack(spacing: 8) {
                Image(systemName: job.payload.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronCoral)

                Text(job.name)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronCoral)
                    .lineLimit(1)

                Spacer()

                Text(job.payload.typeLabel)
                    .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(.tronCoral.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronCoral.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            // Schedule summary
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(TronTypography.sans(size: TronTypography.sizeSM))
                    .foregroundStyle(.tronTextMuted)

                Text(job.schedule.summary)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)

                Spacer()

                // Status badge
                statusBadge
            }

            // Next run / last run
            if let state = runtimeState {
                HStack(spacing: 12) {
                    if let nextRun = state.nextRunAt {
                        HStack(spacing: 4) {
                            Text("Next:")
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextMuted)
                            Text(formatRelativeDate(nextRun))
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextSecondary)
                        }
                    }
                    if let lastRun = state.lastRunAt {
                        HStack(spacing: 4) {
                            Text("Last:")
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextMuted)
                            Text(formatRelativeDate(lastRun))
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextSecondary)
                        }
                    }
                    Spacer()
                    if state.consecutiveFailures > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(TronTypography.sans(size: TronTypography.sizeSM))
                            Text("\(state.consecutiveFailures)")
                                .font(TronTypography.codeSM)
                        }
                        .foregroundStyle(.red)
                    }
                }
            }

            // Tags
            if !job.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(job.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                            .foregroundStyle(.tronCoral.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.tronCoral.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                    if job.tags.count > 3 {
                        Text("+\(job.tags.count - 3)")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextMuted)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            .regular.tint(Color.tronCoral.opacity(0.15)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let state = runtimeState, state.runningSince != nil {
            HStack(spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.tronCoral)
                Text("Running")
                    .font(TronTypography.codeSM)
            }
            .foregroundStyle(.tronCoral)
        } else if !job.enabled {
            Text("Paused")
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronTextMuted)
        }
    }

    private func formatRelativeDate(_ isoString: String) -> String {
        DateParser.relativeAbbreviated(isoString)
    }
}
