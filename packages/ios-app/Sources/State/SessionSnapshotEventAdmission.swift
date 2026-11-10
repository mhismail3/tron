import TronMobileCore

enum SessionRebaselineAdmission: Equatable, Sendable {
    case install
    case ignore
    case resynchronize

    static func evaluate(
        current: SessionSnapshot?,
        incoming: SessionSnapshot
    ) -> SessionRebaselineAdmission {
        guard incoming.revision >= 0,
              SessionSnapshotTranscriptAdmissionPolicy.admit(incoming),
              SessionSnapshotQueueAdmissionPolicy.admit(incoming) else {
            return .resynchronize
        }
        guard let current, current.sessionId == incoming.sessionId else { return .install }
        guard current.runtimeGeneration == incoming.runtimeGeneration else { return .install }
        guard incoming.eventSequence > current.eventSequence else { return .ignore }
        guard incoming.revision >= current.revision else { return .resynchronize }
        if let currentLiveRevision = current.liveActivityRevision {
            guard let incomingLiveRevision = incoming.liveActivityRevision,
                  incomingLiveRevision >= currentLiveRevision else { return .resynchronize }
        }
        if let currentProcessRevision = current.processOverview?.revision {
            guard let incomingProcessRevision = incoming.processOverview?.revision,
                  incomingProcessRevision >= currentProcessRevision else { return .resynchronize }
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
        guard incoming.revision >= 0,
              SessionSnapshotTranscriptAdmissionPolicy.admit(incoming),
              SessionSnapshotQueueAdmissionPolicy.admit(incoming) else {
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
        guard incoming.revision >= current.revision else {
            return .resynchronize(eventSessionID)
        }
        if let currentProcessRevision = current.processOverview?.revision {
            guard let incomingProcessRevision = incoming.processOverview?.revision else {
                return .resynchronize(eventSessionID)
            }
            if incomingProcessRevision < currentProcessRevision {
                return .resynchronize(eventSessionID)
            }
        }
        if let currentLiveRevision = current.liveActivityRevision {
            guard let incomingLiveRevision = incoming.liveActivityRevision else {
                return .resynchronize(eventSessionID)
            }
            if incomingLiveRevision < currentLiveRevision {
                return .resynchronize(eventSessionID)
            }
        }
        if incoming.eventSequence != current.eventSequence + 1 {
            return .resynchronize(eventSessionID)
        }
        return .install
    }
}
