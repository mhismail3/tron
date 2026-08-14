import Foundation
import Testing
@testable import TronMobile

@Suite("Disposable snapshot cache")
struct SnapshotCacheTests {
    @Test("turns in-flight state into interrupted offline state")
    func storesBoundedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let signposts = RecordingPerformanceSignposts()
        let cache = SnapshotCache(root: root, performanceSignposts: signposts)
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
        let events = signposts.events()
        #expect(events.count == 4)
        #expect(events[0] == .begin(.cacheSave))
        guard case .end(.cacheSave, .success, let saveMetrics) = events[1] else {
            Issue.record("cache save interval did not complete successfully")
            return
        }
        #expect(saveMetrics.itemCount == 2)
        #expect(saveMetrics.byteCount > 0)
        #expect(events[2] == .begin(.cacheLoad))
        guard case .end(.cacheLoad, .success, let loadMetrics) = events[3] else {
            Issue.record("cache load interval did not complete successfully")
            return
        }
        #expect(loadMetrics == saveMetrics)
    }

    @Test("rejects caches from before session-kind classification")
    func rejectsVersionTwoCache() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cache = SnapshotCache(root: root)
        let summary = SessionSummary(
            id: "legacy", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1, firstMessage: "legacy", phase: .idle
        )
        await cache.save(profileID: "profile", sessions: [summary], snapshots: [])
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document["version"] = 2
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)

        let signposts = RecordingPerformanceSignposts()
        let instrumentedCache = SnapshotCache(root: root, performanceSignposts: signposts)
        let loaded = await instrumentedCache.load(profileID: "profile")
        #expect(loaded.sessions.isEmpty)
        #expect(loaded.snapshots.isEmpty)
        let events = signposts.events()
        #expect(events.count == 2)
        #expect(events[0] == .begin(.cacheLoad))
        guard case .end(.cacheLoad, .discarded, let metrics) = events[1] else {
            Issue.record("obsolete cache load was not recorded as discarded")
            return
        }
        #expect(metrics.itemCount == 0)
        #expect(metrics.byteCount > 0)
    }

    @Test("records unwritable cache destinations as failed saves")
    func recordsFailedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let signposts = RecordingPerformanceSignposts()
        let cache = SnapshotCache(root: root, performanceSignposts: signposts)

        await cache.save(profileID: "profile", sessions: [], snapshots: [])

        #expect(signposts.events() == [
            .begin(.cacheSave),
            .end(.cacheSave, .failure, .none),
        ])
    }
}
