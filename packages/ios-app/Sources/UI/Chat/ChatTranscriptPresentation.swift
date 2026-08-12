import Foundation

/// Presentation-only filtering for Pi's canonical transcript. Configuration
/// entries before the first conversational entry describe session bootstrap
/// state and belong in Manage Session, not in the chat transcript. Later
/// configuration entries remain visible as compact change notifications.
struct ChatResponseState: Equatable {
    let sessionID: String
    let canonicalEntryCount: Int
    let tailEntryID: String?
    let streaming: TranscriptItem?
    let tools: [ToolExecutionState]

    init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        canonicalEntryCount = snapshot.transcriptTotal ?? snapshot.transcript.count
        tailEntryID = snapshot.transcript.last?.id
        streaming = snapshot.streaming
        tools = snapshot.toolExecutions
    }
}

struct ChatToolPresentation: Hashable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let content: String
    let error: Bool
    let structured: JSONValue?
}

struct ChatToolRunPresentation: Hashable, Identifiable {
    let tools: [ChatToolPresentation]
    var id: String { "tool-run-" + tools.map(\.id).joined(separator: "|") }
    var isRunning: Bool { tools.contains { $0.subtitle == "Running" || $0.subtitle == "Invocation" } }
    var failureCount: Int { tools.filter(\.error).count }
    var title: String { "\(isRunning ? "Using" : "Used") \(tools.count) \(tools.count == 1 ? "tool" : "tools")" }
    var status: String? {
        if failureCount > 0 { return "\(failureCount) failed" }
        return isRunning ? "in progress" : nil
    }
}

enum ChatTranscriptRenderItem: Hashable, Identifiable {
    case transcript(TranscriptItem)
    case toolRun(ChatToolRunPresentation)

    var id: String {
        switch self {
        case .transcript(let item): item.id
        case .toolRun(let run): run.id
        }
    }
}

enum ChatUnreadResponsePolicy {
    static func shouldMarkUnread(
        previous: ChatResponseState?,
        current: ChatResponseState,
        userScrolledAway: Bool
    ) -> Bool {
        guard let previous, previous.sessionID == current.sessionID else { return false }
        return previous != current && userScrolledAway
    }
}

enum ChatTranscriptPresentation {
    static func items(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        let visibleCallIDs = Set(snapshot.transcript.flatMap { item in
            (item.content ?? []).compactMap(\.toolCallId)
        })
        var conversationHasBegun = (snapshot.transcriptStart ?? 0) > 0

        return snapshot.transcript.filter { item in
            if item.kind == .message {
                conversationHasBegun = true
            }
            if item.kind == .modelChange || item.kind == .thinkingChange {
                return conversationHasBegun
            }
            if item.role == .toolResult, let callID = item.toolCallId {
                return !visibleCallIDs.contains(callID)
            }
            return true
        }
    }

