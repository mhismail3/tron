import Foundation

struct CapabilityInvocationGroupData: Equatable, Identifiable {
    let id: String
    var invocations: [CapabilityInvocationData]

    init(invocations: [CapabilityInvocationData]) {
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

    var displayStatus: CapabilityInvocationStatus {
        if isActive { return .running }
        if failedCount > 0 { return .error }
        return .success
    }

    var title: String {
        "\(isActive ? "Using" : "Used") \(count) \(count == 1 ? "capability" : "capabilities")"
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

struct CapabilityInvocationRenderGroup: Equatable, Identifiable {
    let id: String
    var messages: [ChatMessage]

    init(messages: [ChatMessage]) {
        self.messages = messages
        self.id = "capability-group-\(messages.first?.id.uuidString ?? UUID().uuidString)"
    }

    var invocations: [CapabilityInvocationData] {
        messages.compactMap { message in
            if case .capabilityInvocation(let invocation) = message.content {
                return invocation
            }
            return nil
        }
    }

    var data: CapabilityInvocationGroupData {
        CapabilityInvocationGroupData(invocations: invocations)
    }
}

enum ChatMessageRenderItem: Equatable, Identifiable {
    case message(ChatMessage)
    case capabilityGroup(CapabilityInvocationRenderGroup)

    var id: String {
        switch self {
        case .message(let message):
            return message.id.uuidString
        case .capabilityGroup(let group):
            return group.id
        }
    }
}

enum CapabilityInvocationGrouping {
    static func renderItems(from messages: [ChatMessage]) -> [ChatMessageRenderItem] {
        var items: [ChatMessageRenderItem] = []
        var pendingCapabilityMessages: [ChatMessage] = []

        func flushPending() {
            guard !pendingCapabilityMessages.isEmpty else { return }
            if pendingCapabilityMessages.count == 1, let message = pendingCapabilityMessages.first {
                items.append(.message(message))
            } else {
                items.append(.capabilityGroup(CapabilityInvocationRenderGroup(messages: pendingCapabilityMessages)))
            }
            pendingCapabilityMessages.removeAll(keepingCapacity: true)
        }

        for message in messages {
            if case .capabilityInvocation = message.content {
                pendingCapabilityMessages.append(message)
            } else {
                flushPending()
                items.append(.message(message))
            }
        }

        flushPending()
        return items
    }
}
