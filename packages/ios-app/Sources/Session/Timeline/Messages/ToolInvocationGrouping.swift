import Foundation

struct ToolInvocationGroupData: Equatable, Identifiable {
    let id: String
    var invocations: [ToolInvocationData]

    init(invocations: [ToolInvocationData]) {
        self.invocations = invocations
        self.id = invocations.map(\.id).joined(separator: "|")
    }

    var count: Int { invocations.count }

    var runningCount: Int {
        invocations.filter { $0.status == .running || $0.status == .generating }.count
    }

    var failedCount: Int {
        invocations.filter { $0.status == .error || $0.status == .unavailable }.count
    }

    var completedCount: Int {
        invocations.count - runningCount
    }

    var isActive: Bool {
        runningCount > 0
    }

    var displayStatus: ToolInvocationStatus {
        if isActive { return .running }
        if failedCount > 0 { return .error }
        return .success
    }

    var title: String {
        "\(isActive ? "Using" : "Used") \(count) \(count == 1 ? "tool" : "tools")"
    }

    var inlineStatusText: String? {
        if isActive {
            return "\(completedCount)/\(count) done"
        }
        if failedCount > 0 {
            return "\(failedCount) failed"
        }
        return nil
    }
}

struct ToolInvocationRenderGroup: Equatable, Identifiable {
    let id: String
    var messages: [ChatMessage]

    init(messages: [ChatMessage]) {
        self.messages = messages
        self.id = "tool-group-\(messages.first?.id.uuidString ?? UUID().uuidString)"
    }

    var invocations: [ToolInvocationData] {
        messages.compactMap { message in
            if case .toolInvocation(let invocation) = message.content {
                return invocation
            }
            return nil
        }
    }

    var data: ToolInvocationGroupData {
        ToolInvocationGroupData(invocations: invocations)
    }
}

enum ChatMessageRenderItem: Equatable, Identifiable {
    case message(ChatMessage)
    case toolGroup(ToolInvocationRenderGroup)

    var id: String {
        switch self {
        case .message(let message):
            return message.id.uuidString
        case .toolGroup(let group):
            return group.id
        }
    }
}

enum ToolInvocationGrouping {
    static func renderItems(from messages: [ChatMessage]) -> [ChatMessageRenderItem] {
        var items: [ChatMessageRenderItem] = []
        var pendingToolMessages: [ChatMessage] = []

        func flushPending() {
            guard !pendingToolMessages.isEmpty else { return }
            if pendingToolMessages.count == 1, let message = pendingToolMessages.first {
                items.append(.message(message))
            } else {
                items.append(.toolGroup(ToolInvocationRenderGroup(messages: pendingToolMessages)))
            }
            pendingToolMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if case .toolInvocation = message.content {
                pendingToolMessages.append(message)
            } else {
                flushPending()
                items.append(.message(message))
            }
        }

        flushPending()
        return items
    }
}
