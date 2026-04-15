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
                VStack(alignment: .leading, spacing: 24) {
                    configurationSection
                    runtimeSection
                    actionsSection
                    recentRunsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: currentJob.name, color: .tronCoral)
                        .lineLimit(1)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCoral)
                }
            }
        }
        .sheet(item: $selectedRun) { run in
            AutomationRunDetailSheet(run: run)
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .task {
            await refreshJob()
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Configuration", color: .tronCoral)

            SettingsCard(accent: .tronCoral) {
                SettingsRow(icon: currentJob.payload.icon, label: currentJob.payload.typeLabel, accentColor: .tronCoral) {
                    Text(currentJob.enabled ? "Active" : "Paused")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(currentJob.enabled ? .tronSuccess : .tronTextMuted)
                }

                SettingsRowDivider()

                SettingsRow(icon: "clock", label: "Schedule", accentColor: .tronCoral) {
                    Text(currentJob.schedule.summary)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }

                payloadDetailRows

                if let desc = currentJob.description, !desc.isEmpty {
                    SettingsRowDivider()
                    SettingsRow(icon: "text.alignleft", label: "Description", accentColor: .tronCoral) {
                        Text(desc)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                    }
                }

                if !currentJob.tags.isEmpty {
                    SettingsRowDivider()
                    tagsRow
                }
            }
        }
    }

    @ViewBuilder
    private var payloadDetailRows: some View {
        switch currentJob.payload {
        case .shellCommand(let command, _, _):
            SettingsRowDivider()
            SettingsRow(icon: "terminal.fill", label: "Command", accentColor: .tronCoral) {
                Text(command)
                    .font(TronTypography.code(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
            }
        case .agentTurn(let prompt, let model, _, _):
            SettingsRowDivider()
            SettingsRow(icon: "brain", label: "Prompt", accentColor: .tronCoral) {
                Text(prompt)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(2)
            }
            if let model {
                SettingsRowDivider()
                SettingsRow(icon: "cpu", label: "Model", accentColor: .tronCoral) {
                    Text(model)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronTextSecondary)
                }
            }
        case .webhook(let url, let method, _, _, _):
            SettingsRowDivider()
            SettingsRow(icon: "link", label: "URL", accentColor: .tronCoral) {
                Text(url)
                    .font(TronTypography.code(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
            }
            if let method {
                SettingsRowDivider()
                SettingsRow(icon: "arrow.up.arrow.down", label: "Method", accentColor: .tronCoral) {
                    Text(method.uppercased())
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronCoral)
                }
            }
        case .systemEvent(let sessionId, _):
            SettingsRowDivider()
            SettingsRow(icon: "bolt.fill", label: "Session", accentColor: .tronCoral) {
                Text(sessionId)
                    .font(TronTypography.code(size: TronTypography.sizeBody3))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var tagsRow: some View {
        HStack {
            Image(systemName: "tag")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronCoral)
                .frame(width: 18)
            ForEach(currentJob.tags, id: \.self) { tag in
                Text(tag)
                    .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(.tronCoral.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronCoral.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Runtime

    @ViewBuilder
    private var runtimeSection: some View {
        if let state = currentRuntimeState, hasRuntimeInfo(state) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Runtime", color: .tronCoral)

                SettingsCard(accent: .tronCoral) {
                    runtimeRows(state)
                }
            }
        }
    }

    private func hasRuntimeInfo(_ state: CronRuntimeStateDTO) -> Bool {
        state.nextRunAt != nil || state.lastRunAt != nil || state.consecutiveFailures > 0 || state.runningSince != nil
    }

    @ViewBuilder
    private func runtimeRows(_ state: CronRuntimeStateDTO) -> some View {
        let items = buildRuntimeItems(state)
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if index > 0 { SettingsRowDivider() }
            SettingsRow(icon: item.icon, label: item.label, accentColor: item.accent) {
                if item.showSpinner {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.tronCoral)
                        Text(item.value)
                            .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(item.accent)
                    }
                } else {
                    Text(item.value)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(item.valueColor)
                }
            }
        }
    }

    private struct RuntimeItem {
        let icon: String
        let label: String
        let value: String
        let accent: Color
        var valueColor: Color = .tronTextSecondary
        var showSpinner: Bool = false
    }

    private func buildRuntimeItems(_ state: CronRuntimeStateDTO) -> [RuntimeItem] {
        var items: [RuntimeItem] = []
        if let nextRun = state.nextRunAt {
            items.append(RuntimeItem(icon: "arrow.right.circle", label: "Next Run", value: DateParser.shortDateTime(nextRun), accent: .tronCoral))
        }
        if let lastRun = state.lastRunAt {
            items.append(RuntimeItem(icon: "arrow.left.circle", label: "Last Run", value: DateParser.shortDateTime(lastRun), accent: .tronCoral))
        }
        if state.consecutiveFailures > 0 {
            items.append(RuntimeItem(icon: "exclamationmark.triangle", label: "Failures", value: "\(state.consecutiveFailures) consecutive", accent: .tronError, valueColor: .tronError))
        }
        if state.runningSince != nil {
            items.append(RuntimeItem(icon: "play.circle.fill", label: "Status", value: "Running", accent: .tronCoral, showSpinner: true))
        }
        return items
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
                    .foregroundStyle(.tronCoral)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .glassEffect(
                .regular.tint(Color.tronCoral.opacity(0.2)).interactive(),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
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
                let tint: Color = currentJob.enabled ? .orange : .tronSuccess
                Label(currentJob.enabled ? "Pause" : "Enable", systemImage: currentJob.enabled ? "pause.fill" : "play.fill")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .glassEffect(
                .regular.tint((currentJob.enabled ? Color.orange : Color.tronSuccess).opacity(0.2)).interactive(),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .disabled(isPerformingAction)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronError)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .glassEffect(
                .regular.tint(Color.tronError.opacity(0.2)).interactive(),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .disabled(isPerformingAction)
        }
        .opacity(isPerformingAction ? 0.6 : 1)
    }

    // MARK: - Recent Runs

    private var recentRunsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Recent Runs", color: .tronCoral)

            if isLoadingRuns {
                ProgressView()
                    .tint(.tronCoral)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else if recentRuns.isEmpty {
                Text("No runs yet")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                SettingsCard(accent: .tronCoral) {
                    ForEach(Array(recentRuns.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { SettingsRowDivider() }
                        runRow(run)
                    }
                }
            }
        }
    }

    private func runRow(_ run: CronRunDTO) -> some View {
        HStack(spacing: 10) {
            runStatusIcon(run.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(DateParser.shortDateTime(run.startedAt))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
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
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { selectedRun = run }
    }

    // MARK: - Run Status

    @ViewBuilder
    private func runStatusIcon(_ status: String) -> some View {
        switch status {
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tronSuccess)
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tronError)
        case "running":
            ProgressView()
                .controlSize(.mini)
                .tint(.tronCoral)
        case "timedOut":
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.tronWarning)
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
        case "completed": return .tronSuccess
        case "failed": return .tronError
        case "running": return .tronCoral
        case "timedOut": return .tronWarning
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
