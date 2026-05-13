import Foundation

enum CodexAppHistoryWindow {
    static let initialEntryLimit = 80
    static let additionalEntryBatchSize = 60
    static let initialMessageLimit = initialEntryLimit
    static let additionalMessageBatchSize = additionalEntryBatchSize
    static let initialItemLimit = initialEntryLimit
    static let additionalItemBatchSize = additionalEntryBatchSize
}

struct CodexAppState: Equatable {
    var threads: [CodexThreadSummary] = []
    var selectedThreadId: String?
    var currentTurnId: String?
    var entries: [CodexTranscriptEntry] = []
    var earlierEntries: [CodexTranscriptEntry] = []
    var messages: [ChatMessage] = []
    var earlierMessages: [ChatMessage] = []
    var items: [CodexAppItem] = []
    var earlierItems: [CodexAppItem] = []
    var pendingApprovals: [CodexApprovalRequest] = []
    var latestPlan: String?
    var latestDiff: String?
    var isTurnRunning = false
    var isDraftingNewThread = false
    var errorMessage: String?

    var selectedThread: CodexThreadSummary? {
        guard let selectedThreadId else { return nil }
        return threads.first { $0.id == selectedThreadId }
    }

    var hasEarlierEntries: Bool {
        !earlierEntries.isEmpty
    }

    mutating func rebuildTranscriptCollections() {
        messages = entries.compactMap(\.message)
        earlierMessages = earlierEntries.compactMap(\.message)
        items = entries.compactMap(\.item)
        earlierItems = earlierEntries.compactMap(\.item)
    }

    fileprivate var streamingMessageIDs: [String: UUID] = [:]
}

enum CodexTranscriptEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case item(CodexAppItem)

    var id: String {
        switch self {
        case .message(let message):
            "message-\(message.id.uuidString)"
        case .item(let item):
            "item-\(item.id)"
        }
    }

    var message: ChatMessage? {
        switch self {
        case .message(let message): message
        case .item: nil
        }
    }

    var item: CodexAppItem? {
        switch self {
        case .message: nil
        case .item(let item): item
        }
    }
}

enum CodexAppItem: Identifiable, Equatable {
    case agentMessage(id: String, text: String)
    case reasoning(id: String, text: String, isStreaming: Bool)
    case command(id: String, command: String, cwd: String?, status: String, output: String?)
    case fileChange(id: String, status: String, summary: String?)
    case mcpTool(id: String, server: String?, tool: String?, status: String, detail: String?)
    case webSearch(id: String, query: String?, status: String)
    case plan(id: String, text: String)
    case diff(id: String, text: String)
    case other(id: String, title: String, detail: String?)

    var id: String {
        switch self {
        case .agentMessage(let id, _),
             .reasoning(let id, _, _),
             .command(let id, _, _, _, _),
             .fileChange(let id, _, _),
             .mcpTool(let id, _, _, _, _),
             .webSearch(let id, _, _),
             .plan(let id, _),
             .diff(let id, _),
             .other(let id, _, _):
            id
        }
    }
}

enum CodexAppReducerEvent: Equatable {
    case threadsLoaded([CodexThreadSummary])
    case threadStarted(CodexThreadSummary)
    case threadResumed(CodexThread)
    case threadArchived(String)
    case turnStarted(threadId: String, turnId: String)
    case turnCompleted(threadId: String, turnId: String?)
    case userMessage(threadId: String?, text: String)
    case agentMessageDelta(threadId: String, turnId: String, itemId: String, delta: String)
    case itemStarted(CodexAppItem)
    case itemCompleted(CodexAppItem)
    case commandOutputDelta(itemId: String, delta: String)
    case fileOutputDelta(itemId: String, delta: String)
    case planDelta(itemId: String, delta: String)
    case reasoningDelta(itemId: String, delta: String)
    case planUpdated(threadId: String?, turnId: String?, plan: String)
    case diffUpdated(threadId: String?, turnId: String?, diff: String)
    case approvalRequested(CodexApprovalRequest)
    case approvalResolved(requestId: CodexJSONRPCID)
    case failed(String)
    case unknownNotification(method: String)
}

