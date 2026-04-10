import SwiftUI

// MARK: - Wait Tool Detail Sheet

/// Detail sheet for the Wait tool.
/// Shows a list of jobs being waited on with live status, and drill-down
/// into individual process output or subagent chat history.
@available(iOS 26.0, *)
struct WaitToolDetailSheet: View {
    let data: CommandToolChipData
    let viewModel: ChatViewModel
    let rpcClient: RPCClient
    let sessionId: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dependencies) private var dependencies

    @State private var drillDownSheet: DrillDownTarget?

    private var tint: TintedColors {
        TintedColors(accent: .tronTeal, colorScheme: colorScheme)
    }

    // MARK: - Drill-Down Target

    private enum DrillDownTarget: Identifiable, Equatable {
        case process(toolCallId: String)
        case agent(sessionId: String)

        var id: String {
            switch self {
            case .process(let toolCallId): return "proc-\(toolCallId)"
            case .agent(let sessionId): return "agent-\(sessionId)"
            }
        }
    }

    // MARK: - Argument Extraction

    private var jobIds: [String] {
        ToolArgumentParser.stringArray("ids", from: data.arguments) ?? []
    }

    private var waitMode: String {
        ToolArgumentParser.string("mode", from: data.arguments) ?? "all"
    }

    private var timeoutMs: Int? {
        ToolArgumentParser.integer("timeout", from: data.arguments)
    }

    // MARK: - Details Extraction

    private var completedCount: Int {
        if let count = data.details?.int("completed") { return count }
        return jobIds.reduce(0) { count, id in
            count + (jobStatus(for: id) == .completed ? 1 : 0)
        }
    }

    private var failedCount: Int {
        data.details?.int("failed") ?? 0
    }

    // MARK: - Body

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Wait",
            iconName: "clock.arrow.circlepath",
            accent: .tronTeal
        ) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    statusRow
                        .sheetSection()

                    if !jobIds.isEmpty {
                        jobsSection
                            .sheetSection()
                    }

                    contentSection
                        .sheetSection()
                }
                .padding(.vertical)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $drillDownSheet) { target in
            drillDownContent(for: target)
        }
    }

    // MARK: - Content Section

    @ViewBuilder
    private var contentSection: some View {
        switch data.status {
        case .running:
            ToolRunningSpinner(
                title: "Status",
                accent: .tronTeal,
                tint: tint,
                actionText: "Waiting for \(jobIds.count) job\(jobIds.count == 1 ? "" : "s")..."
            )
        case .success:
            if let result = data.result, !result.isEmpty {
                resultSection(result)
            }
        case .error:
            if let result = data.result {
                ToolClassifiedErrorSection(
                    errorMessage: result,
                    classification: ErrorClassification(
                        icon: "clock.badge.exclamationmark",
                        title: "Wait Failed",
                        code: nil,
                        suggestion: "Some jobs may have timed out or failed."
                    ),
                    colorScheme: colorScheme
                )
            }
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        ToolStatusRow(status: data.status, durationMs: data.durationMs) {
            ToolInfoPill(
                icon: waitMode == "any" ? "1.circle" : "circle.grid.2x2",
                label: waitMode == "any" ? "Any" : "All",
                color: .tronTeal
            )
            ToolInfoPill(
                icon: "number",
                label: "\(jobIds.count) job\(jobIds.count == 1 ? "" : "s")",
                color: .tronSlate
            )
            if data.status == .running || data.status == .success {
                let done = completedCount + failedCount
                if done > 0 {
                    ToolInfoPill(
                        icon: "checkmark.circle",
                        label: "\(done)/\(jobIds.count) done",
                        color: .tronEmerald
                    )
                }
            }
            if let timeout = timeoutMs {
                let seconds = Double(timeout) / 1000.0
                ToolInfoPill(
                    icon: "timer",
                    label: seconds >= 60 ? "\(Int(seconds / 60))m" : "\(Int(seconds))s timeout",
                    color: .tronAmber
                )
            }
        }
    }

    // MARK: - Jobs Section

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jobs")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)

            VStack(spacing: 0) {
                ForEach(Array(jobIds.enumerated()), id: \.element) { index, jobId in
                    if index > 0 {
                        Divider()
                            .foregroundStyle(.tronTextDisabled.opacity(0.3))
                    }
                    jobRow(for: jobId)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronTeal.opacity(0.08)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Job Row

    @ViewBuilder
    private func jobRow(for jobId: String) -> some View {
        let isProcess = jobId.hasPrefix("proc-")
        let status = jobStatus(for: jobId)
        let label = jobLabel(for: jobId)
        let tappable = canDrillDown(jobId: jobId)

        Button {
            handleJobTap(jobId: jobId, isProcess: isProcess)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isProcess ? "terminal" : "person.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(isProcess ? .tronEmerald : .tronIndigo)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    Text(truncateId(jobId))
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextDisabled)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 6) {
                    jobMetadata(for: jobId, isProcess: isProcess)
                    jobStatusIcon(status)
                }

                if tappable {
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
    }

    // MARK: - Job Status

    private enum JobStatus {
        case running, completed, failed, cancelled, unknown
    }

    private func jobStatus(for jobId: String) -> JobStatus {
        if jobId.hasPrefix("proc-") {
            if let process = viewModel.processState.processes[jobId] {
                switch process.status {
                case .running, .backgrounded, .cancelling: return .running
                case .completed: return .completed
                case .failed: return .failed
                case .cancelled: return .cancelled
                }
            }
        } else {
            if let agent = viewModel.subagentState.subagents[jobId] {
                switch agent.status {
                case .running: return .running
                case .completed: return .completed
                case .failed: return .failed
                }
            }
        }
        if data.status == .running { return .running }
        return parseStatusFromResult(jobId: jobId)
    }

    private func parseStatusFromResult(jobId: String) -> JobStatus {
        // Server emits a structured jobs array in tool.details. Read it
        // directly — zero text scanning.
        guard let jobs = data.details?.dictArray("jobs") else {
            return .unknown
        }
        for job in jobs where (job["id"] as? String) == jobId {
            switch job["status"] as? String {
            case "completed": return .completed
            case "failed": return .failed
            default: return .unknown
            }
        }
        return .unknown
    }

    private func jobLabel(for jobId: String) -> String {
        if jobId.hasPrefix("proc-") {
            if let process = viewModel.processState.processes[jobId] {
                return process.label.isEmpty ? "Process" : process.label
            }
            return "Process"
        } else {
            if let agent = viewModel.subagentState.subagents[jobId] {
                let task = agent.task
                return task.truncated(to: 53)
            }
            return "Sub-Agent"
        }
    }

    @ViewBuilder
    private func jobMetadata(for jobId: String, isProcess: Bool) -> some View {
        if isProcess {
            if let process = viewModel.processState.processes[jobId] {
                if let exitCode = process.exitCode, exitCode != 0 {
                    Text("exit \(exitCode)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronError)
                }
                if let ms = process.durationMs {
                    Text(formatDuration(ms))
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        } else {
            if let agent = viewModel.subagentState.subagents[jobId] {
                if agent.currentTurn > 0 {
                    Text("T\(agent.currentTurn)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                }
                if let ms = agent.duration {
                    Text(formatDuration(ms))
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
    }

    @ViewBuilder
    private func jobStatusIcon(_ status: JobStatus) -> some View {
        switch status {
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 16, height: 16)
                .tint(.tronTeal)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronSuccess)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronError)
        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
        }
    }

    // MARK: - Drill-Down

    private func canDrillDown(jobId: String) -> Bool {
        if jobId.hasPrefix("proc-") {
            return viewModel.processState.processes[jobId] != nil
        } else {
            return viewModel.subagentState.subagents[jobId] != nil
        }
    }

    private func handleJobTap(jobId: String, isProcess: Bool) {
        if isProcess {
            if let process = viewModel.processState.processes[jobId] {
                drillDownSheet = .process(toolCallId: process.toolCallId)
            }
        } else {
            if viewModel.subagentState.subagents[jobId] != nil {
                drillDownSheet = .agent(sessionId: jobId)
            }
        }
    }

    @ViewBuilder
    private func drillDownContent(for target: DrillDownTarget) -> some View {
        switch target {
        case .process(let toolCallId):
            processDrillDown(toolCallId: toolCallId)
        case .agent(let agentSessionId):
            agentDrillDown(sessionId: agentSessionId)
        }
    }

    @ViewBuilder
    private func processDrillDown(toolCallId: String) -> some View {
        let bashData: CommandToolChipData? = {
            if let index = MessageFinder.lastIndexOfToolUse(toolCallId: toolCallId, in: viewModel.messages),
               case .toolUse(let tool) = viewModel.messages[index].content {
                return CommandToolChipData(from: tool)
            }
            return nil
        }()

        if let bashData {
            BashToolDetailSheet(data: bashData, rpcClient: rpcClient, sessionId: sessionId)
        } else {
            ProcessJobFallbackSheet(toolCallId: toolCallId)
        }
    }

    @ViewBuilder
    private func agentDrillDown(sessionId agentSessionId: String) -> some View {
        if let agentData = viewModel.subagentState.subagents[agentSessionId] {
            SubagentDetailSheet(
                data: agentData,
                subagentState: viewModel.subagentState,
                eventStoreManager: dependencies.eventStoreManager,
                rpcClient: rpcClient
            )
            .adaptivePresentationDetents([.medium, .large])
        } else {
            EmptyView()
        }
    }

    // MARK: - Result Section

    private func resultSection(_ result: String) -> some View {
        ToolDetailSection(title: "Results", accent: .tronTeal, tint: tint) {
            Text(result)
                .font(TronTypography.codeContent)
                .foregroundStyle(tint.body)
                .textSelection(.enabled)
                .lineSpacing(3)
        }
    }

    // MARK: - Helpers

    private func truncateId(_ id: String) -> String {
        if id.count > 24 {
            return String(id.prefix(12)) + "..." + String(id.suffix(8))
        }
        return id
    }

    private func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}

// MARK: - Process Job Fallback Sheet

@available(iOS 26.0, *)
private struct ProcessJobFallbackSheet: View {
    let toolCallId: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Process",
            iconName: "terminal",
            accent: .tronEmerald
        ) {
            VStack(spacing: 16) {
                ToolEmptyState(
                    title: "Output",
                    icon: "doc.text.magnifyingglass",
                    message: "Process output not available",
                    accent: .tronEmerald,
                    tint: TintedColors(accent: .tronEmerald, colorScheme: colorScheme),
                    subtitle: "The original command data could not be found."
                )
            }
            .padding()
        }
    }
}
