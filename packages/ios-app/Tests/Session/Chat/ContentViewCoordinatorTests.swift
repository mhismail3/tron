import XCTest
@testable import TronMobile

/// Tests for ContentViewCoordinator and its workspace resolution logic.
///
/// The coordinator delegates most work to EventStoreManager and EngineClient via
/// async Tasks. Those delegation paths are tested indirectly through integration
/// tests (ConnectionCoordinatorTests, ChatViewModelLifecycleTests). These tests
/// cover the coordinator's own state management and the pure workspace resolution
/// function it depends on.
@MainActor
final class ContentViewCoordinatorTests: XCTestCase {

    // MARK: - Coordinator State Tests

    /// ContentViewCoordinator requires a DependencyContainer. Use the real one
    /// since it initializes synchronously (async init is separate).
    private var container: DependencyContainer!
    private var coordinator: ContentViewCoordinator!

    override func setUp() async throws {
        container = DependencyContainer()
        coordinator = ContentViewCoordinator(dependencies: container)
    }

    override func tearDown() async throws {
        coordinator = nil
        container = nil
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertTrue(coordinator.workspaceDeletedForSession.isEmpty)
        XCTAssertFalse(coordinator.isValidatingWorkspace)
    }

    // MARK: - handleServerSettingsChanged

    func testHandleServerSettingsChangedClearsWorkspaceCache() {
        coordinator.workspaceDeletedForSession = ["sess-1": true, "sess-2": false]
        coordinator.handleServerSettingsChanged()
        XCTAssertTrue(coordinator.workspaceDeletedForSession.isEmpty)
    }

    // MARK: - handleSessionSelection

    func testHandleSessionSelectionNilDoesNotCrash() {
        coordinator.handleSessionSelection(nil)
        // Should not crash or mutate state
        XCTAssertTrue(coordinator.workspaceDeletedForSession.isEmpty)
    }

    // MARK: - handleDeepLink

    func testHandleDeepLinkNilSessionDoesNotNavigate() {
        var navigated = false
        coordinator.handleDeepLink(sessionId: nil, scrollTarget: nil) { _, _ in
            navigated = true
        }
        XCTAssertFalse(navigated, "onNavigate should not be called for nil sessionId")
    }

    // MARK: - handleConnectionEstablished

    func testHandleConnectionEstablishedNilSessionDoesNotCrash() {
        coordinator.handleConnectionEstablished(selectedSessionId: nil)
        // Should not crash — just refreshes session list
    }
}

// MARK: - Pending Deep Link State

final class PendingSessionDeepLinkTests: XCTestCase {
    func testPendingSessionDeepLinkReturnsNilWithoutSession() {
        XCTAssertNil(pendingSessionDeepLink(sessionId: nil, scrollTarget: .bottom))
    }

    func testPendingSessionDeepLinkPreservesSessionAndTarget() {
        XCTAssertEqual(
            pendingSessionDeepLink(
                sessionId: "sess_pending",
                scrollTarget: .capabilityInvocation(id: "cap_123")
            ),
            PendingSessionDeepLink(
                sessionId: "sess_pending",
                scrollTarget: .capabilityInvocation(id: "cap_123")
            )
        )
    }
}

// MARK: - resolveQuickSessionWorkspace (Pure Function Tests)

/// Tests for the workspace resolution logic used by createQuickSession.
/// This is a free function — no coordinator or DI needed.
@MainActor
final class ResolveQuickSessionWorkspaceTests: XCTestCase {

    private let defaultWorkspace = "/Users/default/workspace"

    private func makeSession(id: String, workingDirectory: String) -> CachedSession {
        CachedSession(
            id: id,
            workspaceId: "ws-1",
            title: nil,
            latestModel: "claude-sonnet-4-6",
            workingDirectory: workingDirectory,
            createdAt: "2026-04-01T00:00:00Z",
            lastActivityAt: "2026-04-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0
        )
    }

    // MARK: - Setting Takes Priority

    func testExplicitSettingTakesPriority() {
        let result = resolveQuickSessionWorkspace(
            setting: "/custom/workspace",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: "sess-1",
            sessions: [makeSession(id: "sess-1", workingDirectory: "/session/dir")],
            sortedSessions: [makeSession(id: "sess-1", workingDirectory: "/session/dir")]
        )
        XCTAssertEqual(result, "/custom/workspace")
    }

    func testSettingEqualToDefaultFallsThrough() {
        let result = resolveQuickSessionWorkspace(
            setting: defaultWorkspace,
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: "sess-1",
            sessions: [makeSession(id: "sess-1", workingDirectory: "/session/dir")],
            sortedSessions: []
        )
        XCTAssertEqual(result, "/session/dir")
    }

    func testEmptySettingFallsThrough() {
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: "sess-1",
            sessions: [makeSession(id: "sess-1", workingDirectory: "/session/dir")],
            sortedSessions: []
        )
        XCTAssertEqual(result, "/session/dir")
    }

    // MARK: - Current Session Fallback

    func testCurrentSessionWorkspace() {
        let sessions = [
            makeSession(id: "sess-1", workingDirectory: "/current"),
            makeSession(id: "sess-2", workingDirectory: "/other"),
        ]
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: "sess-1",
            sessions: sessions,
            sortedSessions: sessions
        )
        XCTAssertEqual(result, "/current")
    }

    func testCurrentSessionWithEmptyWorkingDirectoryFallsToRecent() {
        let sessions = [
            makeSession(id: "sess-1", workingDirectory: ""),
            makeSession(id: "sess-2", workingDirectory: "/recent"),
        ]
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: "sess-1",
            sessions: sessions,
            sortedSessions: [makeSession(id: "sess-2", workingDirectory: "/recent")]
        )
        XCTAssertEqual(result, "/recent")
    }

    // MARK: - Most Recent Session Fallback

    func testMostRecentSessionWorkspace() {
        let sorted = [makeSession(id: "sess-recent", workingDirectory: "/recent")]
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: nil,
            sessions: [],
            sortedSessions: sorted
        )
        XCTAssertEqual(result, "/recent")
    }

    func testMostRecentSessionEmptyWorkspaceFallsToDefault() {
        let sorted = [makeSession(id: "sess-recent", workingDirectory: "")]
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: nil,
            sessions: [],
            sortedSessions: sorted
        )
        XCTAssertEqual(result, defaultWorkspace)
    }

    // MARK: - Final Default Fallback

    func testNoSessionsFallsToDefault() {
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: nil,
            sessions: [],
            sortedSessions: []
        )
        XCTAssertEqual(result, defaultWorkspace)
    }

    func testNilSelectedSessionFallsToRecentThenDefault() {
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: nil,
            sessions: [makeSession(id: "sess-1", workingDirectory: "/exists")],
            sortedSessions: [] // No sorted sessions
        )
        XCTAssertEqual(result, defaultWorkspace)
    }

    func testSelectedSessionNotInListFallsToRecent() {
        let result = resolveQuickSessionWorkspace(
            setting: "",
            defaultWorkspace: defaultWorkspace,
            selectedSessionId: "sess-missing",
            sessions: [makeSession(id: "sess-1", workingDirectory: "/exists")],
            sortedSessions: [makeSession(id: "sess-1", workingDirectory: "/exists")]
        )
        XCTAssertEqual(result, "/exists")
    }
}
