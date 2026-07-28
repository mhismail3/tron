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
    }
}

struct WorkerRunDetailLinksView: View {
    let graph: WorkerRunGraphDTO
    let openTree: () -> Void
    let openTimeline: () -> Void

    private var visibleTimeline: [WorkerRunTimelineEntryDTO] {
        graph.timeline.filter { !$0.technical }
    }

    var body: some View {
        WorkerConsoleSection(
            title: "Execution details",
            detail: "Open the durable work structure or activity only when you need it.",
            accent: .tronCyan
        ) {
            VStack(spacing: 0) {
                WorkerRunDisclosureRow(
                    title: "Work breakdown",
                    detail: WorkerRunGraphPresentation.workBreakdown(graph),
                    symbol: "point.3.connected.trianglepath.dotted",
                    accent: .tronCyan,
                    action: openTree
                )
                WorkerMetadataDivider()
                WorkerRunDisclosureRow(
                    title: "Activity",
                    detail: WorkerRunGraphPresentation.activitySummary(visibleTimeline),
                    symbol: "clock.arrow.circlepath",
                    accent: .tronPurple,
                    action: openTimeline
                )
            }
        }
        .accessibilityIdentifier("worker-run-detail-links")
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
        } else if let preview = graph.resultPreview, !preview.isEmpty {
            let result = WorkerRunGraphPresentation.resultPresentation(preview)
            WorkerConsoleSection(
                title: result.status.map { "\($0) result" } ?? "Result",
                detail: "Readable summary from the validated durable result.",
                accent: .tronSuccess
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(result.summary)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(10)
                        .fixedSize(horizontal: false, vertical: true)

                    if WorkerRunGraphPresentation.canInspectResult(status: graph.status) {
                        WorkerMetadataDivider()
                        WorkerRunDisclosureRow(
                            title: "Open full result",
                            detail: "Browse fields on demand from the durable invocation.",
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

struct WorkerRunTreeSheet: View {
    let graph: WorkerRunGraphDTO

    @State private var selectedSession: WorkerToolSessionSelection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(WorkerRunGraphPresentation.workBreakdown(graph))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    WorkerRunCausalTreeView(graph: graph) { sessionId in
                        selectedSession = WorkerToolSessionSelection(sessionId: sessionId)
                    }
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Work Breakdown", color: .tronCyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronCyan)
                }
            }
            .sheet(item: $selectedSession) { selection in
                WorkerAuditSessionSheet(
                    sessionId: selection.sessionId,
                    title: "Worker Session"
                )
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronCyan)
    }
}

struct WorkerRunTimelineSheet: View {
    let graph: WorkerRunGraphDTO

    private var entries: [WorkerRunTimelineEntryDTO] {
        graph.timeline.filter { !$0.technical }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if entries.isEmpty {
                    Text("No user-facing activity has been recorded yet.")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                } else {
                    WorkerRunTimelineView(entries: entries, nodes: graph.nodes)
                        .padding(18)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Activity", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronPurple)
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
                if let error = node.errorPreview, !error.isEmpty {
                    Text(error)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronError)
                        .lineLimit(3)
                } else if let result = node.resultPreview, !result.isEmpty {
                    Text(WorkerRunGraphPresentation.resultPresentation(result).summary)
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
    let nodes: [WorkerRunNodeDTO]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(WorkerRunGraphPresentation.color(status: entry.status))
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        if let node = nodes.first(where: { $0.id == entry.nodeId }) {
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
    var id: String { sessionId }
}
