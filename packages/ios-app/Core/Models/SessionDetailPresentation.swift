import Foundation

/// Disposable, independently observable facts for descendants of a frozen chat.
/// Neither transport revisions nor ordinary assistant text belong in these values.
package struct SessionHistoryPresentation: Hashable, Sendable {
    package let sessionID: String
    package let phase: SessionPhase
    package let stats: SessionStats
    package let leafEntryId: String?

    package init(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        phase = snapshot.phase
        stats = snapshot.stats
        leafEntryId = snapshot.leafEntryId
    }
}

package struct SessionProcessPresentation: Hashable, Sendable {
    package let sessionID: String
    package let activities: [SessionProcessActivity]

    package init(_ snapshot: SessionSnapshot, previous: Self? = nil) {
        sessionID = snapshot.sessionId
        let previousActivities = previous?.sessionID == sessionID ? previous?.activities ?? [] : []
        activities = (snapshot.processActivities ?? []).map { process in
            process.retainingDurationSample(from: previousActivities.first { $0.processId == process.processId })
        }
    }
}

package struct SessionQueuePresentation: Hashable, Sendable {
    package let sessionID: String
    package let runtimeGeneration: String
    package let revision: Int
    package let items: [SessionSnapshot.QueuedMessage]

    package init(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        runtimeGeneration = snapshot.runtimeGeneration
        revision = snapshot.queueRevision
        items = snapshot.queuedItems
    }
}

package struct SessionToolDetailSource: Hashable, Sendable {
    package let sessionID: String
    package let runtimeGeneration: String
    package let phase: SessionPhase
    package let acceptsQueuedPrompts: Bool?
    package let activeToolSegmentId: String?
    package let executions: [ToolExecutionState]
    package let canonical: [TranscriptItem]
    package let streaming: TranscriptItem?

    package init(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        runtimeGeneration = snapshot.runtimeGeneration
        phase = snapshot.phase
        acceptsQueuedPrompts = snapshot.acceptsQueuedPrompts
        activeToolSegmentId = snapshot.activeToolSegmentId
        executions = snapshot.toolExecutions
        streaming = snapshot.streaming.flatMap { item in
            item.content?.contains { $0.type == .toolCall } == true ? item : nil
        }
        // Canonical results remain authoritative when runtime execution rows
        // retire. Use the admitted tail, never fetch or mirror another session.
        canonical = snapshot.transcript.suffix(SessionSnapshot.maximumTranscriptItems).filter {
            $0.role == .toolResult || $0.content?.contains { $0.type == .toolCall } == true
        }
    }
}