@MainActor
enum CodexAppReducer {
    static func apply(_ event: CodexAppReducerEvent, to state: inout CodexAppState) {
        switch event {
        case .threadsLoaded(let threads):
            state.threads = threads.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
            if let selected = state.selectedThreadId,
               state.threads.contains(where: { $0.id == selected }) {
                return
            }
            state.selectedThreadId = nil

        case .threadStarted(let summary):
            upsertThread(summary, in: &state)
            state.selectedThreadId = summary.id
            state.isDraftingNewThread = false
            state.entries.removeAll()
            state.earlierEntries.removeAll()
            state.messages.removeAll()
            state.earlierMessages.removeAll()
            state.items.removeAll()
            state.earlierItems.removeAll()
            state.pendingApprovals.removeAll()

        case .threadResumed(let thread):
            let summary = thread.summary
            upsertThread(summary, in: &state)
            state.selectedThreadId = thread.id
            state.isDraftingNewThread = false
            applyLatestWindow(
                entries: transcriptEntries(from: thread),
                to: &state
            )
            state.pendingApprovals.removeAll()

        case .threadArchived(let id):
            state.threads.removeAll { $0.id == id }
            if state.selectedThreadId == id {
                state.selectedThreadId = nil
                state.isDraftingNewThread = false
                state.entries.removeAll()
                state.earlierEntries.removeAll()
                state.messages.removeAll()
                state.earlierMessages.removeAll()
                state.items.removeAll()
                state.earlierItems.removeAll()
            }

        case .turnStarted(let threadId, let turnId):
            state.selectedThreadId = threadId
            state.isDraftingNewThread = false
            state.currentTurnId = turnId
            state.isTurnRunning = true
            state.errorMessage = nil

        case .turnCompleted:
            state.currentTurnId = nil
            state.isTurnRunning = false
            for id in state.streamingMessageIDs.values {
                updateMessage(id: id, in: &state) { message in
                    message.isStreaming = false
                }
            }
            state.streamingMessageIDs.removeAll()

        case .userMessage(_, let text):
            appendMessage(ChatMessage(role: .user, content: .text(text)), to: &state)

        case .agentMessageDelta(_, _, let itemId, let delta):
            appendAssistantDelta(itemId: itemId, delta: delta, state: &state)

        case .itemStarted(let item):
            if case .agentMessage = item {
                return
            }
            upsertItem(item, in: &state)

        case .itemCompleted(let item):
            if case .agentMessage(let itemId, let text) = item {
                finalizeAssistantMessage(itemId: itemId, text: text, state: &state)
            } else {
                upsertItem(item, in: &state)
            }

        case .commandOutputDelta(let itemId, let delta):
            appendOutput(itemId: itemId, delta: delta, state: &state, kind: "Command")

        case .fileOutputDelta(let itemId, let delta):
            appendOutput(itemId: itemId, delta: delta, state: &state, kind: "File Change")

        case .planDelta(let itemId, let delta):
            appendPlanDelta(itemId: itemId, delta: delta, state: &state)

        case .reasoningDelta(let itemId, let delta):
            appendReasoningDelta(itemId: itemId, delta: delta, state: &state)

        case .planUpdated(_, _, let plan):
            state.latestPlan = plan
            upsertItem(.plan(id: "plan", text: plan), in: &state)

        case .diffUpdated(_, _, let diff):
            state.latestDiff = diff
            upsertItem(.diff(id: "diff", text: diff), in: &state)

        case .approvalRequested(let request):
            if !state.pendingApprovals.contains(where: { $0.requestId == request.requestId }) {
                state.pendingApprovals.append(request)
            }

        case .approvalResolved(let requestId):
            state.pendingApprovals.removeAll { $0.requestId == requestId }

        case .failed(let message):
            state.errorMessage = message
            state.isTurnRunning = false
            appendMessage(ChatMessage(role: .system, content: .error(message)), to: &state)

        case .unknownNotification:
            break
        }
    }

