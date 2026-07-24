import SwiftUI

enum SessionContextPressure: Equatable {
    case normal
    case elevated
    case critical

    var color: Color {
        switch self {
        case .normal: .tronEmerald
        case .elevated: .tronAmber
        case .critical: .tronError
        }
    }
}

/// Pure presentation and action policy for the Session Context surface.
enum SessionContextPresentation {
    /// Completed cards separate clearly from the next section, while each
    /// heading remains visually attached to the content it introduces.
    static let sectionSpacing: CGFloat = 20
    static let headerToContentSpacing: CGFloat = 4
    static let headerToSubheaderSpacing: CGFloat = 0

    static func boundedPercentage(_ percentage: Int) -> Int {
        min(max(percentage, 0), 100)
    }

    static func progressFraction(_ percentage: Int) -> Double {
        Double(boundedPercentage(percentage)) / 100
    }

    static func pressure(for percentage: Int) -> SessionContextPressure {
        switch boundedPercentage(percentage) {
        case 95...: .critical
        case 80...: .elevated
        default: .normal
        }
    }

    static func canMutate(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool,
        isBusy: Bool
    ) -> Bool {
        isConnected && !isAgentActive && !isCompacting && !isBusy
    }

    static func mutationUnavailableReason(
        isConnected: Bool,
        isAgentActive: Bool,
        isCompacting: Bool
    ) -> String? {
        if !isConnected { return "Reconnect to change the model or fork this session." }
        if isCompacting { return "Wait for context compaction to finish." }
        if isAgentActive { return "Wait for the current response to finish." }
        return nil
    }

    static func hasSessionUsage(inputTokens: Int, outputTokens: Int, cost: Double) -> Bool {
        inputTokens > 0 || outputTokens > 0 || cost > 0
    }

    static func remainingContextText(currentContextWindow: Int, tokensRemaining: Int) -> String {
        guard currentContextWindow > 0 else { return "Window loading" }
        return "\(TokenFormatter.format(tokensRemaining, style: .withSuffix)) left"
    }

    static func causalGroups(_ runs: [WorkerInvocationDTO]) -> [SessionWorkerRunGroup] {
        let byParent = Dictionary(grouping: runs.compactMap { run -> (String, WorkerInvocationDTO)? in
            run.parentWorkerInvocationId.map { ($0, run) }
        }, by: \.0)
        let known = Set(runs.map(\.invocationId))
        let roots = runs.filter {
            $0.parentWorkerInvocationId == nil
                || !known.contains($0.parentWorkerInvocationId ?? "")
        }

        func descendants(of invocationId: String) -> [WorkerInvocationDTO] {
            (byParent[invocationId] ?? []).flatMap { pair in
                [pair.1] + descendants(of: pair.1.invocationId)
            }
        }

        return roots.map {
            SessionWorkerRunGroup(root: $0, descendants: descendants(of: $0.invocationId))
        }
    }

    static func runState(_ run: WorkerInvocationDTO) -> String {
        if run.detachedAt != nil,
           run.status == "queued" || run.status == "running" {
            return "Detached"
        }
        return WorkerConsolePresentation.displayLabel(run.status)
    }
}

struct SessionWorkerRunGroup: Identifiable, Equatable {
    let root: WorkerInvocationDTO
    let descendants: [WorkerInvocationDTO]

    var id: String { root.invocationId }
}

/// Session-scoped context telemetry, worker activity, and controls backed only
/// by durable engine truth: token records, originating-session worker runs, the
/// model catalog/switch operation, automatic compaction state, and forking.
struct SessionContextSheet: View {
    let sessionId: String
    let contextState: ContextTrackingState
    let currentModelId: String
    let currentModelInfo: ModelInfo?
    let reasoningLevel: String?
    let isConnected: Bool
    let isAgentActive: Bool
    let isCompacting: Bool
    let isFork: Bool
    let modelRepository: any ModelRepository
    let workerRepository: any WorkerKernelRepository
    let onSelectModel: (ModelInfo) -> Void
    let onFork: () async throws -> String

    @Environment(\.dismiss) private var dismiss
    @State private var availableModels: [ModelInfo] = []
    @State private var isLoadingModels = false
    @State private var isForking = false
    @State private var showModelPicker = false
    @State private var showForkConfirmation = false
    @State private var sessionWorkerRuns: [WorkerInvocationDTO] = []
    @State private var workerNames: [String: String] = [:]
    @State private var workerRunsNextOffset: UInt64?
    @State private var isLoadingWorkerRuns = false
    @State private var workerLoadError: String?
    @State private var selectedWorkerRun: WorkerInvocationDTO?
    @State private var errorMessage: String?
    @State private var workerRefreshRevision = 0

