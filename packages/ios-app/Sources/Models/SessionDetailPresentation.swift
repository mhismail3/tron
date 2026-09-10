import Foundation

/// Disposable, independently observable facts for descendants of a frozen chat.
/// Neither transport revisions nor ordinary assistant text belong in these values.
struct SessionHistoryPresentation: Hashable, Sendable {
    let sessionID: String
    let phase: SessionPhase
    let stats: SessionStats
    let leafEntryId: String?

    init(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        phase = snapshot.phase
        stats = snapshot.stats
        leafEntryId = snapshot.leafEntryId
    }
}

struct SessionProcessPresentation: Hashable, Sendable {
    let sessionID: String
    let activities: [SessionProcessActivity]

    init(_ snapshot: SessionSnapshot, previous: Self? = nil) {
        sessionID = snapshot.sessionId
        let previousActivities = previous?.sessionID == sessionID ? previous?.activities ?? [] : []
        activities = (snapshot.processActivities ?? []).map { process in
            process.retainingDurationSample(from: previousActivities.first { $0.processId == process.processId })
        }
    }
}

struct SessionQueuePresentation: Hashable, Sendable {
    let sessionID: String
    let runtimeGeneration: String
    let revision: Int
    let items: [SessionSnapshot.QueuedMessage]

    init(_ snapshot: SessionSnapshot) {
        sessionID = snapshot.sessionId
        runtimeGeneration = snapshot.runtimeGeneration
        revision = snapshot.queueRevision
        items = snapshot.queuedItems
    }
}

struct SessionToolDetailSource: Hashable, Sendable {
    let sessionID: String
    let runtimeGeneration: String
    let phase: SessionPhase
    let acceptsQueuedPrompts: Bool?
    let activeToolSegmentId: String?
    let executions: [ToolExecutionState]
    let canonical: [TranscriptItem]
    let streaming: TranscriptItem?

    init(_ snapshot: SessionSnapshot) {
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
