import Foundation
import Testing
@testable import TronMobile

@Suite("Disposable snapshot cache")
struct SnapshotCacheTests {
    @Test("turns in-flight state into interrupted offline state")
    func storesBoundedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = SnapshotCache(root: root)
        let snapshot = SessionSnapshot(
            sessionId: "session", runtimeGeneration: "generation", revision: 1, eventSequence: 3,
            phase: .running, name: nil, cwd: "/workspace", parentSessionId: nil,
            model: nil, thinkingLevel: "off", availableThinkingLevels: ["off"], contextUsage: nil,
            stats: .init(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0, tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queued: .init(steering: [], followUp: []), transcript: [], transcriptStart: 10, transcriptTotal: 12,
            streaming: nil, leafEntryId: nil,
            operation: .init(id: "operation", kind: .prompt, startedAt: "2026-01-01T00:00:00Z", reason: nil),
            retry: nil, toolExecutions: [],
            extensionUI: .init(
                statuses: [:], working: .init(message: nil, visible: true), hiddenThinkingLabel: nil,
                widgets: [], title: nil, editorRevision: 0, editorText: "", pendingInteractions: []
            ),
            diagnostics: []
        )
        let summary = SessionSummary(
            id: "session", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .running
        )
        await cache.save(profileID: "profile", sessions: [summary], snapshots: [snapshot])
        let loaded = await cache.load(profileID: "profile")
        #expect(loaded.snapshots.first?.phase == .interrupted)
        #expect(loaded.snapshots.first?.transcriptStart == 10)
        #expect(loaded.snapshots.first?.transcriptTotal == 12)
    }
}
