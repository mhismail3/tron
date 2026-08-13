import Foundation

/// Quarantines sequenced session events while an authoritative baseline is in
/// flight. A successful sync installs the snapshot first, then replays only
/// events newer than that exact generation/sequence cursor.
struct SessionEventSynchronizer: Sendable {
    struct Cursor: Equatable, Sendable {
        let runtimeGeneration: String
        let eventSequence: Int
    }

    enum Admission: Equatable, Sendable {
        case deliver(GatewayEvent)
        case buffered
        case overflow(String)
    }

    private struct Synchronization: Sendable {
        let token: UUID
        var events: [GatewayEvent] = []
        var overflowed = false
    }

    private let maximumBufferedEvents: Int
    private var synchronizations: [String: Synchronization] = [:]

    init(maximumBufferedEvents: Int = 1_024) {
        self.maximumBufferedEvents = maximumBufferedEvents
    }

    func isSynchronizing(sessionID: String) -> Bool {
        synchronizations[sessionID] != nil
    }

    func token(sessionID: String) -> UUID? {
        synchronizations[sessionID]?.token
    }

    mutating func begin(sessionID: String) -> UUID {
        if let existing = synchronizations[sessionID] { return existing.token }
        let token = UUID()
        synchronizations[sessionID] = Synchronization(token: token)
        return token
    }

    mutating func admit(_ event: GatewayEvent) -> Admission {
        guard let sessionID = event.sessionId, var synchronization = synchronizations[sessionID] else {
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

    mutating func complete(sessionID: String, token: UUID, baseline: Cursor?) -> [GatewayEvent]? {
        guard let synchronization = synchronizations[sessionID], synchronization.token == token else { return [] }
        synchronizations.removeValue(forKey: sessionID)
        guard !synchronization.overflowed else { return nil }
        guard let baseline else { return synchronization.events }
        return synchronization.events.filter { event in
            guard let cursor = Self.cursor(for: event) else { return true }
            if cursor.runtimeGeneration != baseline.runtimeGeneration { return true }
            return cursor.eventSequence > baseline.eventSequence
        }
    }

    mutating func cancel(sessionID: String, token: UUID) {
        guard synchronizations[sessionID]?.token == token else { return }
        synchronizations.removeValue(forKey: sessionID)
    }

    mutating func reset() {
        synchronizations.removeAll()
    }

    static func cursor(for event: GatewayEvent) -> Cursor? {
        guard let object = event.payload.objectValue,
              let runtimeGeneration = object["runtimeGeneration"]?.stringValue,
              let eventSequence = object["eventSequence"]?.intValue else { return nil }
        return Cursor(runtimeGeneration: runtimeGeneration, eventSequence: eventSequence)
    }
}
