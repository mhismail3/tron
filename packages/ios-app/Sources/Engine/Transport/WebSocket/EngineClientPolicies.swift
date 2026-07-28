import Foundation

// MARK: - Engine Client Errors

enum EngineClientError: Error, LocalizedError {
    case noActiveSession
    case invalidURL
    case connectionNotEstablished

    var errorDescription: String? {
        switch self {
        case .noActiveSession: return "No active session"
        case .invalidURL: return "Invalid server URL"
        case .connectionNotEstablished: return "Connection not established"
        }
    }
}

enum EngineClientConnectionPolicy {
    static func shouldSkipConnect(state: ConnectionState) -> Bool {
        switch state {
        case .connected, .connecting, .reconnecting, .deployRestarting:
            return true
        case .disconnected, .failed, .unauthorized:
            return false
        }
    }

    static func shouldDiscardExistingTransport(hasTransport: Bool, state: ConnectionState) -> Bool {
        hasTransport && !shouldSkipConnect(state: state)
    }
}

enum EngineClientStreamSubscriptionPolicy {
    static let workerProjectionTopics = [
        "worker.lifecycle",
        "worker.invocations",
    ]

    static func shouldClearSubscriptions(previous: ConnectionState, next: ConnectionState) -> Bool {
        previous.isConnected && !next.isConnected
    }

    static func shouldResubscribe(
        previous: ConnectionState,
        next: ConnectionState,
        hasCurrentSession: Bool
    ) -> Bool {
        !previous.isConnected && next.isConnected && hasCurrentSession
    }

    static func isWorkerProjectionTopic(_ topic: String?) -> Bool {
        guard let topic else { return false }
        return workerProjectionTopics.contains(topic)
    }

    static func isWorkerLifecycleTopic(_ topic: String?) -> Bool {
        topic == "worker.lifecycle"
    }
}

struct EngineStreamSubscriptionKey: Hashable {
    let topic: String
    let sessionId: String?
    let workspaceId: String?
}

enum EngineSessionSubscriptionInterest: Hashable {
    case presentation
    case processing
}

/// Coalesces connection-local stream acknowledgements per subscription.
struct EngineStreamAckCoalescer {
    private var latestBySubscription: [String: EngineStreamCursor] = [:]
    private var scheduledSubscriptions: Set<String> = []

    mutating func record(subscriptionId: String, cursor: EngineStreamCursor) -> Bool {
        if let existing = latestBySubscription[subscriptionId] {
            latestBySubscription[subscriptionId] = max(existing, cursor)
        } else {
            latestBySubscription[subscriptionId] = cursor
        }
        return scheduledSubscriptions.insert(subscriptionId).inserted
    }

    mutating func takeForFlush(subscriptionId: String) -> EngineStreamCursor? {
        latestBySubscription.removeValue(forKey: subscriptionId)
    }

    mutating func completeFlush(subscriptionId: String) -> Bool {
        scheduledSubscriptions.remove(subscriptionId)
        return latestBySubscription[subscriptionId] != nil
    }

    mutating func remove(subscriptionId: String) {
        latestBySubscription.removeValue(forKey: subscriptionId)
        scheduledSubscriptions.remove(subscriptionId)
    }

    mutating func removeAll() {
        latestBySubscription.removeAll()
        scheduledSubscriptions.removeAll()
    }
}

// MARK: - Engine Client