    static func event(from notification: CodexJSONRPCNotification) -> CodexAppReducerEvent {
        let params = notification.params ?? [:]
        switch notification.method {
        case "thread/started":
            guard let thread = decodeThread(from: params) else {
                return .unknownNotification(method: notification.method)
            }
            return .threadStarted(thread.summary)
        case "thread/archived":
            return .threadArchived(params.string("threadId") ?? (params.dict("thread")?["id"] as? String) ?? "")
        case "turn/started":
            return .turnStarted(
                threadId: params.string("threadId") ?? (params.dict("turn")?["threadId"] as? String) ?? "",
                turnId: (params.dict("turn")?["id"] as? String) ?? params.string("turnId") ?? ""
            )
        case "turn/completed":
            return .turnCompleted(
                threadId: params.string("threadId") ?? (params.dict("turn")?["threadId"] as? String) ?? "",
                turnId: params.string("turnId") ?? (params.dict("turn")?["id"] as? String)
            )
        case "item/started":
            guard let item = decodeAppItem(from: params) else {
                return .unknownNotification(method: notification.method)
            }
            return .itemStarted(item)
        case "item/completed":
            guard let item = decodeAppItem(from: params) else {
                return .unknownNotification(method: notification.method)
            }
            return .itemCompleted(item)
        case "item/agentMessage/delta":
            return .agentMessageDelta(
                threadId: params.string("threadId") ?? "",
                turnId: params.string("turnId") ?? "",
                itemId: params.string("itemId") ?? "",
                delta: params.string("delta") ?? ""
            )
        case "item/plan/delta":
            return .planDelta(
                itemId: params.string("itemId") ?? params.string("id") ?? "plan",
                delta: params.string("delta") ?? ""
            )
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            return .reasoningDelta(
                itemId: params.string("itemId") ?? params.string("id") ?? "reasoning",
                delta: params.string("delta") ?? params.string("text") ?? ""
            )
        case "item/reasoning/summaryPartAdded":
            return .reasoningDelta(
                itemId: params.string("itemId") ?? params.string("id") ?? "reasoning",
                delta: "\n"
            )
        case "item/commandExecution/outputDelta":
            return .commandOutputDelta(
                itemId: params.string("itemId") ?? "",
                delta: params.string("delta") ?? ""
            )
        case "item/fileChange/outputDelta":
            return .fileOutputDelta(
                itemId: params.string("itemId") ?? "",
                delta: params.string("delta") ?? ""
            )
        case "turn/plan/updated":
            return .planUpdated(
                threadId: params.string("threadId"),
                turnId: params.string("turnId"),
                plan: params.string("plan") ?? params.string("text") ?? ""
            )
        case "turn/diff/updated":
            return .diffUpdated(
                threadId: params.string("threadId"),
                turnId: params.string("turnId"),
                diff: params.string("diff") ?? params.string("text") ?? ""
            )
        case "serverRequest/resolved":
            guard let requestId = jsonRPCID(from: params, key: "requestId") else {
                return .unknownNotification(method: notification.method)
            }
            return .approvalResolved(requestId: requestId)
        case "error":
            return .failed(
                params.string("message")
                    ?? (params.dict("error")?["message"] as? String)
                    ?? "Codex App Server error"
            )
        default:
            return .unknownNotification(method: notification.method)
        }
    }

    static func approval(from request: CodexJSONRPCServerRequest) -> CodexApprovalRequest? {
        let params = request.params ?? [:]
        let kind: CodexApprovalKind
        switch request.method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            kind = .command
        case "item/fileChange/requestApproval", "applyPatchApproval":
            kind = .fileChange
        default:
            return nil
        }

        guard let threadId = params.string("threadId"),
              let turnId = params.string("turnId"),
              let itemId = params.string("itemId")
        else {
            return nil
        }

