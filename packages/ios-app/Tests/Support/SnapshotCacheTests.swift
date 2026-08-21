import Foundation
import Testing
@testable import TronMobile

@Suite("Disposable snapshot cache")
struct SnapshotCacheTests {
    @Test("ratchets bound disposable cache files and individual projections")
    func ratchets() {
        #expect(SnapshotCachePolicy.maximumEncodedBytes == 8_388_608)
        #expect(SnapshotCachePolicy.maximumSessionCount == 250)
        #expect(SnapshotCachePolicy.maximumTranscriptEntriesPerSnapshot == 500)
        #expect(SnapshotCachePolicy.maximumEncodedSessionBytes == 131_072)
        #expect(SnapshotCachePolicy.maximumEncodedSnapshotBytes == 2_097_152)
        #expect(SnapshotCachePolicy.maximumEncodedTranscriptItemBytes == 524_288)
    }

    @Test("writes use protection-at-creation and backup-excluded root policies")
    func filePolicySourceContract() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appending(path: "Sources/Support/SnapshotCache.swift"),
            encoding: .utf8
        )
        #expect(source.contains("options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]"))
        #expect(source.contains("values.isExcludedFromBackup = true"))
    }

    @Test("turns in-flight state into interrupted offline state")
    func storesBoundedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let signposts = RecordingPerformanceSignposts()
        let cache = SnapshotCache(root: root, performanceSignposts: signposts)
        var snapshot = SessionSnapshot(
            sessionId: "session", runtimeGeneration: "generation", revision: 1, eventSequence: 3,
            phase: .running, name: nil, cwd: "/workspace", parentSessionId: nil,
            model: nil, thinkingLevel: "off", availableThinkingLevels: ["off"], contextUsage: nil,
            stats: .init(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0, tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queued: .init(steering: [], followUp: []), transcript: [], transcriptStart: 10, transcriptTotal: 12,
            streaming: nil, leafEntryId: nil,
            operation: .init(id: "operation", kind: .prompt, startedAt: "2026-01-01T00:00:00Z", reason: nil),
            retry: nil, toolExecutions: [],
            extensionPresentation: .init(
                version: 2, hostEpoch: "host", revision: 0, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: true), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: [], inputLease: nil, projection: nil
            ),
            diagnostics: []
        )
        snapshot.toolExecutions = [ToolExecutionState(
            toolCallId: "running-tool",
            toolName: "bash",
            order: 0,
            status: .running,
            arguments: .object([:]),
            partialResult: nil,
            result: nil,
            isError: false,
            startedAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:01Z",
            lastProgressAt: "2026-01-01T00:00:01Z"
        )]
        snapshot.extensionPresentation.semanticState.statuses = ["ephemeral": "value"]
        snapshot.extensionPresentation.surfaces = [.init(
            id: "surface", kind: .widget, placement: .aboveEditor, lifecycle: .retained,
            targetId: nil, provenance: nil, revision: 1, focused: true, inputMode: .keys,
            frame: .init(width: 20, height: 1, lines: [.init(plainText: "surface", runs: [.init(text: "surface", style: .init())])], plainText: "surface", cursor: nil)
        )]
        snapshot.extensionPresentation.pendingInteractions = [.init(
            id: "interaction", hostEpoch: "host", presentationRevision: 1,
            method: .confirm, title: "Confirm", message: nil, options: nil,
            placeholder: nil, prefill: nil, expiresAt: nil
        )]
        snapshot.extensionPresentation.inputLease = .init(
            id: "lease", connectionId: "connection", surfaceId: "surface",
            surfaceRevision: 1, acquiredAt: "2026-01-01T00:00:00Z"
        )
        let summary = SessionSummary(
            id: "session", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .running
        )
        await cache.save(profileID: "profile", sessions: [summary], snapshots: [snapshot])
        let loaded = await cache.load(profileID: "profile")
        #expect(loaded.snapshots.first?.phase == .interrupted)
        #expect(loaded.snapshots.first?.isCachedProjection == true)
        #expect(loaded.snapshots.first?.toolExecutions.first?.status == .running)
        #expect(loaded.snapshots.first?.transcriptStart == 10)
        #expect(loaded.snapshots.first?.transcriptTotal == 12)
        #expect(loaded.snapshots.first?.extensionPresentation.surfaces.isEmpty == true)
        #expect(loaded.snapshots.first?.extensionPresentation.pendingInteractions.isEmpty == true)
        #expect(loaded.snapshots.first?.extensionPresentation.inputLease == nil)
        #expect(loaded.snapshots.first?.extensionPresentation.semanticState.statuses.isEmpty == true)
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

        snapshot.transcriptStart = nil
        snapshot.transcriptTotal = nil
        await cache.save(profileID: "profile", sessions: [summary], snapshots: [snapshot])
        let absentBounds = await cache.load(profileID: "profile").snapshots.first
        #expect(absentBounds?.transcriptStart == nil)
        #expect(absentBounds?.transcriptTotal == nil)
    }

    @Test("malformed maximum source bounds trim without overflow")
    func maximumSourceBoundsAreConservative() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(root: root)
        let item = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
        {"id":"entry","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"x"}]}
        """.utf8))
        let snapshot = SessionSnapshot(
            sessionId: "session", runtimeGeneration: "generation", revision: 1,
            eventSequence: 1, phase: .idle, name: nil, cwd: "/workspace",
            parentSessionId: nil, model: nil, thinkingLevel: "off",
            availableThinkingLevels: ["off"], contextUsage: nil,
            stats: .init(
                userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0,
                totalMessages: 0,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0),
                latestCacheHitRate: nil, cost: 0
            ),
            queued: .init(steering: [], followUp: []),
            transcript: Array(repeating: item, count: 501),
            transcriptStart: Int.max, transcriptTotal: Int.max,
            streaming: nil, leafEntryId: nil, operation: nil, retry: nil,
            toolExecutions: [],
            extensionPresentation: .init(
                version: 2, hostEpoch: "host", revision: 0, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: [], inputLease: nil, projection: nil
            ),
            diagnostics: []
        )
        let summary = SessionSummary(
            id: "session", name: nil, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 501, firstMessage: "x", phase: .idle
        )

        await cache.save(profileID: "profile", sessions: [summary], snapshots: [snapshot])
        let loaded = try #require(await cache.load(profileID: "profile").snapshots.first)
        #expect(loaded.transcript.count == 500)
        #expect(loaded.transcriptStart == nil)
        #expect(loaded.transcriptTotal == Int.max)
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
        #expect(!FileManager.default.fileExists(atPath: file.path))
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

        await cache.save(profileID: "profile", sessions: sessions, snapshots: [])
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
        await cache.save(profileID: "profile", sessions: [], snapshots: [])
        let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)

        try Data(count: SnapshotCachePolicy.maximumEncodedBytes + 1).write(to: file)
        let oversized = await cache.load(profileID: "profile")
        #expect(oversized.sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        await cache.save(profileID: "profile", sessions: [], snapshots: [])
        let replacement = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("{not-json".utf8).write(to: replacement)
        let corrupt = await cache.load(profileID: "profile")
        #expect(corrupt.snapshots.isEmpty)
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
        await cache.save(profileID: "profile-a", sessions: [first], snapshots: [])
        await cache.save(profileID: "profile-b", sessions: [second], snapshots: [])

        await cache.remove(profileID: "profile-a")
        await cache.save(profileID: "profile-a", generation: .max, sessions: [first], snapshots: [])
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

        await cache.save(profileID: "profile", generation: 2, sessions: [newer], snapshots: [])
        await cache.save(profileID: "profile", generation: 1, sessions: [older], snapshots: [])

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

        await cache.save(profileID: "profile", sessions: [], snapshots: [])

        #expect(signposts.events() == [
            .begin(.cacheSave),
            .end(.cacheSave, .failure, .none),
        ])
    }
}
