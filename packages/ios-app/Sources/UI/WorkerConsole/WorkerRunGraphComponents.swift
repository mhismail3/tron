import SwiftUI

/// Pure presentation policy over the server-authored worker run graph.
///
/// Stage selection, node ordering, causal parents, timings, and timeline
/// summaries are protocol truth. This type only maps that truth to labels,
/// colors, and generic action availability.
enum WorkerRunGraphPresentation {
    static func isActive(status: String) -> Bool {
        let value = WorkerConsolePresentation.normalized(status)
        return value == "queued" || value == "running"
    }

    static func canDetach(status: String, mode: String) -> Bool {
        isActive(status: status)
            && WorkerConsolePresentation.normalized(mode) == "foreground"
    }

    static func canAwait(status: String, mode: String) -> Bool {
        isActive(status: status)
            && WorkerConsolePresentation.normalized(mode) == "background"
    }

    static func canCancel(status: String) -> Bool {
        isActive(status: status)
    }

    static func canRetry(status: String) -> Bool {
        WorkerConsolePresentation.normalized(status) == "failed"
    }

    static func canInspectResult(status: String) -> Bool {
        let value = WorkerConsolePresentation.normalized(status)
        return value == "completed" || value == "succeeded"
    }

    static func color(status: String) -> Color {
        switch WorkerConsolePresentation.normalized(status) {
        case "completed", "succeeded": .tronSuccess
        case "failed", "cancelled", "interrupted": .tronError
        case "running": .tronCyan
        default: .tronWarning
        }
    }

    static func symbol(status: String) -> String {
        switch WorkerConsolePresentation.normalized(status) {
        case "completed", "succeeded": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "cancelled", "interrupted": "stop.circle"
        case "running": "waveform.path.ecg"
        default: "clock"
        }
    }

    static func elapsed(_ milliseconds: UInt64) -> String {
        let seconds = Double(milliseconds) / 1_000
        if seconds < 1 {
            return "\(milliseconds) ms"
        }
        if seconds < 60 {
            return String(format: "%.1f sec", seconds)
        }
        let minutes = Int(seconds) / 60
        return "\(minutes)m \(Int(seconds) % 60)s"
    }

    static func depth(
        of node: WorkerRunNodeDTO,
        nodes: [WorkerRunNodeDTO]
    ) -> Int {
        var parents: [String: String?] = [:]
        for candidate in nodes {
            parents[candidate.id] = candidate.parentId
        }
        var current = node.parentId
        var visited = Set<String>()
        var depth = 0
        while let parent = current, visited.insert(parent).inserted, depth < 6 {
            depth += 1
            current = parents[parent] ?? nil
        }
        return depth
    }

    static func childSummary(_ counts: WorkerRunCountsDTO) -> String {
        var values: [String] = []
        if counts.running > 0 { values.append("\(counts.running) active") }
        if counts.queued > 0 { values.append("\(counts.queued) queued") }
        if counts.completed > 0 { values.append("\(counts.completed) completed") }
        if counts.failed > 0 { values.append("\(counts.failed) failed") }
        if counts.cancelled > 0 { values.append("\(counts.cancelled) cancelled") }
        return values.isEmpty ? "No child work recorded" : values.joined(separator: " · ")
    }
}

struct WorkerRunGraphSummaryView: View {
    let graph: WorkerRunGraphDTO

    private var color: Color {
        WorkerRunGraphPresentation.color(status: graph.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(graph.requestPreview)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 10) {
                Image(systemName: WorkerRunGraphPresentation.symbol(status: graph.status))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(graph.stageLabel)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(color)
                    Text(
                        "\(WorkerConsolePresentation.displayLabel(graph.status)) · "
                            + "\(WorkerConsolePresentation.displayLabel(graph.mode)) · "
                            + WorkerRunGraphPresentation.elapsed(graph.elapsedMs)
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                }
                Spacer(minLength: 0)
            }

            Text(WorkerRunGraphPresentation.childSummary(graph.counts))
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)

            if let expected = graph.expectedNextTransition, !expected.isEmpty {
                Label(expected, systemImage: "arrow.right.circle")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
        .accessibilityIdentifier("worker-run-summary")
    }
}

