import XCTest
@testable import TronMobile

@MainActor
final class QuickSessionWorkspaceTests: XCTestCase {

    // MARK: - Setting takes priority

    func testExplicitSettingWinsOverCurrentSession() {
        let current = makeCachedSession(id: "current", workingDirectory: "/Users/me/ProjectA")
        let result = resolveQuickSessionWorkspace(
            setting: "/Users/me/Configured",
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: "current",
            sessions: [current],
            sortedSessions: [current]
        )
        XCTAssertEqual(result, "/Users/me/Configured")
    }

    func testExplicitSettingWinsOverMostRecentSession() {
        let recent = makeCachedSession(id: "recent", workingDirectory: "/Users/me/ProjectB")
        let result = resolveQuickSessionWorkspace(
            setting: "/Users/me/Configured",
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: nil,
            sessions: [recent],
            sortedSessions: [recent]
        )
        XCTAssertEqual(result, "/Users/me/Configured")
    }

    // MARK: - Setting equals default → treat as unset

    func testDefaultWorkspaceSettingFallsBackToCurrentSession() {
        let current = makeCachedSession(id: "current", workingDirectory: "/Users/me/ProjectA")
        let result = resolveQuickSessionWorkspace(
            setting: AppConstants.defaultWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: "current",
            sessions: [current],
            sortedSessions: [current]
        )
        XCTAssertEqual(result, "/Users/me/ProjectA")
    }

    func testEmptySettingFallsBackToCurrentSession() {
        let current = makeCachedSession(id: "current", workingDirectory: "/Users/me/ProjectA")
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: "current",
            sessions: [current],
            sortedSessions: [current]
        )
        XCTAssertEqual(result, "/Users/me/ProjectA")
    }

    // MARK: - Fallback chain (no explicit setting)

    func testFallsBackToCurrentSessionWhenNoSetting() {
        let current = makeCachedSession(id: "s1", workingDirectory: "/Users/me/ProjectA")
        let other = makeCachedSession(id: "s2", workingDirectory: "/Users/me/ProjectB")
        let result = resolveQuickSessionWorkspace(
            setting: AppConstants.defaultWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: "s1",
            sessions: [current, other],
            sortedSessions: [other, current]
        )
        XCTAssertEqual(result, "/Users/me/ProjectA")
    }

    func testFallsBackToMostRecentWhenNoCurrentSession() {
        let recent = makeCachedSession(id: "recent", workingDirectory: "/Users/me/ProjectB")
        let result = resolveQuickSessionWorkspace(
            setting: AppConstants.defaultWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: nil,
            sessions: [recent],
            sortedSessions: [recent]
        )
        XCTAssertEqual(result, "/Users/me/ProjectB")
    }

    func testFallsBackToMostRecentWhenCurrentHasEmptyWorkspace() {
        let current = makeCachedSession(id: "current", workingDirectory: "")
        let recent = makeCachedSession(id: "recent", workingDirectory: "/Users/me/ProjectB")
        let result = resolveQuickSessionWorkspace(
            setting: AppConstants.defaultWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: "current",
            sessions: [current, recent],
            sortedSessions: [recent, current]
        )
        XCTAssertEqual(result, "/Users/me/ProjectB")
    }

    func testFallsBackToDefaultWhenNoSessions() {
        let result = resolveQuickSessionWorkspace(
            setting: AppConstants.defaultWorkspace,
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: nil,
            sessions: [],
            sortedSessions: []
        )
        XCTAssertEqual(result, AppConstants.defaultWorkspace)
    }

    func testFallsBackToDefaultWhenAllSessionsHaveEmptyWorkspace() {
        let s1 = makeCachedSession(id: "s1", workingDirectory: "")
        let s2 = makeCachedSession(id: "s2", workingDirectory: "")
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: AppConstants.defaultWorkspace,
            selectedSessionId: "s1",
            sessions: [s1, s2],
            sortedSessions: [s2, s1]
        )
        XCTAssertEqual(result, AppConstants.defaultWorkspace)
    }

    // MARK: - Helpers

    private func makeCachedSession(id: String, workingDirectory: String) -> CachedSession {
        CachedSession(
            id: id,
            workspaceId: workingDirectory,
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4-5-20250514",
            workingDirectory: workingDirectory,
            createdAt: "2026-01-01T00:00:00Z",
            lastActivityAt: "2026-01-01T00:00:00Z",
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
}
