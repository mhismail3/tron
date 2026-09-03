import Foundation
import Testing
@testable import TronMobile

@Suite("Summary-only cache")
struct SnapshotCacheTests {
    @Test("summary cache retains bounded file policy")
    func ratchets() {
        #expect(SnapshotCachePolicy.maximumEncodedBytes == 8_388_608)
        #expect(SnapshotCachePolicy.maximumSessionCount == 250)
        #expect(SnapshotCachePolicy.maximumEncodedSessionBytes == 131_072)
    }

    @Test("ignores legacy snapshot state while retaining summaries")
    func ignoresLegacySnapshotValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let signposts = RecordingPerformanceSignposts()
        let cache = SnapshotCache(root: root, performanceSignposts: signposts)
        let summary = SessionSummary(
            id: "session", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            activeSince: "2026-01-01T00:00:00Z", messageCount: 0, firstMessage: "", phase: .running
        )
        await cache.save(profileID: "profile", sessions: [summary])
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy["version"] = 3
        // Legacy snapshot state can be deeply nested, malformed, or the wrong
        // shape independently of valid catalog rows. The cache must ignore the
        // field without decoding it as JSONValue, while the bounded envelope
        // remains comfortably below the file limit.
        var deep: Any = ["leaf": true]
        for _ in 0..<64 { deep = ["nested": deep] }
        legacy["snapshots"] = ["not-a-snapshot", ["invalid": true], deep]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(legacyData.count < SnapshotCachePolicy.maximumEncodedBytes)
        try legacyData.write(to: file, options: .atomic)
        let loaded = await cache.load(profileID: "profile")
        #expect(loaded.sessions.map(\.id) == [summary.id])
        #expect(loaded.sessions.first?.activeSince == summary.activeSince)
        let events = signposts.events()
        #expect(events.count == 4)
        #expect(events[0] == .begin(.cacheSave))
        guard case .end(.cacheSave, .success, let saveMetrics) = events[1] else {
            Issue.record("cache save interval did not complete successfully")
            return
        }
        #expect(saveMetrics.itemCount == 1)
        #expect(saveMetrics.byteCount > 0)
        #expect(events[2] == .begin(.cacheLoad))
        guard case .end(.cacheLoad, .success, let loadMetrics) = events[3] else {
            Issue.record("cache load interval did not complete successfully")
            return
        }
        #expect(loadMetrics.itemCount == saveMetrics.itemCount)
        #expect(loadMetrics.byteCount > 0)

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
        await cache.save(profileID: "profile", sessions: [summary])
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        document["version"] = 2
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)

        let signposts = RecordingPerformanceSignposts()
        let instrumentedCache = SnapshotCache(root: root, performanceSignposts: signposts)
        let loaded = await instrumentedCache.load(profileID: "profile")
        #expect(loaded.sessions.isEmpty)
        let events = signposts.events()
        #expect(events.count == 2)
        #expect(events[0] == .begin(.cacheLoad))
        guard case .end(.cacheLoad, .discarded, let metrics) = events[1] else {
            Issue.record("obsolete cache load was not recorded as discarded")
            return
        }
        #expect(metrics.itemCount == 0)
        #expect(metrics.byteCount > 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("load drops invalid and duplicate rows in deterministic stored order")
    func loadAdmissionIsBoundedAndLossyPerRow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        let valid = SessionSummary(
            id: "duplicate", name: "first", cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1, firstMessage: "first", phase: .idle
        )
        let duplicate = SessionSummary(
            id: "duplicate", name: "second", cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 2, firstMessage: "second", phase: .running
        )
        let oversized = SessionSummary(
            id: "oversized-load", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1, firstMessage: String(repeating: "x", count: SnapshotCachePolicy.maximumEncodedSessionBytes), phase: .idle
        )
        let regular = (0..<300).map { index in
            SessionSummary(
                id: "stored-\(index)", name: nil, cwd: "/workspace", parentSessionId: nil,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                messageCount: 0, firstMessage: "row-\(index)", phase: .idle
            )
        }
        let rows: [SessionSummary] = [valid, duplicate, oversized] + regular
        await cache.save(profileID: "profile", sessions: [])
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let encodedRows = try rows.map { row -> Any in
            try JSONSerialization.jsonObject(with: JSONEncoder.gateway.encode(row))
        }
        let document: [String: Any] = ["version": 4, "sessions": encodedRows]
        try JSONSerialization.data(withJSONObject: document).write(to: file, options: .atomic)

        let loaded = await cache.load(profileID: "profile")
        #expect(loaded.sessions.count == SnapshotCachePolicy.maximumSessionCount)
        #expect(loaded.sessions.first?.id == "duplicate")
        #expect(loaded.sessions.first?.name == "first")
        #expect(!loaded.sessions.contains { $0.id == duplicate.id && $0.name == duplicate.name })
        #expect(!loaded.sessions.contains { $0.id == oversized.id })
        #expect(loaded.sessions.dropFirst().first?.id == "stored-0")
        #expect(loaded.sessions.last?.id == "stored-248")
    }

    @Test("encoded files stay bounded, duplicate IDs retain first authority, and the root is backup excluded")
    func encodedByteBoundAndDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        let payload = String(repeating: "x", count: 100_000)
        var sessions = [SessionSummary(
            id: "oversized", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1, firstMessage: String(repeating: "oversized", count: 131_072), phase: .idle
        )]
        sessions += (0..<100).map { index in
            SessionSummary(
                id: "session-\(index)", name: "first-\(index)", cwd: "/workspace", parentSessionId: nil,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                messageCount: 1, firstMessage: payload, phase: .idle
            )
        }
        sessions.append(SessionSummary(
            id: "session-0", name: "duplicate", cwd: "/other", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 2, firstMessage: "duplicate", phase: .running
        ))

        await cache.save(profileID: "profile", sessions: sessions)
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? .max <= SnapshotCachePolicy.maximumEncodedBytes)
        #if !targetEnvironment(simulator)
        #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        let loaded = await cache.load(profileID: "profile")
        #expect(Set(loaded.sessions.map(\.id)).count == loaded.sessions.count)
        #expect(loaded.sessions.first?.name == "first-0")
        #expect(!loaded.sessions.contains { $0.id == "oversized" })
        #expect(loaded.sessions.count < sessions.count)
    }

    @Test("oversized and corrupt files self-clean without unbounded reads")
    func malformedFilesSelfClean() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        await cache.save(profileID: "profile", sessions: [])
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)

        try Data(count: SnapshotCachePolicy.maximumEncodedBytes + 1).write(to: file)
        let oversized = await cache.load(profileID: "profile")
        #expect(oversized.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        await cache.save(profileID: "profile", sessions: [])
        let replacement = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("{not-json".utf8).write(to: replacement)
        _ = await cache.load(profileID: "profile")
        #expect(!FileManager.default.fileExists(atPath: replacement.path))
    }

    @Test("profile removal deletes only the matching disposable cache")
    func profileRemovalIsIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        let first = SessionSummary(
            id: "first", name: nil, cwd: "/one", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .idle
        )
        let second = SessionSummary(
            id: "second", name: nil, cwd: "/two", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .idle
        )
        await cache.save(profileID: "profile-a", sessions: [first])
        await cache.save(profileID: "profile-b", sessions: [second])

        await cache.remove(profileID: "profile-a")
        await cache.save(profileID: "profile-a", generation: .max, sessions: [first])
        #expect((await cache.load(profileID: "profile-a")).sessions.isEmpty)
        #expect((await cache.load(profileID: "profile-b")).sessions.map(\.id) == ["second"])
    }

    @Test("newest generation wins when checkpoint tasks arrive out of order")
    func newestGenerationWins() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        let newer = SessionSummary(
            id: "session", name: "newer", cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:02Z",
            messageCount: 2, firstMessage: "newer", phase: .running, summaryRevision: 2
        )
        let older = SessionSummary(
            id: "session", name: "older", cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 1, firstMessage: "older", phase: .idle, summaryRevision: 1
        )

        await cache.save(profileID: "profile", generation: 2, sessions: [newer])
        await cache.save(profileID: "profile", generation: 1, sessions: [older])

        let loaded = await cache.load(profileID: "profile")
        #expect(loaded.sessions.first?.name == "newer")
        #expect(loaded.sessions.first?.summaryRevision == 2)
    }

    @Test("records unwritable cache destinations as failed saves")
    func recordsFailedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let signposts = RecordingPerformanceSignposts()
        let cache = SnapshotCache(root: root, performanceSignposts: signposts)

        await cache.save(profileID: "profile", sessions: [])

        #expect(signposts.events() == [
            .begin(.cacheSave),
            .end(.cacheSave, .failure, .none),
        ])
    }
}
