import SwiftUI

/// Detail sheet for a single cron job showing config, runtime state, and recent runs.
/// Owns its own state and refreshes after actions for real-time updates.
@available(iOS 26.0, *)
struct AutomationDetailSheet: View {
    let rpcClient: RPCClient
    let onTrigger: () -> Void
    let onDelete: () -> Void
    let onToggleEnabled: () -> Void

    @State private var currentJob: CronJobDTO
    @State private var currentRuntimeState: CronRuntimeStateDTO?
    @State private var recentRuns: [CronRunDTO] = []
    @State private var isLoadingRuns = true
    @State private var isPerformingAction = false
    @State private var selectedRun: CronRunDTO?
    @Environment(\.dismiss) private var dismiss

    init(
        rpcClient: RPCClient,
        job: CronJobDTO,
        initialRuntimeState: CronRuntimeStateDTO?,
        onTrigger: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onToggleEnabled: @escaping () -> Void
    ) {
        self.rpcClient = rpcClient
        self._currentJob = State(initialValue: job)
        self._currentRuntimeState = State(initialValue: initialRuntimeState)
        self.onTrigger = onTrigger
        self.onDelete = onDelete
        self.onToggleEnabled = onToggleEnabled
    }

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(currentJob.name)
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronCoral)
                        .lineLimit(1)
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
        .sheet(item: $selectedRun) { run in
            AutomationRunDetailSheet(run: run)
        }
        .task {
            await refreshJob()
        }
    }

    // MARK: - Job Info

    private var jobInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Configuration")

            infoRow("Type", value: currentJob.payload.typeLabel, icon: currentJob.payload.icon)
            infoRow("Schedule", value: currentJob.schedule.summary, icon: "clock")
            infoRow("Status", value: currentJob.enabled ? "Active" : "Paused", icon: "circle.fill",
                     color: currentJob.enabled ? .green : .tronTextMuted)

            if let desc = currentJob.description, !desc.isEmpty {
                infoRow("Description", value: desc, icon: "text.alignleft")
            }

            switch currentJob.payload {
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

            if !currentJob.tags.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "tag")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                        .frame(width: 20)
                    ForEach(currentJob.tags, id: \.self) { tag in
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.tronCoral.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Runtime State

    @ViewBuilder
    private var runtimeStateSection: some View {
        if let state = currentRuntimeState {
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.tronCoral.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    isPerformingAction = true
                    onTrigger()
                    try? await Task.sleep(for: .milliseconds(500))
                    await refreshJob()
                    isPerformingAction = false
                }
            } label: {
                Label("Run Now", systemImage: "play.fill")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.tronCoral)
            .disabled(isPerformingAction)

            Button {
                Task {
                    isPerformingAction = true
                    onToggleEnabled()
                    try? await Task.sleep(for: .milliseconds(300))
                    await refreshJob()
                    isPerformingAction = false
                }
            } label: {
                Label(currentJob.enabled ? "Pause" : "Enable",
                      systemImage: currentJob.enabled ? "pause.fill" : "play.fill")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(currentJob.enabled ? .orange : .green)
            .disabled(isPerformingAction)

            Spacer()

            Button(action: onDelete) {
                Label("Delete", systemImage: "trash")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isPerformingAction)
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

    private func refreshJob() async {
        do {
            let result = try await rpcClient.cron.getJob(jobId: currentJob.id)
            currentJob = result.job
            currentRuntimeState = result.runtimeState
            recentRuns = result.recentRuns
            isLoadingRuns = false
        } catch {
            isLoadingRuns = false
        }
    }
}
