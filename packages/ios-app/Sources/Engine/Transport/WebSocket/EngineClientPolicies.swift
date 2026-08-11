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
        case .connected, .connecting, .reconnecting, .deployRestarting, .unauthorized:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    static func shouldDiscardExistingTransport(hasTransport: Bool, state: ConnectionState) -> Bool {
        hasTransport && !shouldSkipConnect(state: state)
    }

    static func shouldOwnAutomaticRecovery(
        attemptedLiveSession: Bool,
        isInBackground: Bool,
        state: ConnectionState
    ) -> Bool {
        attemptedLiveSession
            && !isInBackground
            && !state.isConnected
            && !state.requiresUserAction
    }
}

enum EngineClientStreamSubscriptionPolicy {
    static let workerProjectionTopics = [
        "worker.lifecycle",
        "worker.invocations",
        "worker.role_review",
    ]

    static func shouldClearSubscriptions(
        previous: ConnectionState,
        next: ConnectionState,
        transportChanged: Bool = false
    ) -> Bool {
        (previous.isConnected && !next.isConnected)
            || (next.isConnected && transportChanged)
    }

    static func shouldResubscribe(
        previous: ConnectionState,
        next: ConnectionState,
        hasCurrentSession: Bool,
        transportChanged: Bool = false
    ) -> Bool {
        next.isConnected
            && hasCurrentSession
            && (!previous.isConnected || transportChanged)
    }

    static func isWorkerProjectionTopic(_ topic: String?) -> Bool {
        guard let topic else { return false }
        return workerProjectionTopics.contains(topic)
    }

    static func isWorkerLifecycleTopic(_ topic: String?) -> Bool {
        topic == "worker.lifecycle" || topic == "worker.role_review"
    }
}

/// App-local invalidation metadata for canonical worker projection reads.
///
/// Stream events are hints only. Consumers use these identifiers to avoid
/// refreshing unrelated sessions, then re-read durable server state.
struct WorkerProjectionInvalidation: Equatable, Sendable {
    let affectedSessionIds: Set<String>
    let includesUnscopedInvocations: Bool
    let lifecycleChanged: Bool

    func affectsSession(_ sessionId: String) -> Bool {
        affectedSessionIds.contains(sessionId)
    }

    static func affectsSession(notificationObject: Any?, sessionId: String) -> Bool {
        guard let invalidation = notificationObject as? WorkerProjectionInvalidation else {
            // App-local legacy/test notifications without typed metadata are
            // intentionally treated as global invalidations.
            return true
        }
        return invalidation.affectsSession(sessionId)
    }
}

struct WorkerProjectionInvalidationAccumulator: Equatable, Sendable {
    private(set) var affectedSessionIds: Set<String> = []
    private(set) var includesUnscopedInvocations = false
    private(set) var lifecycleChanged = false

    var isEmpty: Bool {
        affectedSessionIds.isEmpty
            && !includesUnscopedInvocations
            && !lifecycleChanged
    }

    mutating func record(topic: String?, sessionId: String?) {
        if EngineClientStreamSubscriptionPolicy.isWorkerLifecycleTopic(topic) {
            lifecycleChanged = true
        } else if let sessionId, !sessionId.isEmpty {
            affectedSessionIds.insert(sessionId)
        } else {
            includesUnscopedInvocations = true
        }
    }

    mutating func take() -> WorkerProjectionInvalidation {
        let invalidation = WorkerProjectionInvalidation(
            affectedSessionIds: affectedSessionIds,
            includesUnscopedInvocations: includesUnscopedInvocations,
            lifecycleChanged: lifecycleChanged
        )
        self = WorkerProjectionInvalidationAccumulator()
        return invalidation
    }
}

/// App-local hint that a canonical agent relationship/detail projection may
/// have changed. The event payload is never treated as UI state.
struct AgentCoordinationProjectionInvalidation: Equatable, Sendable {
    let affectedSessionIds: Set<String>
    let includesUnscopedChanges: Bool

    func affectsSession(_ sessionId: String) -> Bool {
        includesUnscopedChanges || affectedSessionIds.contains(sessionId)
    }

    static func affectsSession(notificationObject: Any?, sessionId: String) -> Bool {
        guard let invalidation = notificationObject as? AgentCoordinationProjectionInvalidation else {
            return true
        }
        return invalidation.affectsSession(sessionId)
    }
}

struct AgentCoordinationInvalidationAccumulator: Equatable, Sendable {
    private(set) var affectedSessionIds: Set<String> = []
    private(set) var includesUnscopedChanges = false

    mutating func record(sessionId: String?) {
        if let sessionId, !sessionId.isEmpty {
            affectedSessionIds.insert(sessionId)
        } else {
            includesUnscopedChanges = true
        }
    }

    mutating func take() -> AgentCoordinationProjectionInvalidation {
        let result = AgentCoordinationProjectionInvalidation(
            affectedSessionIds: affectedSessionIds,
            includesUnscopedChanges: includesUnscopedChanges
        )
        self = AgentCoordinationInvalidationAccumulator()
        return result
    }
}

extension Notification.Name {
    /// Coalesced invalidation for agent relationships, assignments, messages,
    /// results, and management-action availability.
    static let agentCoordinationProjectionInvalidated = Notification.Name(
        "tron.agent-coordination-projection-invalidated"
    )
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
