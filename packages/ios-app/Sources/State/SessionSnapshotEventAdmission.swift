enum SessionSnapshotQueueAdmissionPolicy {
    static func admit(_ snapshot: SessionSnapshot) -> Bool {
        let displayed = snapshot.displayedQueuedMessages
        guard displayed.count <= SessionSnapshot.maximumQueuedMessages else { return false }
        let ids = displayed.map(\.id)
        return ids.allSatisfy { !$0.isEmpty } && Set(ids).count == ids.count
    }
}

enum SessionRebaselineAdmission: Equatable, Sendable {
    case install
    case ignore
    case resynchronize

    static func evaluate(
        current: SessionSnapshot?,
        incoming: SessionSnapshot
    ) -> SessionRebaselineAdmission {
        guard SessionSnapshotQueueAdmissionPolicy.admit(incoming) else { return .resynchronize }
        guard let current, current.sessionId == incoming.sessionId else { return .install }
        guard current.runtimeGeneration == incoming.runtimeGeneration else { return .install }
        guard incoming.eventSequence > current.eventSequence else { return .ignore }
        if let currentLiveRevision = current.liveActivityRevision {
            guard let incomingLiveRevision = incoming.liveActivityRevision,
                  incomingLiveRevision >= currentLiveRevision else { return .resynchronize }
        }
        return .install
    }
}

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
        guard SessionSnapshotQueueAdmissionPolicy.admit(incoming) else {
            return .resynchronize(eventSessionID)
        }
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
        if let currentLiveRevision = current.liveActivityRevision {
            guard let incomingLiveRevision = incoming.liveActivityRevision else {
                // A missing revision cannot prove that an exact-next snapshot
                // is newer. Rebaseline instead of installing it and stalling
                // the live cursor behind an ambiguous frame.
                return .resynchronize(eventSessionID)
            }
            if incomingLiveRevision < currentLiveRevision {
                // The session cursor is exact-next but this subprojection
                // regressed. Ignoring it would leave the next event looking
                // like a gap, so recover authority immediately.
                return .resynchronize(eventSessionID)
            }
        }
        if incoming.eventSequence != current.eventSequence + 1 {
            return .resynchronize(eventSessionID)
        }
        return .install
    }
}
