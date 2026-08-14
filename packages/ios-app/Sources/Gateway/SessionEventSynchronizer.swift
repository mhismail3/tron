import Foundation

/// Owns one authoritative synchronization attempt per session, including its
/// intent, shared outcome, and quarantined event suffix. This replaces token
/// polling and keeps synchronization state from leaking across AppModel fields.
@MainActor
final class SessionSynchronizationCoordinator {
    enum Intent: Equatable, Sendable {
        case presentation(generation: Int)
        case reconnect(presentationGeneration: Int)
    }

    enum Role: Equatable, Sendable {
        case leader
        case join
        case retryAfterCurrent
    }

    typealias Cursor = GatewayEventCursor

    enum EventAdmission: Equatable, Sendable {
        case deliver(GatewayEvent)
        case buffered
        case overflow(String)
    }

    @MainActor
    final class SharedOutcome: @unchecked Sendable {
        private var outcome: Bool?
        private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

        func value() async -> Bool {
            if let outcome { return outcome }
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let outcome {
                        continuation.resume(returning: outcome)
                    } else {
                        waiters[waiterID] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelWaiter(waiterID)
                }
            }
        }

        fileprivate func resolve(_ value: Bool) {
            guard outcome == nil else { return }
            outcome = value
            let pending = waiters.values
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: value) }
        }

        private func cancelWaiter(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume(returning: false)
        }
    }

    struct Lease {
        let sessionID: String
        let intent: Intent
        let role: Role
        fileprivate let token: UUID
        fileprivate let outcome: SharedOutcome

        func sharedValue() async -> Bool { await outcome.value() }
    }

    private struct Synchronization {
        let token: UUID
        let intent: Intent
        let outcome: SharedOutcome
        var events: [GatewayEvent] = []
        var overflowed = false
        var requiresRetry = false
    }

    private let maximumBufferedEvents: Int
    private var synchronizations: [String: Synchronization] = [:]
    private var freshInstallSessionIDs = Set<String>()

    init(maximumBufferedEvents: Int = 1_024) {
        self.maximumBufferedEvents = maximumBufferedEvents
    }

    func acquire(sessionID: String, intent: Intent) -> Lease {
        if let existing = synchronizations[sessionID] {
            return Lease(
                sessionID: sessionID,
                intent: intent,
                role: existing.intent == intent ? .join : .retryAfterCurrent,
                token: existing.token,
                outcome: existing.outcome
            )
        }
        let token = UUID()
        let outcome = SharedOutcome()
        synchronizations[sessionID] = Synchronization(
            token: token,
            intent: intent,
            outcome: outcome
        )
        return Lease(
            sessionID: sessionID,
            intent: intent,
            role: .leader,
            token: token,
            outcome: outcome
        )
    }

    func owns(_ lease: Lease) -> Bool {
        synchronizations[lease.sessionID]?.token == lease.token
    }

    func intent(sessionID: String) -> Intent? {
        synchronizations[sessionID]?.intent
    }

    func admit(_ event: GatewayEvent) -> EventAdmission {
        guard let sessionID = event.sessionId,
              var synchronization = synchronizations[sessionID] else {
            return .deliver(event)
        }
        if synchronization.events.count >= maximumBufferedEvents {
            synchronization.events.removeAll(keepingCapacity: false)
            synchronization.overflowed = true
            synchronizations[sessionID] = synchronization
            return .overflow(sessionID)
        }
        if !synchronization.overflowed { synchronization.events.append(event) }
        synchronizations[sessionID] = synchronization
        return .buffered
    }

    func drainBufferedEvents(for lease: Lease, baseline: Cursor?) -> [GatewayEvent]? {
        guard var synchronization = synchronizations[lease.sessionID],
              synchronization.token == lease.token else { return nil }
        guard !synchronization.overflowed else { return nil }
        let events = synchronization.events
        synchronization.events.removeAll(keepingCapacity: true)
        synchronizations[lease.sessionID] = synchronization
        guard let baseline else { return events }
        return events.filter { event in
            guard let cursor = Self.cursor(for: event) else { return true }
            if cursor.runtimeGeneration != baseline.runtimeGeneration { return true }
            return cursor.eventSequence > baseline.eventSequence
        }
    }

    func markRetryRequired(sessionID: String) -> Bool {
        guard var synchronization = synchronizations[sessionID] else { return false }
        synchronization.requiresRetry = true
        synchronizations[sessionID] = synchronization
        return true
    }

    func consumeRetryRequirement(for lease: Lease) -> Bool {
        guard var synchronization = synchronizations[lease.sessionID],
              synchronization.token == lease.token else { return false }
        let required = synchronization.requiresRetry
        synchronization.requiresRetry = false
        synchronizations[lease.sessionID] = synchronization
        return required
    }

    func prepareLeaderAttempt(_ lease: Lease) {
        guard owns(lease) else { return }
        if case .presentation = lease.intent {
            freshInstallSessionIDs.remove(lease.sessionID)
        }
    }

    func requireFreshInstall(sessionID: String) {
        freshInstallSessionIDs.insert(sessionID)
    }

    func consumeFreshInstallRequirement(sessionID: String) -> Bool {
        freshInstallSessionIDs.remove(sessionID) != nil
    }

    func restartBuffer(for lease: Lease) {
        guard var synchronization = synchronizations[lease.sessionID],
              synchronization.token == lease.token else { return }
        synchronization.events.removeAll(keepingCapacity: false)
        synchronization.overflowed = false
        synchronization.requiresRetry = false
        synchronizations[lease.sessionID] = synchronization
    }

    func complete(_ lease: Lease, outcome: Bool) {
        guard let synchronization = synchronizations[lease.sessionID],
              synchronization.token == lease.token else { return }
        synchronizations.removeValue(forKey: lease.sessionID)
        synchronization.outcome.resolve(outcome)
    }

    func reset() {
        let active = synchronizations.values
        synchronizations.removeAll()
        freshInstallSessionIDs.removeAll()
        for synchronization in active { synchronization.outcome.resolve(false) }
    }

    static func isContiguous(_ events: [GatewayEvent], after baseline: Cursor) -> Bool {
        var cursor = baseline
        for event in events {
            guard event.isConsumableSessionReplay else { return false }
            guard let next = Self.cursor(for: event) else { continue }
            guard next.runtimeGeneration == cursor.runtimeGeneration,
                  next.eventSequence == cursor.eventSequence + 1 else { return false }
            cursor = next
        }
        return true
    }

    static func cursor(for event: GatewayEvent) -> Cursor? {
        event.sessionCursor
    }
}
