enum SessionSnapshotTranscriptAdmissionPolicy {
    static let maximumItemIdentityUTF8Bytes = 512

    static func admit(_ snapshot: SessionSnapshot) -> Bool {
        guard admitsItems(snapshot.transcript),
              snapshot.streaming.map(admitsItem) ?? true,
              snapshot.activeToolSegmentId.map({
                  !$0.isEmpty && $0.utf8.count <= maximumItemIdentityUTF8Bytes
                      && snapshot.phase == .running
                      && snapshot.acceptsQueuedPrompts != false
              }) ?? true else { return false }
        switch (snapshot.transcriptStart, snapshot.transcriptTotal) {
        case (nil, nil):
            // Legacy/test projections without paging metadata remain valid. A
            // partial pair cannot establish a canonical range.
            return true
        case let (start?, total?):
            guard start >= 0, total >= start else { return false }
            let (end, overflow) = start.addingReportingOverflow(snapshot.transcript.count)
            return !overflow && end == total
        default:
            return false
        }
    }

    static func admitsPage(_ items: [TranscriptItem]) -> Bool {
        admitsItems(items)
    }

    static func admitsItem(_ item: TranscriptItem) -> Bool {
        !item.id.isEmpty && item.id.utf8.count <= maximumItemIdentityUTF8Bytes
    }

    private static func admitsItems(_ items: [TranscriptItem]) -> Bool {
        guard items.count <= SessionSnapshot.maximumTranscriptItems,
              items.allSatisfy(admitsItem) else { return false }
        return Set(items.map(\.id)).count == items.count
    }
}

enum SessionSnapshotQueueAdmissionPolicy {
    static func admit(_ snapshot: SessionSnapshot) -> Bool {
        let displayed = snapshot.displayedQueuedMessages
        guard displayed.count <= SessionSnapshot.maximumQueuedMessages else { return false }
        let ids = displayed.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { return false }
        guard displayed.allSatisfy({ message in
            admits(
                message.resourceInvocation,
                text: message.text,
                attachmentCount: message.attachmentCount
            )
        }) else { return false }
        guard let pending = snapshot.pendingPrompt else { return true }
        return admits(
            pending.resourceInvocation,
            text: pending.text,
            attachmentCount: pending.attachmentCount
        )
    }

    private static func admits(
        _ resource: ComposerResourceInvocation?,
        text: String,
        attachmentCount: Int
    ) -> Bool {
        guard attachmentCount >= 0 else { return false }
        guard let resource else { return true }
        guard resource.arguments == text, resource.isTransportValid else { return false }
        // Extension commands execute immediately and never belong to prompt queue state.
        return resource.source != .extension
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
        // Activity recency is a separate Gateway-owned projection. A delayed
        // snapshot must not resurrect an older current/recent frame even when
        // its session event sequence is otherwise admissible.
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
