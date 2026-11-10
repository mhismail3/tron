import Foundation
import TronMobileCore

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