struct WorkerRunCausalTreeView: View {
    let graph: WorkerRunGraphDTO
    let openSession: (String) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(graph.nodes) { node in
                nodeRow(node)
                    .padding(.leading, CGFloat(WorkerRunGraphPresentation.depth(
                        of: node,
                        nodes: graph.nodes
                    )) * 14)
            }
        }
        .accessibilityIdentifier("worker-run-causal-tree")
    }

    private func nodeRow(_ node: WorkerRunNodeDTO) -> some View {
        let color = WorkerRunGraphPresentation.color(status: node.status)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: WorkerRunGraphPresentation.symbol(status: node.status))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.workerName ?? node.model ?? WorkerConsolePresentation.displayLabel(node.kind))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                HStack(spacing: 5) {
                    Text(WorkerConsolePresentation.displayLabel(node.status))
                    if let runner = node.runner {
                        Text("· \(WorkerConsolePresentation.displayLabel(runner))")
                    }
                    Text("· \(WorkerRunGraphPresentation.elapsed(node.elapsedMs))")
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)
                if let error = node.errorPreview, !error.isEmpty {
                    Text(error)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                        .lineLimit(3)
                } else if let result = node.resultPreview, !result.isEmpty {
                    Text(result)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let sessionId = node.sessionId, !sessionId.isEmpty {
                Button {
                    openSession(sessionId)
                } label: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.tronPurple)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open child session")
            }
        }
        .padding(10)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: false)
    }
}

struct WorkerRunTimelineView: View {
    let entries: [WorkerRunTimelineEntryDTO]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(WorkerRunGraphPresentation.color(status: entry.status))
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(WorkerConsolePresentation.displayLabel(entry.stage.rawValue))
                            if let timestamp = WorkerConsolePresentation.timestamp(entry.occurredAt) {
                                Text("· \(timestamp)")
                            }
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                    }
                }
            }
        }
        .accessibilityIdentifier("worker-run-structured-timeline")
    }
}

struct WorkerRunActionBar: View {
    let graph: WorkerRunGraphDTO
    let isMutating: Bool
    let detach: () -> Void
    let awaitResult: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let inspectResult: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if WorkerRunGraphPresentation.canDetach(status: graph.status, mode: graph.mode) {
                    action("Continue in background", symbol: "arrow.up.forward.circle", color: .tronCyan, detach)
                }
                if WorkerRunGraphPresentation.canAwait(status: graph.status, mode: graph.mode) {
                    action("Await", symbol: "hourglass", color: .tronPurple, awaitResult)
                }
                if WorkerRunGraphPresentation.canCancel(status: graph.status) {
                    action("Cancel", symbol: "stop.fill", color: .tronError, cancel)
                }
                if WorkerRunGraphPresentation.canRetry(status: graph.status) {
                    action("Retry", symbol: "arrow.clockwise", color: .tronWarning, retry)
                }
                if WorkerRunGraphPresentation.canInspectResult(status: graph.status) {
                    action("Inspect result", symbol: "doc.text.magnifyingglass", color: .tronSuccess, inspectResult)
                }
            }
        }
        .disabled(isMutating)
        .accessibilityIdentifier("worker-run-actions")
    }

    private func action(
        _ title: String,
        symbol: String,
        color: Color,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(color.opacity(0.16)).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
    }
}

/// Authoritative durable worker projection embedded in a chat tool sheet.
/// The model-tool association is persisted at admission, so this works before
/// a direct worker tool has produced a terminal result or background receipt.
struct WorkerToolRunGraphView: View {
    let invocationId: String?
    let modelToolInvocationId: String

