import SwiftUI

/// Detail sheet for a single cron run.
@available(iOS 26.0, *)
struct AutomationRunDetailSheet: View {
    let run: CronRunDTO

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status header
                    HStack(spacing: 10) {
                        statusIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.status.capitalized)
                                .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                                .foregroundStyle(statusColor)
                            Text(run.jobName)
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextMuted)
                        }
                        Spacer()
                        if run.attempt > 0 {
                            Text("Attempt \(run.attempt + 1)")
                                .font(TronTypography.codeSM)
                                .foregroundStyle(.tronTextMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.tronCoral.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    Divider()

                    // Timestamps
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Started", value: formatDate(run.startedAt))
                        if let completed = run.completedAt {
                            infoRow("Completed", value: formatDate(completed))
                        }
                        if let duration = run.durationMs {
                            infoRow("Duration", value: formatDuration(duration))
                        }
                        if let exitCode = run.exitCode {
                            infoRow("Exit Code", value: "\(exitCode)")
                        }
                        if let deliveryStatus = run.deliveryStatus {
                            infoRow("Delivery", value: deliveryStatus)
                        }
                        if let sessionId = run.sessionId {
                            infoRow("Session", value: sessionId)
                        }
                    }

                    // Output
                    if let output = run.output, !output.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Output")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
                                    .foregroundStyle(.tronCoral)
                                if run.outputTruncated {
                                    Text("(truncated)")
                                        .font(TronTypography.codeCaption)
                                        .foregroundStyle(.tronTextMuted)
                                }
                            }
                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(output)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.tronTextPrimary)
                                    .textSelection(.enabled)
                            }
                            .padding(12)
                            .background(Color.black.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    // Error
                    if let error = run.error, !error.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Error")
                                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.9))
                                .textSelection(.enabled)
                                .padding(12)
                                .background(Color.red.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Run Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.tronCoral)
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var statusIcon: some View {
        switch run.status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .font(.title)
                .foregroundStyle(.red)
        case "running":
            ProgressView()
                .tint(.tronCoral)
        case "timedOut":
            Image(systemName: "clock.badge.exclamationmark")
                .font(.title)
                .foregroundStyle(.orange)
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
        case "completed": return .green
        case "failed": return .red
        case "running": return .tronCoral
        case "timedOut": return .orange
        case "skipped": return .tronTextMuted
        default: return .tronTextSecondary
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronTextMuted)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
        }
    }

    private func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) else {
            return isoString
        }
        let display = DateFormatter()
        display.dateStyle = .short
        display.timeStyle = .medium
        return display.string(from: date)
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        if ms < 60000 { return String(format: "%.1fs", Double(ms) / 1000) }
        let minutes = ms / 60000
        let seconds = (ms % 60000) / 1000
        return "\(minutes)m \(seconds)s"
    }
}
