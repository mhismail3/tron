enum SessionSnapshotEventAdmission: Equatable, Sendable {
    case install
    case ignore
    case resynchronize(String)

    static func evaluate(
        eventSessionID: String?,
        hasLiveAuthority: Bool,
        current: SessionSnapshot?,
        incoming: SessionSnapshot
    ) -> SessionSnapshotEventAdmission {
        guard hasLiveAuthority, let eventSessionID else { return .ignore }
        guard eventSessionID == incoming.sessionId else {
            return .resynchronize(eventSessionID)
        }
        guard let current else { return .resynchronize(eventSessionID) }
        guard current.sessionId == eventSessionID,
              current.runtimeGeneration == incoming.runtimeGeneration else {
            return .resynchronize(eventSessionID)
        }
        if incoming.eventSequence <= current.eventSequence { return .ignore }
        // Activity recency is a separate Gateway-owned projection. A delayed
        // snapshot must not resurrect an older current/recent frame even when
        // its session event sequence is otherwise admissible.
        if let currentLiveRevision = current.liveActivityRevision,
           let incomingLiveRevision = incoming.liveActivityRevision,
           incomingLiveRevision < currentLiveRevision {
            return .ignore
        }
        if incoming.eventSequence != current.eventSequence + 1 {
            return .resynchronize(eventSessionID)
        }
        return .install
    }
}