    private var percentage: Int { contextState.contextPercentage }
    private var accent: Color { SessionContextPresentation.pressure(for: percentage).color }
    private var totalSessionInputTokens: Int {
        contextState.accumulatedInputTokens + contextState.accumulatedCacheReadTokens
    }
    private var canMutate: Bool {
        SessionContextPresentation.canMutate(
            isConnected: isConnected,
            isAgentActive: isAgentActive,
            isCompacting: isCompacting,
            isBusy: isForking
        )
    }
    private var currentModelDisplayName: String {
        currentModelInfo?.formattedModelName ?? currentModelId.shortModelName
    }
    private var workerRunGroups: [SessionWorkerRunGroup] {
        SessionContextPresentation.causalGroups(sessionWorkerRuns)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: SessionContextPresentation.sectionSpacing) {
                    sessionSummary
                    modelSection
                    workerActivitySection
                    sessionActionsSection

                    if let reason = SessionContextPresentation.mutationUnavailableReason(
                        isConnected: isConnected,
                        isAgentActive: isAgentActive,
                        isCompacting: isCompacting
                    ) {
                        Text(reason)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Session Context", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task { await loadModels() }
        .task(id: "\(sessionId):\(isConnected):\(isAgentActive):\(workerRefreshRevision)") {
            await observeSessionWorkers()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
            workerRefreshRevision += 1
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                models: availableModels,
                currentModelId: currentModelId,
                readOnly: !canMutate,
                reasoningLevel: currentModelInfo?.supportsReasoning == true ? reasoningLevel : nil,
                onSelect: onSelectModel
            )
        }
        .sheet(isPresented: $showForkConfirmation) {
            ForkSessionConfirmationSheet(isFork: isFork) {
                Task { await forkSession() }
            }
        }
        .sheet(item: $selectedWorkerRun) { run in
            WorkerRunDetailSheet(
                run: run,
                workerName: workerNames[run.workerId]
            )
        }
        .tronErrorAlert(message: $errorMessage)
    }

    private var sessionSummary: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                contextGauge

                VStack(alignment: .leading, spacing: 4) {
                    Text(SessionContextPresentation.remainingContextText(
                        currentContextWindow: contextState.currentContextWindow,
                        tokensRemaining: contextState.tokensRemaining
                    ))
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text("\(TokenFormatter.format(contextState.contextWindowTokens, style: .withSuffix)) used · \(contextWindowDescription)")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }

            if SessionContextPresentation.hasSessionUsage(
                inputTokens: totalSessionInputTokens,
                outputTokens: contextState.accumulatedOutputTokens,
                cost: contextState.accumulatedCost
            ) {
                Divider().opacity(0.35)

                usageMetrics
            }

            Divider().opacity(0.35)

            HStack(spacing: 8) {
                Image(systemName: isCompacting ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
                    .accessibilityHidden(true)
                Text("Automatic compaction")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                Spacer()
                Text(isCompacting ? "Running" : "On")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(isCompacting ? accent : .tronEmerald)
            }
        }
        .padding(14)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var contextGauge: some View {
        ZStack {
            Circle()
                .stroke(Color.tronTextMuted.opacity(0.2), lineWidth: 7)
            Circle()
                .trim(from: 0, to: SessionContextPresentation.progressFraction(percentage))
                .stroke(accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percentage)%")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context used")
        .accessibilityValue("\(percentage) percent")
    }

