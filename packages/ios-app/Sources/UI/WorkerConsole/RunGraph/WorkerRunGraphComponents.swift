import Foundation
import SwiftUI

struct WorkerRunResultPresentation: Equatable, Sendable {
    let status: String?
    let summary: String
}

/// Pure presentation policy over the server-authored worker run graph.
///
/// Stage selection, node ordering, causal parents, timings, and timeline
/// summaries are protocol truth. This type only maps that truth to labels,
/// colors, and generic action availability.
enum WorkerRunGraphPresentation {
    static func runTitle(workerName: String?, workerId: String) -> String {
        if let workerName = workerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workerName.isEmpty {
            return workerName
        }
        return WorkerConsolePresentation.displayLabel(workerId)
    }

    static func requestSummary(_ preview: String) -> String {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Worker request" }
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return WorkerConsolePresentation.compactText(trimmed, maxLength: 420)
        }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let fields = object as? [String: Any] {
            for key in ["question", "query", "request", "prompt", "task", "topic", "title", "action"] {
                if let value = fields[key] as? String, !value.isEmpty {
                    return WorkerConsolePresentation.compactText(value, maxLength: 420)
                }
            }
        }

        for key in ["question", "query", "request", "prompt", "task", "topic", "title", "action"] {
            if let value = stringField(key, in: trimmed), !value.isEmpty {
                return WorkerConsolePresentation.compactText(value, maxLength: 420)
            }
        }
        return "Structured worker request"
    }

    static func resultPresentation(_ preview: String) -> WorkerRunResultPresentation {
        let components = preview.components(separatedBy: " · ")
        guard components.count >= 3,
              components[0].contains("."),
              isResultStatus(components[1]) else {
            return WorkerRunResultPresentation(
                status: nil,
                summary: WorkerConsolePresentation.compactText(preview, maxLength: 640)
            )
        }
        return WorkerRunResultPresentation(
            status: WorkerConsolePresentation.displayLabel(components[1]),
            summary: WorkerConsolePresentation.compactText(
                components.dropFirst(2).joined(separator: " · "),
                maxLength: 640
            )
        )
    }

    static func workBreakdown(_ graph: WorkerRunGraphDTO) -> String {
        let workers = graph.nodes.filter { $0.kind == "invocation" }.count
        let attempts = graph.nodes.filter { $0.kind == "attempt" }.count
        let modelTurns = graph.nodes.filter { $0.kind == "model" }.count
        var values = ["\(workers) work item\(workers == 1 ? "" : "s")"]
        if attempts > 0 {
            values.append("\(attempts) attempt\(attempts == 1 ? "" : "s")")
        }
        if modelTurns > 0 {
            values.append("\(modelTurns) model turn\(modelTurns == 1 ? "" : "s")")
        }
        return values.joined(separator: " · ")
    }

    static func activitySummary(_ entries: [WorkerRunTimelineEntryDTO]) -> String {
        guard let latest = entries.last else { return "Waiting for the first durable update" }
        return "\(entries.count) update\(entries.count == 1 ? "" : "s") · \(latest.summary)"
    }

    static func transcriptCount(_ graph: WorkerRunGraphDTO) -> Int {
        Set(graph.nodes.compactMap { node in
            node.sessionId?.isEmpty == false ? node.sessionId : nil
        }).count
    }

    /// One transcript belongs to one agent session even though the server
    /// projects that session onto its invocation, agent, and model-turn nodes.
    /// The invocation node is the clearest owner because it names the worker
    /// whose agent performed the work.
    static func transcriptOwnerNodeIds(_ nodes: [WorkerRunNodeDTO]) -> Set<String> {
        var owners: [String: (rank: Int, index: Int, nodeId: String)] = [:]
        for (index, node) in nodes.enumerated() {
            guard let sessionId = node.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sessionId.isEmpty else { continue }
            let rank: Int = switch node.kind {
            case "invocation": 0
            case "agent": 1
            default: 2
            }
            if let owner = owners[sessionId],
               (owner.rank, owner.index) <= (rank, index) {
                continue
            }
            owners[sessionId] = (rank, index, node.id)
        }
        return Set(owners.values.map(\.nodeId))
    }

    static func stageLabel(status: String) -> String {
        switch WorkerConsolePresentation.normalized(status) {
        case "completed", "succeeded": "Worker execution completed"
        case "failed": "Worker execution failed"
        case "cancelled", "interrupted": "Worker execution stopped"
        case "running": "Worker execution in progress"
        default: "Worker execution queued"
        }
    }

    static func visibleTimeline(_ graph: WorkerRunGraphDTO) -> [WorkerRunTimelineEntryDTO] {
        graph.timeline.filter { !$0.technical }
    }

    static func nodeTitle(_ node: WorkerRunNodeDTO) -> String {
        if node.kind == "attempt", let attempt = node.attemptNumber {
            return "Attempt \(attempt)"
        }
        if node.kind == "model", let turn = node.turn {
            let model = node.model.map { " · \($0)" } ?? ""
            return "Model turn \(turn)\(model)"
        }
        return node.workerName
            ?? node.model
            ?? WorkerConsolePresentation.displayLabel(node.kind)
    }

    static func isActive(status: String) -> Bool {
        let value = WorkerConsolePresentation.normalized(status)
        return value == "queued" || value == "running"
    }

    /// A missing graph still needs its first authoritative read. Once a graph
    /// reaches a terminal state, unrelated worker invalidations must not
    /// restart its detail query.
    static func shouldRefreshAfterInvalidation(status: String?) -> Bool {
        status.map(isActive(status:)) ?? true
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
        if counts.completed > 0 { values.append("\(counts.completed) complete") }
        if counts.failed > 0 { values.append("\(counts.failed) failed") }
        if counts.cancelled > 0 { values.append("\(counts.cancelled) cancelled") }
        let total = counts.running + counts.queued + counts.completed + counts.failed + counts.cancelled
        return values.isEmpty
            ? "No child work recorded"
            : values.joined(separator: " · ") + " work item\(total == 1 ? "" : "s")"
    }

    private static func isResultStatus(_ value: String) -> Bool {
        switch WorkerConsolePresentation.normalized(value) {
        case "complete", "completed", "partial", "validationfailed", "failed", "cancelled":
            true
        default:
            false
        }
    }

    private static func stringField(_ key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\""),
              let colon = text.range(
                  of: ":",
                  range: keyRange.upperBound..<text.endIndex
              ),
              let openingQuote = text.range(
                  of: "\"",
                  range: colon.upperBound..<text.endIndex
              ) else {
            return nil
        }

        var result = ""
        var escaped = false
        for character in text[openingQuote.upperBound...] {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stable first-paint summary sourced from the invocation already selected in
/// the activity list. Loading the richer graph must not replace this layout.
struct WorkerRunInvocationSummaryView: View {
    let run: WorkerInvocationDTO

    private var color: Color {
        WorkerRunGraphPresentation.color(status: run.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("REQUESTED WORK")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text(WorkerConsolePresentation.runSummary(run) ?? "Structured worker request")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WorkerMetadataDivider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: WorkerRunGraphPresentation.symbol(status: run.status))
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(color)
                    .frame(width: 22)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(WorkerRunGraphPresentation.stageLabel(status: run.status))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(color)
                    Text("\(WorkerConsolePresentation.runInteractionMode(run)) run")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    Text(WorkerConsolePresentation.runAttemptLabel(run))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    if let model = run.effectiveModel ?? run.requestedModel {
                        Text(
                            [model, run.effectiveReasoningLevel ?? run.requestedReasoningLevel]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        )
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(color, cornerRadius: 12, subtle: true, interactive: false)
        .accessibilityIdentifier("worker-run-summary")
    }
}

/// Stable terminal-result preview. Full field hydration is deferred until the
/// user explicitly opens the bounded result inspector.
struct WorkerRunInvocationResultView: View {
    let run: WorkerInvocationDTO
    let inspectResult: () -> Void

    var body: some View {
        if let error = run.error?.trimmingCharacters(in: .whitespacesAndNewlines),
           !error.isEmpty {
            WorkerConsoleSection(
                title: "Action needed",
                detail: "The durable invocation reported this terminal failure.",
                accent: .tronError
            ) {
                Text(error)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if WorkerRunGraphPresentation.canInspectResult(status: run.status) {
            WorkerConsoleSection(
                title: "Result",
                detail: "Validated durable output from this worker run.",
                accent: .tronSuccess
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(WorkerConsolePresentation.runResultSummary(run) ?? "Validated worker result")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)
                    WorkerMetadataDivider()
                    WorkerRunDisclosureRow(
                        title: "View complete result",
                        detail: "Browse every field and nested value on demand.",
                        symbol: "doc.text.magnifyingglass",
                        accent: .tronSuccess,
                        action: inspectResult
                    )
                }
            }
            .accessibilityIdentifier("worker-run-result-summary")
        }
    }
}

struct WorkerRunInvocationExecutionOverviewView: View {
    let isReady: Bool
    let openDetails: () -> Void

    var body: some View {
        WorkerConsoleSection(
            title: "Execution trace",
            detail: "Ordered worker, attempt, model, and durable activity evidence.",
            accent: .tronCyan
        ) {
            WorkerRunDisclosureRow(
                title: "Inspect execution trace",
                detail: isReady
                    ? "Expand work steps and open each distinct agent transcript in context."
                    : "Preparing the bounded execution trace…",
                symbol: "point.3.connected.trianglepath.dotted",
                accent: .tronCyan,
                isEnabled: isReady,
                action: openDetails
            )
        }
        .accessibilityIdentifier("worker-run-execution-overview")
    }
}

struct WorkerRunGraphSummaryView: View {
    let graph: WorkerRunGraphDTO

    private var color: Color {
        WorkerRunGraphPresentation.color(status: graph.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("REQUESTED WORK")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                Text(WorkerRunGraphPresentation.requestSummary(graph.requestPreview))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WorkerMetadataDivider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: WorkerRunGraphPresentation.symbol(status: graph.status))
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(color)
                    .frame(width: 22)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(graph.stageLabel)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(color)
                    Text(
                        "\(WorkerConsolePresentation.displayLabel(graph.mode)) run · "
                            + WorkerRunGraphPresentation.elapsed(graph.elapsedMs)
                    )
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    Text(WorkerRunGraphPresentation.childSummary(graph.counts))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                    if let effectiveModel = graph.effectiveModel {
                        Text(
                            [effectiveModel, graph.effectiveReasoningLevel]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        )
                        .font(TronTypography.code(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                    }
                }
                Spacer(minLength: 0)
            }

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

struct WorkerRunDisclosureRow: View {
    let title: String
    let detail: String
    let symbol: String
    let accent: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: symbol)
                    .foregroundStyle(accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.62)
    }
}

struct WorkerRunExecutionOverviewView: View {
    let graph: WorkerRunGraphDTO
    let openDetails: () -> Void

    private var visibleTimeline: [WorkerRunTimelineEntryDTO] {
        WorkerRunGraphPresentation.visibleTimeline(graph)
    }

    var body: some View {
        WorkerConsoleSection(
            title: "Execution trace",
            detail: WorkerRunGraphPresentation.workBreakdown(graph),
            accent: .tronCyan
        ) {
            WorkerRunDisclosureRow(
                title: "Inspect execution trace",
                detail: executionDetail,
                symbol: "point.3.connected.trianglepath.dotted",
                accent: .tronCyan,
                action: openDetails
            )
        }
        .accessibilityIdentifier("worker-run-execution-overview")
    }

    private var executionDetail: String {
        let transcripts = WorkerRunGraphPresentation.transcriptCount(graph)
        if transcripts > 0 {
            return "\(transcripts) distinct agent transcript\(transcripts == 1 ? "" : "s") · \(WorkerRunGraphPresentation.activitySummary(visibleTimeline))"
        }
        return WorkerRunGraphPresentation.activitySummary(visibleTimeline)
    }
}

struct WorkerRunTerminalResultView: View {
    let graph: WorkerRunGraphDTO
    let inspectResult: () -> Void

    var body: some View {
        if let failure = graph.errorPreview, !failure.isEmpty {
            WorkerConsoleSection(
                title: "Action needed",
                detail: "The durable invocation reported this terminal failure.",
                accent: .tronError
            ) {
                Text(failure)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if graph.resultPreview?.isEmpty == false
                    || WorkerRunGraphPresentation.canInspectResult(status: graph.status) {
            let preview = graph.resultPreview ?? "Validated worker result"
            WorkerConsoleSection(
                title: "Result",
                detail: "Validated durable output from this worker run.",
                accent: .tronSuccess
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(WorkerRunGraphPresentation.resultPresentation(preview).summary)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)

                    if WorkerRunGraphPresentation.canInspectResult(status: graph.status) {
                        WorkerMetadataDivider()
                        WorkerRunDisclosureRow(
                            title: "View complete result",
                            detail: "Browse every field and nested value on demand.",
                            symbol: "doc.text.magnifyingglass",
                            accent: .tronSuccess,
                            action: inspectResult
                        )
                    }
                }
            }
            .accessibilityIdentifier("worker-run-result-summary")
        }
    }
}

struct WorkerRunExecutionSheet: View {
    let graph: WorkerRunGraphDTO

    @State private var selectedSession: WorkerToolSessionSelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    WorkerConsoleSectionHeader(
                        title: "Execution trace",
                        detail: traceDetail(graph)
                    )
                    WorkerRunExecutionTraceView(graph: graph) { node, sessionId in
                        selectedSession = WorkerToolSessionSelection(
                            sessionId: sessionId,
                            title: "\(WorkerRunGraphPresentation.nodeTitle(node)) Transcript"
                        )
                    }
                    if graph.truncated {
                        WorkerConsoleInlineEmptyState(
                            symbol: "ellipsis.circle",
                            text: "This trace is bounded to the execution history retained by the server."
                        )
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Execution Trace", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
            .sheet(item: $selectedSession) { selection in
                WorkerAuditSessionSheet(
                    sessionId: selection.sessionId,
                    title: selection.title
                )
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronCyan)
    }

    private func traceDetail(_ graph: WorkerRunGraphDTO) -> String {
        let entries = WorkerRunGraphPresentation.visibleTimeline(graph)
        let transcripts = WorkerRunGraphPresentation.transcriptCount(graph)
        return [
            WorkerRunGraphPresentation.workBreakdown(graph),
            "\(entries.count) durable update\(entries.count == 1 ? "" : "s")",
            "\(transcripts) agent transcript\(transcripts == 1 ? "" : "s")",
        ].joined(separator: " · ")
    }
}

struct WorkerRunExecutionTraceView: View {
    let graph: WorkerRunGraphDTO
    let openSession: (WorkerRunNodeDTO, String) -> Void

    @State private var expandedNodeIds = Set<String>()

    private var transcriptOwnerNodeIds: Set<String> {
        WorkerRunGraphPresentation.transcriptOwnerNodeIds(graph.nodes)
    }

    private var entriesByNode: [String: [WorkerRunTimelineEntryDTO]] {
        Dictionary(
            grouping: WorkerRunGraphPresentation.visibleTimeline(graph),
            by: \.nodeId
        )
    }

    private var orphanEntries: [WorkerRunTimelineEntryDTO] {
        let nodeIds = Set(graph.nodes.map(\.id))
        return WorkerRunGraphPresentation.visibleTimeline(graph).filter {
            !nodeIds.contains($0.nodeId)
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(graph.nodes) { node in
                WorkerRunTraceNodeView(
                    node: node,
                    entries: entriesByNode[node.id] ?? [],
                    ownsTranscript: transcriptOwnerNodeIds.contains(node.id),
                    isExpanded: expandedNodeIds.contains(node.id),
                    toggle: { toggle(node.id) },
                    openSession: { sessionId in openSession(node, sessionId) }
                )
                    .padding(.leading, CGFloat(WorkerRunGraphPresentation.depth(
                        of: node,
                        nodes: graph.nodes
                    )) * 14)
            }
            if !orphanEntries.isEmpty {
                WorkerConsoleSection(
                    title: "Additional durable updates",
                    detail: "Updates retained without a projected work node.",
                    accent: .tronSlate
                ) {
                    WorkerRunTimelineView(
                        entries: orphanEntries,
                        nodes: graph.nodes,
                        showsNodeTitle: true
                    )
                }
            }
        }
        .accessibilityIdentifier("worker-run-execution-trace")
    }

    private func toggle(_ nodeId: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if expandedNodeIds.contains(nodeId) {
                expandedNodeIds.remove(nodeId)
            } else {
                expandedNodeIds.insert(nodeId)
            }
        }
    }
}

private struct WorkerRunTraceNodeView: View {
    let node: WorkerRunNodeDTO
    let entries: [WorkerRunTimelineEntryDTO]
    let ownsTranscript: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    let openSession: (String) -> Void

    private var color: Color {
        WorkerRunGraphPresentation.color(status: node.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: WorkerRunGraphPresentation.symbol(status: node.status))
                        .foregroundStyle(color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(WorkerRunGraphPresentation.nodeTitle(node))
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
                        if let preview = collapsedPreview {
                            Text(preview)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(node.errorPreview == nil ? .tronTextMuted : .tronError)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                WorkerMetadataDivider()
                    .padding(.vertical, 9)
                VStack(alignment: .leading, spacing: 10) {
                    if !entries.isEmpty {
                        WorkerRunTimelineView(
                            entries: entries,
                            nodes: [node],
                            showsNodeTitle: false
                        )
                    } else {
                        Text("No additional durable updates were recorded for this step.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    if ownsTranscript,
                       let sessionId = node.sessionId,
                       !sessionId.isEmpty {
                        WorkerMetadataDivider()
                        WorkerRunDisclosureRow(
                            title: "Open agent transcript",
                            detail: "View this worker's prompts, responses, reasoning, and tool calls.",
                            symbol: "text.bubble",
                            accent: .tronPurple
                        ) {
                            openSession(sessionId)
                        }
                    }
                }
            }
        }
        .padding(10)
        .sectionFill(color, cornerRadius: 10, subtle: true, interactive: true)
        .accessibilityLabel("\(WorkerRunGraphPresentation.nodeTitle(node)), \(WorkerConsolePresentation.displayLabel(node.status))")
    }

    private var collapsedPreview: String? {
        if let error = node.errorPreview, !error.isEmpty {
            return error
        }
        if let result = node.resultPreview, !result.isEmpty {
            return WorkerRunGraphPresentation.resultPresentation(result).summary
        }
        return entries.last?.summary
    }
}

struct WorkerRunTimelineView: View {
    let entries: [WorkerRunTimelineEntryDTO]
    let nodes: [WorkerRunNodeDTO]
    var showsNodeTitle = true

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(WorkerRunGraphPresentation.color(status: entry.status))
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        if showsNodeTitle,
                           let node = nodes.first(where: { $0.id == entry.nodeId }) {
                            Text(WorkerRunGraphPresentation.nodeTitle(node).uppercased())
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeSM,
                                    weight: .semibold
                                ))
                                .foregroundStyle(.tronTextMuted)
                        }
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

private struct WorkerToolSessionSelection: Identifiable {
    let sessionId: String
    let title: String
    var id: String { sessionId }
}

/*
 The execution trace intentionally owns the only transcript affordance for a
 session. Invocation, agent, and model nodes can share one session identifier;
 presenting each as a separate chat link would duplicate the same transcript.
 */
