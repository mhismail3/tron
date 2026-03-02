import SwiftUI

/// Detail sheet for a single cron job showing config, runtime state, and recent runs.
@available(iOS 26.0, *)
struct AutomationDetailSheet: View {
    let rpcClient: RPCClient
    let job: CronJobDTO
    let runtimeState: CronRuntimeStateDTO?
    let onTrigger: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: () -> Void

    @State private var recentRuns: [CronRunDTO] = []
    @State private var isLoadingRuns = true
    @State private var selectedRun: CronRunDTO?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    jobInfoSection
                    runtimeStateSection
                    actionsSection
                    recentRunsSection
                }
                .padding()
            }
            .navigationTitle(job.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.tronCoral)
                }
            }
        }
        .sheet(item: $selectedRun) { run in
            AutomationRunDetailSheet(run: run)
        }
        .task {
            await loadRuns()
        }
    }

    // MARK: - Job Info

    private var jobInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Configuration")

            infoRow("Type", value: job.payload.typeLabel, icon: job.payload.icon)
            infoRow("Schedule", value: job.schedule.summary, icon: "clock")
            infoRow("Status", value: job.enabled ? "Active" : "Paused", icon: "circle.fill",
                     color: job.enabled ? .green : .tronTextMuted)

            if let desc = job.description, !desc.isEmpty {
                infoRow("Description", value: desc, icon: "text.alignleft")
            }

            // Payload details
            switch job.payload {
            case .shellCommand(let command, _, _):
                payloadDetail("Command", value: command)
            case .agentTurn(let prompt, let model, _, _):
                payloadDetail("Prompt", value: prompt)
                if let model { payloadDetail("Model", value: model) }
            case .webhook(let url, let method, _, _, _):
                payloadDetail("URL", value: url)
                if let method { payloadDetail("Method", value: method.uppercased()) }
            case .systemEvent(let sessionId, _):
                payloadDetail("Session", value: sessionId)
            }

            if !job.tags.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                        .frame(width: 20)
                    ForEach(job.tags, id: \.self) { tag in
                        Text(tag)
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronCoral.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.tronCoral.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
        .padding()
        .background(Color.tronCoral.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Runtime State

    @ViewBuilder
    private var runtimeStateSection: some View {
        if let state = runtimeState {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Runtime")

                if let nextRun = state.nextRunAt {
                    infoRow("Next Run", value: DateParser.shortDateTime(nextRun), icon: "arrow.right.circle")
                }
                if let lastRun = state.lastRunAt {
                    infoRow("Last Run", value: DateParser.shortDateTime(lastRun), icon: "arrow.left.circle")
                }
                if state.consecutiveFailures > 0 {
                    infoRow("Failures", value: "\(state.consecutiveFailures) consecutive",
                            icon: "exclamationmark.triangle", color: .red)
                }
                if state.runningSince != nil {
                    infoRow("Status", value: "Currently running", icon: "play.circle.fill", color: .tronCoral)
                }
            }
            .padding()
            .background(Color.tronCoral.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button(action: onTrigger) {
                Label("Run Now", systemImage: "play.fill")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.tronCoral)

            Button(action: onToggleEnabled) {
                Label(job.enabled ? "Pause" : "Enable",
                      systemImage: job.enabled ? "pause.fill" : "play.fill")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(job.enabled ? .orange : .green)

            Spacer()

            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    // MARK: - Recent Runs

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Recent Runs")

            if isLoadingRuns {
                ProgressView()
                    .tint(.tronCoral)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if recentRuns.isEmpty {
                Text("No runs yet")
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(recentRuns) { run in
                    runRow(run)
                        .onTapGesture { selectedRun = run }
                }
            }
        }
    }

    @ViewBuilder
    private func runRow(_ run: CronRunDTO) -> some View {
        HStack(spacing: 10) {
            runStatusIcon(run.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(DateParser.shortDateTime(run.startedAt))
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextPrimary)

                if let duration = run.durationMs {
                    Text(DurationFormatter.format(duration))
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }
            }

            Spacer()

            Text(run.status)
                .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                .foregroundStyle(runStatusColor(run.status))

            Image(systemName: "chevron.right")
                .font(TronTypography.labelSM)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.tronCoral.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .bold))
            .foregroundStyle(.tronCoral)
    }

    private func infoRow(_ label: String, value: String, icon: String, color: Color = .tronTextSecondary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(TronTypography.codeSM)
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronTextMuted)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(TronTypography.codeSM)
                .foregroundStyle(color)
                .lineLimit(2)
        }
    }

    private func payloadDetail(_ label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("")
                .frame(width: 20)
            Text(label)
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronTextMuted)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextSecondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func runStatusIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case "running":
            ProgressView()
                .controlSize(.mini)
                .tint(.tronCoral)
        case "timedOut":
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        case "skipped":
            Image(systemName: "arrow.right.circle")
                .foregroundStyle(.tronTextMuted)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.tronTextMuted)
        }
    }

    private func runStatusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "failed": return .red
        case "running": return .tronCoral
        case "timedOut": return .orange
        case "skipped": return .tronTextMuted
        default: return .tronTextSecondary
        }
    }

    private func loadRuns() async {
        isLoadingRuns = true
        do {
            let result = try await rpcClient.cron.getRuns(jobId: job.id, limit: 10)
            await MainActor.run {
                recentRuns = result.runs
                isLoadingRuns = false
            }
        } catch {
            await MainActor.run {
                isLoadingRuns = false
            }
        }
    }
}
