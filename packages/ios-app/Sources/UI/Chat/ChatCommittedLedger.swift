import Foundation

/// Frozen canonical rows inside one complete installed transcript. The revision
/// is local structural lineage: an unchanged canonical identity/membership spine
/// reuses it across live payload updates, while any canonical append, prepend,
/// replacement, or tool-membership change advances it exactly once. A cold owner
/// starts at one deterministically from the authoritative snapshot.
struct ChatCommittedLedger: Hashable, Sendable {
    let revision: UInt64
    let items: [ChatTranscriptRenderItem]

    init(items: [ChatTranscriptRenderItem], revision: UInt64 = 1) {
        self.items = items
        self.revision = max(1, revision)
    }

    static func reconcile(
        items: [ChatTranscriptRenderItem],
        previous: ChatCommittedLedger?
    ) -> Self {
        guard let previous else { return Self(items: items) }
        guard previous.items != items else { return previous }
        if hasSameStructuralSpine(previous.items, items) {
            // Canonical rows can be enriched by disposable execution timing,
            // output, and status. Install the newest value without claiming a
            // canonical append/prepend or replaying scroll/entrance ownership.
            return Self(items: items, revision: previous.revision)
        }
        let nextRevision = previous.revision == .max ? UInt64.max : previous.revision + 1
        return Self(items: items, revision: nextRevision)
    }

    private static func hasSameStructuralSpine(
        _ previous: [ChatTranscriptRenderItem],
        _ incoming: [ChatTranscriptRenderItem]
    ) -> Bool {
        guard previous.count == incoming.count else { return false }
        return zip(previous, incoming).allSatisfy { old, new in
            guard old.id == new.id else { return false }
            switch (old, new) {
            case (.transcript, .transcript), (.message, .message), (.notification, .notification):
                return true
            case let (.toolRun(oldRun), .toolRun(newRun)):
                return oldRun.tools.map(\.id) == newRun.tools.map(\.id)
                    && oldRun.groupIDs == newRun.groupIDs
            default:
                return false
            }
        }
    }
}

/// Mutable-tail facts of the same atomic installed commit. This is a bounded
/// value projection, not a store or cache. Replacing it cannot advance the
/// committed ledger revision.
struct ChatLiveRegion: Hashable, Sendable {
    let items: [ChatTranscriptRenderItem]
    let handoff: ChatTranscriptHandoffCommit
    let queuedMessages: [SessionSnapshot.QueuedMessage]
    let queuePresentationIDByOperationID: [String: String]

    init(
        timelineItems: [ChatTranscriptRenderItem],
        runtimeItems: [ChatTranscriptRenderItem],
        handoff: ChatTranscriptHandoffCommit,
        queuedMessages: [SessionSnapshot.QueuedMessage],
        queuePresentationIDByOperationID: [String: String]
    ) {
        items = timelineItems + runtimeItems
        self.handoff = handoff
        self.queuedMessages = queuedMessages
        self.queuePresentationIDByOperationID = queuePresentationIDByOperationID
    }
}

/// Exact payload identity for one tool row. Unlike an installation tag or a
/// whole-index counter, unrelated authority and other tool updates do not
/// invalidate this row.
struct ChatToolPayloadRevision: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
        let callID: String
        let payload: ChatToolPayload?
    }

    static let empty = Self(entries: [])
    let entries: [Entry]

    init(callIDs: [String], payloads: ChatToolPayloadIndex) {
        entries = callIDs.map { Entry(callID: $0, payload: payloads.payload(for: $0)) }
    }

    private init(entries: [Entry]) {
        self.entries = entries
    }
}
