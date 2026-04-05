import SwiftUI

/// Detail sheet for a single cron run.
@available(iOS 26.0, *)
struct AutomationRunDetailSheet: View {
    let run: CronRunDTO

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusHeader
                    timingSection
                    if let output = run.output, !output.isEmpty {
                        outputSection(output)
                    }
                    if let error = run.error, !error.isEmpty {
                        errorSection(error)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Run Detail")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronCoral)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronCoral)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Status Header

    private var statusHeader: some View {
        HStack(spacing: 10) {
            statusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(run.status.capitalized)
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(statusColor)
                Text(run.jobName)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextMuted)
            }

            Spacer()

            if run.attempt > 0 {
                Text("Attempt \(run.attempt + 1)")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronCoral)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.tronCoral.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }

    // MARK: - Timing

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Timing", color: .tronCoral)

            SettingsCard(accent: .tronCoral) {
                SettingsRow(icon: "play", label: "Started", accentColor: .tronCoral) {
                    Text(DateParser.shortDateTime(run.startedAt))
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronTextSecondary)
                        .textSelection(.enabled)
                }

                if let completed = run.completedAt {
                    SettingsRowDivider()
                    SettingsRow(icon: "stop", label: "Completed", accentColor: .tronCoral) {
                        Text(DateParser.shortDateTime(completed))
                            .font(TronTypography.mono(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                    }
                }

                if let duration = run.durationMs {
                    SettingsRowDivider()
                    SettingsRow(icon: "timer", label: "Duration", accentColor: .tronCoral) {
                        Text(DurationFormatter.format(duration))
                            .font(TronTypography.mono(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }

                if let exitCode = run.exitCode {
                    SettingsRowDivider()
                    SettingsRow(icon: "number", label: "Exit Code", accentColor: .tronCoral) {
                        Text("\(exitCode)")
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(exitCode == 0 ? .tronSuccess : .tronError)
                    }
                }

                if let deliveryStatus = run.deliveryStatus {
                    SettingsRowDivider()
                    SettingsRow(icon: "paperplane", label: "Delivery", accentColor: .tronCoral) {
                        Text(deliveryStatus)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }

                if let sessionId = run.sessionId {
                    SettingsRowDivider()
                    SettingsRow(icon: "rectangle.stack", label: "Session", accentColor: .tronCoral) {
                        Text(sessionId)
                            .font(TronTypography.code(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Output

    private func outputSection(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SettingsSectionHeader(title: "Output", color: .tronCoral)
                if run.outputTruncated {
                    Spacer()
                    Text("(truncated)")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                        .padding(.bottom, 8)
                }
            }

            SettingsCard(accent: .tronCoral) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(output)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .textSelection(.enabled)
                }
                .padding(12)
            }
        }
    }

    // MARK: - Error

    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Error", color: .tronError)

            SettingsCard(accent: .tronError) {
                Text(error)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronError)
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
    }

    // MARK: - Status Helpers

    @ViewBuilder
    private var statusIcon: some View {
        switch run.status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.tronSuccess)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.tronError)
        case "running":
            ProgressView()
                .tint(.tronCoral)
        case "timedOut":
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title)
                .foregroundStyle(.tronWarning)
        case "skipped":
            Image(systemName: "arrow.right.circle.fill")
                .font(.title)
                .foregroundStyle(.tronTextMuted)
        default:
            Image(systemName: "circle.fill")
                .font(.title)
                .foregroundStyle(.tronTextMuted)
        }
    }

    private var statusColor: Color {
        switch run.status {
        case "completed": return .tronSuccess
        case "failed": return .tronError
        case "running": return .tronCoral
        case "timedOut": return .tronWarning
        case "skipped": return .tronTextMuted
        default: return .tronTextSecondary
        }
    }
}
