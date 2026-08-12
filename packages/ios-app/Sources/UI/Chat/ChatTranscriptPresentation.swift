import Foundation

/// Presentation-only filtering for Pi's canonical transcript. Configuration
/// entries before the first conversational entry describe session bootstrap
/// state and belong in Manage Session, not in the chat transcript. Later
/// configuration entries remain visible as compact change notifications.
struct ChatResponseState: Equatable {
    let sessionID: String
    let canonicalEntryCount: Int
    let tailEntryID: String?
    let streaming: TranscriptItem?
    let tools: [ToolExecutionState]

    init(snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        canonicalEntryCount = snapshot.transcriptTotal ?? snapshot.transcript.count
        tailEntryID = snapshot.transcript.last?.id
        streaming = snapshot.streaming
        tools = snapshot.toolExecutions
    }
}

enum ChatUnreadResponsePolicy {
    static func shouldMarkUnread(
        previous: ChatResponseState?,
        current: ChatResponseState,
        userScrolledAway: Bool
    ) -> Bool {
        guard let previous, previous.sessionID == current.sessionID else { return false }
        return previous != current && userScrolledAway
    }
}

enum ChatTranscriptPresentation {
    static func items(in snapshot: SessionSnapshot) -> [TranscriptItem] {
        let visibleCallIDs = Set(snapshot.transcript.flatMap { item in
            (item.content ?? []).compactMap(\.toolCallId)
        })
        var conversationHasBegun = (snapshot.transcriptStart ?? 0) > 0

        return snapshot.transcript.filter { item in
            if item.kind == .message {
                conversationHasBegun = true
            }
            if item.kind == .modelChange || item.kind == .thinkingChange {
                return conversationHasBegun
            }
            if item.role == .toolResult, let callID = item.toolCallId {
                return !visibleCallIDs.contains(callID)
            }
            return true
        }
    }

    static func toolResults(in snapshot: SessionSnapshot) -> [String: TranscriptItem] {
        Dictionary(
            snapshot.transcript.compactMap { item in
                guard item.role == .toolResult, let callID = item.toolCallId else { return nil }
                return (callID, item)
            },
            uniquingKeysWith: { _, newest in newest }
        )
    }
}
