import Testing
@testable import TronMobile

@Suite("CachedSession.recentWorkspaces")
struct RecentWorkspacesTests {

    // MARK: - Factory

    private func makeSession(
        id: String,
        workingDirectory: String,
        lastActivityAt: String = "2026-01-01T00:00:00Z"
    ) -> CachedSession {
        CachedSession(
            id: id,
            workspaceId: workingDirectory,
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4-6",
            workingDirectory: workingDirectory,
            createdAt: "2026-01-01T00:00:00Z",
            lastActivityAt: lastActivityAt,
            archivedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0
        )
    }

    // MARK: - Empty

    @Test("returns empty for no sessions")
    func emptySessions() {
        let result = CachedSession.recentWorkspaces(from: [])
        #expect(result.isEmpty)
    }

    // MARK: - Basic

    @Test("returns single workspace")
    func singleSession() {
        let sessions = [makeSession(id: "s1", workingDirectory: "/Users/dev/project-a")]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 1)
        #expect(result[0].path == "/Users/dev/project-a")
        #expect(result[0].name == "project-a")
    }

    @Test("returns multiple unique workspaces in order")
    func multipleUnique() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: "/Users/dev/alpha"),
            makeSession(id: "s2", workingDirectory: "/Users/dev/beta"),
            makeSession(id: "s3", workingDirectory: "/Users/dev/gamma"),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 3)
        #expect(result[0].name == "alpha")
        #expect(result[1].name == "beta")
        #expect(result[2].name == "gamma")
    }

    // MARK: - Deduplication

    @Test("deduplicates sessions with same workingDirectory")
    func deduplication() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: "/Users/dev/project-a"),
            makeSession(id: "s2", workingDirectory: "/Users/dev/project-b"),
            makeSession(id: "s3", workingDirectory: "/Users/dev/project-a"),
            makeSession(id: "s4", workingDirectory: "/Users/dev/project-b"),
            makeSession(id: "s5", workingDirectory: "/Users/dev/project-c"),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 3)
        #expect(result[0].path == "/Users/dev/project-a")
        #expect(result[1].path == "/Users/dev/project-b")
        #expect(result[2].path == "/Users/dev/project-c")
    }

    @Test("all sessions same workspace yields one pill")
    func allSameWorkspace() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: "/tmp/same"),
            makeSession(id: "s2", workingDirectory: "/tmp/same"),
            makeSession(id: "s3", workingDirectory: "/tmp/same"),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 1)
        #expect(result[0].path == "/tmp/same")
    }

    // MARK: - Filtering

    @Test("filters out sessions with empty workingDirectory")
    func emptyWorkingDirectory() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: ""),
            makeSession(id: "s2", workingDirectory: "/Users/dev/real"),
            makeSession(id: "s3", workingDirectory: ""),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 1)
        #expect(result[0].path == "/Users/dev/real")
    }

    @Test("all empty workingDirectories returns empty")
    func allEmpty() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: ""),
            makeSession(id: "s2", workingDirectory: ""),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.isEmpty)
    }

    // MARK: - Order Preservation

    @Test("preserves input order (first occurrence wins)")
    func orderPreservation() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: "/a/newest"),
            makeSession(id: "s2", workingDirectory: "/b/middle"),
            makeSession(id: "s3", workingDirectory: "/a/newest"),
            makeSession(id: "s4", workingDirectory: "/c/oldest"),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 3)
        #expect(result[0].path == "/a/newest")
        #expect(result[1].path == "/b/middle")
        #expect(result[2].path == "/c/oldest")
    }

    // MARK: - Name Extraction

    @Test("extracts last path component as name")
    func nameExtraction() {
        let sessions = [
            makeSession(id: "s1", workingDirectory: "/Users/dev/deeply/nested/my-project"),
            makeSession(id: "s2", workingDirectory: "/tmp"),
        ]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result[0].name == "my-project")
        #expect(result[1].name == "tmp")
    }

    @Test("root path returns /")
    func rootPath() {
        let sessions = [makeSession(id: "s1", workingDirectory: "/")]
        let result = CachedSession.recentWorkspaces(from: sessions)
        #expect(result.count == 1)
        #expect(result[0].name == "/")
    }
}