    private var contextWindowDescription: String {
        guard contextState.currentContextWindow > 0 else {
            return "Waiting for the model context-window limit"
        }
        return "\(TokenFormatter.format(contextState.currentContextWindow, style: .withSuffix)) window"
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Model",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                showModelPicker = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronPurple)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentModelDisplayName)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)

                        Text(currentModelInfo?.formattedContextWindow ?? "Current session model")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    if isLoadingModels {
                        ProgressView().controlSize(.small).tint(.tronPurple)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: canMutate)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canMutate || availableModels.isEmpty)
            .accessibilityIdentifier("session-context-model-picker")
        }
    }

    private var usageMetrics: some View {
        HStack(spacing: 0) {
            metric(label: "Input", value: TokenFormatter.format(totalSessionInputTokens))
            Divider().frame(height: 32)
            metric(label: "Output", value: TokenFormatter.format(contextState.accumulatedOutputTokens))
            Divider().frame(height: 32)
            metric(label: "Cost", value: formatCost(contextState.accumulatedCost))
        }
    }

    private func metric(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var workerActivitySection: some View {
        VStack(alignment: .leading, spacing: SessionContextPresentation.headerToContentSpacing) {
            VStack(alignment: .leading, spacing: SessionContextPresentation.headerToSubheaderSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Workers in this session")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    if isLoadingWorkerRuns, sessionWorkerRuns.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.tronCyan)
                    } else if !workerRunGroups.isEmpty {
                        Text("\(workerRunGroups.count) roots · \(sessionWorkerRuns.count) runs")
                            .font(TronTypography.pillValue)
                            .foregroundStyle(.tronCyan)
                    }
                }

                Text("Runs started here, including nested work from the same causal trace.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let workerLoadError {
                Text(workerLoadError)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronError)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronError, cornerRadius: 10, subtle: true, interactive: false)
            } else if sessionWorkerRuns.isEmpty, !isLoadingWorkerRuns {
                Label("No workers have run in this session.", systemImage: "bolt.horizontal.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: false)
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(workerRunGroups) { group in
                        SessionWorkerRunRow(
                            run: group.root,
                            workerName: workerNames[group.root.workerId]
                                ?? WorkerConsolePresentation.displayLabel(group.root.workerId)
                        ) {
                            selectedWorkerRun = group.root
                        }
                        ForEach(group.descendants) { child in
                            SessionWorkerRunRow(
                                run: child,
                                workerName: workerNames[child.workerId]
                                    ?? WorkerConsolePresentation.displayLabel(child.workerId)
                            ) {
                                selectedWorkerRun = child
                            }
                            .padding(.leading, 18)
                        }
                    }
                }
            }

            if workerRunsNextOffset != nil, !isLoadingWorkerRuns {
                Button {
                    Task { await loadSessionWorkerRuns(reset: false) }
                } label: {
                    Label("Load older worker runs", systemImage: "clock.arrow.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .sectionFill(.tronCyan, cornerRadius: 10, subtle: true, interactive: true)
            }
        }
    }

    private var sessionActionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                title: "Session",
                bottomPadding: SessionContextPresentation.headerToContentSpacing
            )

            Button {
                showForkConfirmation = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isFork ? "Fork again from here" : "Fork from current point")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Create a new branch without changing this session")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }

                    Spacer()

                    if isForking {
                        ProgressView().controlSize(.small).tint(.tronEmerald)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: canMutate)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(!canMutate)
            .accessibilityIdentifier("session-context-fork")
        }
    }

    private func loadModels() async {
        availableModels = modelRepository.cachedModels
        guard availableModels.isEmpty, isConnected else { return }

        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await modelRepository.list(forceRefresh: false)
        } catch {
            errorMessage = "Could not load models: \(error.localizedDescription)"
        }
    }

    private func observeSessionWorkers() async {
        await loadSessionWorkerRuns(reset: true)
        while !Task.isCancelled,
              isAgentActive || sessionWorkerRuns.contains(where: { $0.status == "queued" || $0.status == "running" }) {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await loadSessionWorkerRuns(reset: true)
        }
    }

    private func loadSessionWorkerRuns(reset: Bool) async {
        guard !isLoadingWorkerRuns else { return }
        isLoadingWorkerRuns = true
        defer { isLoadingWorkerRuns = false }
        do {
            if workerNames.isEmpty {
                let workers = try await workerRepository.workers(includeRetired: true).workers
                workerNames = Dictionary(uniqueKeysWithValues: workers.map { ($0.workerId, $0.name) })
            }
            let page = try await workerRepository.workerRunGraphs(
                originSessionId: sessionId,
                limit: 10,
                offset: reset ? nil : workerRunsNextOffset
            )
            if reset {
                sessionWorkerRuns = page.runs
            } else {
                var identifiers = Set(sessionWorkerRuns.map(\.invocationId))
                sessionWorkerRuns.append(contentsOf: page.runs.filter {
                    identifiers.insert($0.invocationId).inserted
                })
            }
            workerRunsNextOffset = page.nextOffset
            workerLoadError = nil
        } catch {
            workerLoadError = "Worker activity could not load: \(error.localizedDescription)"
        }
    }

    private func forkSession() async {
        guard canMutate else { return }
        isForking = true
        defer { isForking = false }
        do {
            let newSessionId = try await onFork()
            dismiss()
            await Task.yield()
            NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
        } catch {
            errorMessage = "Could not fork session: \(error.localizedDescription)"
        }
    }
}

private struct SessionWorkerRunRow: View {
    let run: WorkerInvocationDTO
    let workerName: String
    let action: () -> Void

    private var color: Color {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    private var symbol: String {
        switch WorkerConsolePresentation.normalized(run.status) {
        case "completed", "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled": "stop.circle"
        case "running": "waveform.path.ecg"
        default: "clock"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbol)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workerName)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)
                    Text(WorkerConsolePresentation.runSummary(run)
                        ?? WorkerConsolePresentation.displayLabel(run.triggerKind))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(SessionContextPresentation.runState(run))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(color)
                    if let timestamp = WorkerConsolePresentation.timestamp(
                        run.completedAt ?? run.startedAt ?? run.createdAt
                    ) {
                        Text(timestamp)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .sectionFill(color, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
    }
}

private struct ForkSessionConfirmationSheet: View {
    let isFork: Bool
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: 34, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 62, height: 62)
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.14)), in: .circle)

                VStack(spacing: 5) {
                    Text(isFork ? "Fork again from here?" : "Fork from this point?")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text("A new session branch is created. This session remains unchanged.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .glassEffect(.regular, in: .capsule)

                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        Label("Create fork", systemImage: "arrow.triangle.branch")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.24)), in: .capsule)
                }
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            }
            .padding(20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Fork Session", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents(
            [.medium],
            ipadSizing: .compactForm,
            phoneSizing: .unchanged
        )
        .tint(.tronEmerald)
    }
}