    @Environment(\.dependencies) private var dependencies
    @State private var graph: WorkerRunGraphDTO?
    @State private var selectedSession: WorkerToolSessionSelection?
    @State private var isMutating = false
    @State private var error: String?
    @State private var confirmCancel = false
    @State private var refreshRevision = 0
    @State private var selectedResult: WorkerResultSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let graph {
                WorkerRunGraphSummaryView(graph: graph)

                WorkerConsoleSection(
                    title: "Run tree",
                    detail: "Live causal work ordered by the server.",
                    accent: .tronCyan
                ) {
                    WorkerRunCausalTreeView(graph: graph) { sessionId in
                        selectedSession = WorkerToolSessionSelection(sessionId: sessionId)
                    }
                }

                let visibleTimeline = graph.timeline.filter { !$0.technical }
                WorkerConsoleSection(
                    title: "Timeline",
                    detail: "Structured lifecycle transitions, not raw event identifiers.",
                    accent: .tronPurple
                ) {
                    if visibleTimeline.isEmpty {
                        Text("Waiting for the next durable transition.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    } else {
                        WorkerRunTimelineView(entries: visibleTimeline)
                    }
                }

                if let failure = graph.errorPreview, !failure.isEmpty {
                    WorkerConsoleSection(
                        title: "Action needed",
                        detail: "The durable invocation reported this failure.",
                        accent: .tronError
                    ) {
                        Text(failure)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronError)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let result = graph.resultPreview, !result.isEmpty {
                    WorkerConsoleSection(
                        title: "Result",
                        detail: "Concise schema-validated result.",
                        accent: .tronSuccess
                    ) {
                        Text(result)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                WorkerRunActionBar(
                    graph: graph,
                    isMutating: isMutating,
                    detach: { mutate(.detach) },
                    awaitResult: { mutate(.awaitResult) },
                    cancel: { confirmCancel = true },
                    retry: { mutate(.retry) },
                    inspectResult: {
                        selectedResult = WorkerResultSelection(
                            invocationId: graph.requestedInvocationId
                        )
                    }
                )
            } else if let error {
                WorkerConsoleErrorBanner(message: error)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading durable worker state…")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: false)
            }
        }
        .task(id: "\(invocationId ?? ""):\(modelToolInvocationId):\(refreshRevision)") {
            await observe()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workerRunProjectionInvalidated)) { _ in
            refreshRevision += 1
        }
        .sheet(item: $selectedSession) { selection in
            WorkerAuditSessionSheet(
                sessionId: selection.sessionId,
                title: "Worker Session"
            )
        }
        .sheet(item: $selectedResult) { selection in
            WorkerResultInspectorSheet(
                invocationId: selection.invocationId,
                repository: dependencies.workerKernelRepository
            )
        }
        .confirmationDialog(
            "Cancel this worker run?",
            isPresented: $confirmCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel run", role: .destructive) { mutate(.cancel) }
            Button("Keep running", role: .cancel) {}
        } message: {
            Text("Only this invocation and its causal descendants will stop.")
        }
        .accessibilityIdentifier("worker-tool-authoritative-graph")
    }

    private func observe() async {
        repeat {
            await refresh()
            guard !Task.isCancelled else {
                return
            }
            if let graph,
               !WorkerRunGraphPresentation.isActive(status: graph.status) {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        } while !Task.isCancelled
    }

    private func refresh() async {
        do {
            let page = try await dependencies.workerKernelRepository.workerRunGraph(
                invocationId: invocationId,
                modelToolInvocationId: invocationId == nil ? modelToolInvocationId : nil
            )
            graph = page.graphs?.first
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private enum Mutation {
        case detach
        case awaitResult
        case cancel
        case retry
    }

    private func mutate(_ mutation: Mutation) {
        guard !isMutating, let targetId = graph?.requestedInvocationId else { return }
        isMutating = true
        Task {
            defer { isMutating = false }
            do {
                switch mutation {
                case .detach:
                    _ = try await dependencies.workerKernelRepository.detachWorkerInvocation(
                        invocationId: targetId,
                        idempotencyKey: .userAction("detach-worker")
                    )
                case .awaitResult:
                    _ = try await dependencies.workerKernelRepository.awaitWorkerInvocation(
                        invocationId: targetId,
                        timeoutSeconds: 10
                    )
                case .cancel:
                    _ = try await dependencies.workerKernelRepository.cancelWorkerInvocation(
                        invocationId: targetId,
                        idempotencyKey: .userAction("cancel-worker")
                    )
                case .retry:
                    _ = try await dependencies.workerKernelRepository.retryWorkerInvocation(
                        invocationId: targetId,
                        idempotencyKey: .userAction("retry-worker")
                    )
                }
                error = nil
                await refresh()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct WorkerToolSessionSelection: Identifiable {
    let sessionId: String
    var id: String { sessionId }
}