        return CodexApprovalRequest(
            requestId: request.id,
            kind: kind,
            threadId: threadId,
            turnId: turnId,
            itemId: itemId,
            reason: params.string("reason")
        )
    }

    private static func transcriptEntries(from thread: CodexThread) -> [CodexTranscriptEntry] {
        thread.turns?.flatMap { turn in
            turn.items?.compactMap(transcriptEntry(from:)) ?? []
        } ?? []
    }

    private static func transcriptEntry(from item: CodexThreadItem) -> CodexTranscriptEntry? {
        if let message = message(from: item) {
            return .message(message)
        }
        if let item = appItem(from: item) {
            return .item(item)
        }
        return nil
    }

    private static func message(from item: CodexThreadItem) -> ChatMessage? {
        switch item {
        case .userMessage(_, let content):
            return ChatMessage(role: .user, content: .text(content.compactMap(\.textValue).joined(separator: "\n")))
        case .agentMessage(_, let text):
            return ChatMessage(role: .assistant, content: .text(text))
        case .plan(_, let text):
            return text.isEmpty ? nil : ChatMessage(role: .assistant, content: .thinking(visible: text, isExpanded: false, isStreaming: false))
        case .reasoning(_, let summary, let content):
            let text = (summary + content).joined(separator: "\n")
            return text.isEmpty ? nil : ChatMessage(role: .assistant, content: .thinking(visible: text, isExpanded: false, isStreaming: false))
        default:
            return nil
        }
    }

    private static func appItem(from item: CodexThreadItem) -> CodexAppItem? {
        switch item {
        case .agentMessage(let id, let text):
            return .agentMessage(id: id, text: text)
        case .plan(let id, let text):
            return .plan(id: id, text: text)
        case .reasoning(let id, let summary, let content):
            return .reasoning(id: id, text: (summary + content).joined(separator: "\n"), isStreaming: false)
        case .commandExecution(let id, let command, let cwd, let status, let output, _):
            return .command(id: id, command: command, cwd: cwd, status: status, output: output)
        case .fileChange(let id, let status, let changes):
            return .fileChange(id: id, status: status, summary: changes?.joined(separator: "\n"))
        case .mcpCapabilityInvocation(let id, let server, let tool, let status, let error):
            return .mcpTool(id: id, server: server, tool: tool, status: status, detail: error)
        case .webSearch(let id, let query, let status):
            return .webSearch(id: id, query: query, status: status)
        case .other(let id, let type, let text):
            return .other(id: id, title: type, detail: text)
        case .userMessage:
            return nil
        }
    }

    private static func upsertThread(_ summary: CodexThreadSummary, in state: inout CodexAppState) {
        if let index = state.threads.firstIndex(where: { $0.id == summary.id }) {
            state.threads[index] = summary
        } else {
            state.threads.insert(summary, at: 0)
        }
    }

    private static func appendMessage(_ message: ChatMessage, to state: inout CodexAppState) {
        state.entries.append(.message(message))
        state.rebuildTranscriptCollections()
    }

    private static func updateMessage(id: UUID, in state: inout CodexAppState, update: (inout ChatMessage) -> Void) {
        if let index = state.entries.firstIndex(where: { $0.message?.id == id }),
           case .message(var message) = state.entries[index] {
            update(&message)
            state.entries[index] = .message(message)
            state.rebuildTranscriptCollections()
            return
        }

        if let index = state.earlierEntries.firstIndex(where: { $0.message?.id == id }),
           case .message(var message) = state.earlierEntries[index] {
            update(&message)
            state.earlierEntries[index] = .message(message)
            state.rebuildTranscriptCollections()
        }
    }

    private static func upsertItem(_ item: CodexAppItem, in state: inout CodexAppState) {
        if let index = state.entries.firstIndex(where: { $0.item?.id == item.id }) {
            state.entries[index] = .item(item)
        } else if let index = state.earlierEntries.firstIndex(where: { $0.item?.id == item.id }) {
            state.earlierEntries[index] = .item(item)
        } else {
            state.entries.append(.item(item))
        }
        state.rebuildTranscriptCollections()
    }

    private static func appendAssistantDelta(itemId: String, delta: String, state: inout CodexAppState) {
        let messageID: UUID
        if let existing = state.streamingMessageIDs[itemId] {
            messageID = existing
        } else {
            let message = ChatMessage(role: .assistant, content: .streaming(""), isStreaming: true)
            messageID = message.id
            state.streamingMessageIDs[itemId] = messageID
            appendMessage(message, to: &state)
        }

        updateMessage(id: messageID, in: &state) { message in
            let current = message.content.textContent
            message.content = .streaming(current + delta)
            message.isStreaming = true
            message.streamingVersion += 1
        }
    }

    private static func finalizeAssistantMessage(itemId: String, text: String, state: inout CodexAppState) {
        if let messageID = state.streamingMessageIDs[itemId] {
            updateMessage(id: messageID, in: &state) { message in
                message.content = .text(text)
                message.isStreaming = false
            }
            state.streamingMessageIDs.removeValue(forKey: itemId)
            return
        }
        appendMessage(ChatMessage(role: .assistant, content: .text(text)), to: &state)
    }

    private static func appendPlanDelta(itemId: String, delta: String, state: inout CodexAppState) {
        let current: String
        if let index = state.items.firstIndex(where: { $0.id == itemId }),
           case .plan(_, let text) = state.items[index] {
            current = text
        } else if let index = state.earlierItems.firstIndex(where: { $0.id == itemId }),
                  case .plan(_, let text) = state.earlierItems[index] {
            current = text
        } else {
            current = ""
        }
        let next = current + delta
        state.latestPlan = next
        upsertItem(.plan(id: itemId, text: next), in: &state)
    }

    private static func appendReasoningDelta(itemId: String, delta: String, state: inout CodexAppState) {
        let current: String
        if let index = state.items.firstIndex(where: { $0.id == itemId }),
           case .reasoning(_, let text, _) = state.items[index] {
            current = text
        } else if let index = state.earlierItems.firstIndex(where: { $0.id == itemId }),
                  case .reasoning(_, let text, _) = state.earlierItems[index] {
            current = text
        } else {
            current = ""
        }
        upsertItem(.reasoning(id: itemId, text: current + delta, isStreaming: true), in: &state)
    }

    private static func appendOutput(itemId: String, delta: String, state: inout CodexAppState, kind: String) {
        if let index = state.entries.firstIndex(where: { $0.item?.id == itemId }),
           let item = state.entries[index].item {
            state.entries[index] = .item(itemWithAppendedOutput(item, itemId: itemId, delta: delta, kind: kind))
        } else if let index = state.earlierEntries.firstIndex(where: { $0.item?.id == itemId }),
                  let item = state.earlierEntries[index].item {
            state.earlierEntries[index] = .item(itemWithAppendedOutput(item, itemId: itemId, delta: delta, kind: kind))
        } else {
            state.entries.append(.item(.other(id: itemId, title: kind, detail: delta)))
        }
        state.rebuildTranscriptCollections()
    }

    private static func itemWithAppendedOutput(_ item: CodexAppItem, itemId: String, delta: String, kind: String) -> CodexAppItem {
        switch item {
        case .command(let id, let command, let cwd, let status, let output):
            .command(id: id, command: command, cwd: cwd, status: status, output: (output ?? "") + delta)
        case .fileChange(let id, let status, let summary):
            .fileChange(id: id, status: status, summary: (summary ?? "") + delta)
        case .other(let id, let title, let detail):
            .other(id: id, title: title, detail: (detail ?? "") + delta)
        default:
            .other(id: itemId, title: kind, detail: delta)
        }
    }

    private static func applyLatestWindow(
        entries allEntries: [CodexTranscriptEntry],
        to state: inout CodexAppState
    ) {
        let split = splitLatest(
            allEntries,
            visibleLimit: CodexAppHistoryWindow.initialEntryLimit
        )
        state.earlierEntries = split.earlier
        state.entries = split.visible
        state.rebuildTranscriptCollections()
    }

    private static func splitLatest<Element>(
        _ values: [Element],
        visibleLimit: Int
    ) -> (earlier: [Element], visible: [Element]) {
        guard values.count > visibleLimit else {
            return ([], values)
        }
        return (
            Array(values.prefix(values.count - visibleLimit)),
            Array(values.suffix(visibleLimit))
        )
    }

    private static func decodeAppItem(from params: [String: AnyCodable]) -> CodexAppItem? {
        guard let item = decodeThreadItem(from: params) else { return nil }
        return appItem(from: item)
    }

    private static func decodeThreadItem(from params: [String: AnyCodable]) -> CodexThreadItem? {
        let rawItem: [String: Any]
        if let item = params.dict("item") {
            rawItem = item
        } else {
            rawItem = params.mapValues(\.value)
        }
        guard JSONSerialization.isValidJSONObject(rawItem),
              let data = try? JSONSerialization.data(withJSONObject: rawItem)
        else {
            return nil
        }
        return try? JSONDecoder().decode(CodexThreadItem.self, from: data)
    }

    private static func decodeThread(from params: [String: AnyCodable]) -> CodexThread? {
        guard let rawThread = params.dict("thread"),
              JSONSerialization.isValidJSONObject(rawThread),
              let data = try? JSONSerialization.data(withJSONObject: rawThread)
        else {
            return nil
        }
        return try? JSONDecoder().decode(CodexThread.self, from: data)
    }

    private static func jsonRPCID(from params: [String: AnyCodable], key: String) -> CodexJSONRPCID? {
        guard let value = params[key]?.value else { return nil }
        if let int = value as? Int {
            return .int(int)
        }
        if let double = value as? Double,
           let int = Int(exactly: double.rounded(.towardZero)) {
            return .int(int)
        }
        if let string = value as? String {
            return .string(string)
        }
        return nil
    }
}