    static func toolResults(in snapshot: SessionSnapshot) -> [String: TranscriptItem] {
        Dictionary(
            snapshot.transcript.compactMap { item in
                guard item.role == .toolResult, let callID = item.toolCallId else { return nil }
                return (callID, item)
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }

    /// Collapses consecutive tool-only transcript entries without mutating Pi's
    /// canonical transcript. Mixed assistant entries keep their text/thinking
    /// row and contribute their calls to the following compact tool run.
    static func renderItems(in snapshot: SessionSnapshot) -> [ChatTranscriptRenderItem] {
        let results = toolResults(in: snapshot)
        let liveCallIDs = Set(snapshot.toolExecutions.map(\.toolCallId))
        var rendered: [ChatTranscriptRenderItem] = []
        var pendingTools: [ChatToolPresentation] = []

        func flushTools() {
            guard !pendingTools.isEmpty else { return }
            rendered.append(.toolRun(ChatToolRunPresentation(tools: pendingTools)))
            pendingTools.removeAll(keepingCapacity: true)
        }

        for item in items(in: snapshot) {
            let tools = toolPresentations(in: item, results: results).filter { !liveCallIDs.contains($0.id) }
            if tools.isEmpty {
                flushTools()
                rendered.append(.transcript(item))
                continue
            }

            if hasNonToolPresentation(item) {
                flushTools()
                rendered.append(.transcript(item))
            }
            pendingTools.append(contentsOf: tools)
        }
        flushTools()
        return rendered
    }

    static func liveToolRun(in snapshot: SessionSnapshot) -> ChatToolRunPresentation? {
        let tools = snapshot.toolExecutions.map { tool in
            ChatToolPresentation(
                id: "live-\(tool.id)",
                title: tool.toolName,
                subtitle: liveToolSubtitle(tool.status),
                content: (tool.result ?? tool.partialResult ?? tool.arguments).prettyPrinted,
                error: tool.isError,
                structured: tool.result ?? tool.partialResult ?? tool.arguments
            )
        }
        return tools.isEmpty ? nil : ChatToolRunPresentation(tools: tools)
    }

    private static func liveToolSubtitle(_ status: ToolExecutionState.Status) -> String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private static func hasNonToolPresentation(_ item: TranscriptItem) -> Bool {
        guard item.kind == .message else {
            return item.kind != .bash && item.kind != .customMessage && item.kind != .customEntry
        }
        guard item.role != .toolResult else { return false }
        return item.content?.contains { part in
            switch part.type {
            case .toolCall: false
            case .text: !(part.text ?? "").isEmpty
            case .thinking, .image: true
            }
        } == true || !(item.errorMessage ?? "").isEmpty
    }

    private static func toolPresentations(
        in item: TranscriptItem,
        results: [String: TranscriptItem]
    ) -> [ChatToolPresentation] {
        switch item.kind {
        case .bash:
            return [ChatToolPresentation(
                id: item.id,
                title: "bash",
                subtitle: item.cancelled == true ? "Cancelled" : "Exit \(item.exitCode.map(String.init) ?? "—")",
                content: item.output ?? "",
                error: (item.exitCode ?? 0) != 0 || item.cancelled == true,
                structured: nil
            )]
        case .customMessage:
            return [ChatToolPresentation(
                id: item.id,
                title: item.customType ?? "Extension",
                subtitle: "Extension message",
                content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
                error: false,
                structured: item.details
            )]
        case .customEntry:
            return [ChatToolPresentation(
                id: item.id,
                title: item.customType ?? "Extension state",
                subtitle: "Extension state",
                content: item.customData?.prettyPrinted ?? "",
                error: false,
                structured: item.customData
            )]
        case .message where item.role == .toolResult:
            return [toolResultPresentation(item)]
        case .message:
            return (item.content ?? []).compactMap { part in
                guard part.type == .toolCall else { return nil }
                if let callID = part.toolCallId, let result = results[callID] {
                    return ChatToolPresentation(
                        id: part.toolCallId ?? part.id,
                        title: part.name ?? result.toolName ?? "Tool",
                        subtitle: result.isError == true ? "Failed" : "Completed",
                        content: result.text.isEmpty ? result.details?.prettyPrinted ?? "" : result.text,
                        error: result.isError == true,
                        structured: result.details
                    )
                }
                return ChatToolPresentation(
                    id: part.toolCallId ?? part.id,
                    title: part.name ?? "Tool",
                    subtitle: "Invocation",
                    content: part.arguments?.prettyPrinted ?? "",
                    error: false,
                    structured: part.arguments
                )
            }
        case .compaction, .branchSummary, .modelChange, .thinkingChange, .label:
            return []
        }
    }

    private static func toolResultPresentation(_ item: TranscriptItem) -> ChatToolPresentation {
        ChatToolPresentation(
            id: item.toolCallId ?? item.id,
            title: item.toolName ?? "Tool result",
            subtitle: item.isError == true ? "Failed" : "Completed",
            content: item.text.isEmpty ? item.details?.prettyPrinted ?? "" : item.text,
            error: item.isError == true,
            structured: item.details
        )
    }
}
