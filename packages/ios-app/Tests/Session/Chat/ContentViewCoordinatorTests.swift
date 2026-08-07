import XCTest
@testable import TronMobile

/// Tests for ContentViewCoordinator and its workspace resolution helper.
///
/// The coordinator delegates most work to EventStoreManager and EngineClient via
/// async Tasks. Those delegation paths are tested indirectly through integration
/// tests (ConnectionCoordinatorTests, ChatViewModelLifecycleTests). These tests
/// cover its deep-link input boundary and the pure workspace resolution function.
@MainActor
final class ContentViewCoordinatorTests: XCTestCase {

    // MARK: - Coordinator State Tests

    /// ContentViewCoordinator requires a DependencyContainer. Use the real one
    /// since it initializes synchronously (async init is separate).
    private var container: DependencyContainer!
    private var coordinator: ContentViewCoordinator!
    private var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "content-view-coordinator")
        testState.registerTeardown(with: self)
        container = testState.makeContainer()
        coordinator = ContentViewCoordinator(dependencies: container)
    }

    override func tearDown() async throws {
        coordinator = nil
        container = nil
        await testState.cleanup()
    }

    // MARK: - handleDeepLink

    func testHandleDeepLinkNilSessionDoesNotNavigate() {
        var navigated = false
        coordinator.handleDeepLink(sessionId: nil, scrollTarget: nil) { _, _ in
            navigated = true
        }
        XCTAssertFalse(navigated, "onNavigate should not be called for nil sessionId")
    }

    func testHandleDeepLinkNavigatesImmediatelyForPublishedSession() async throws {
        try await container.eventDatabase.initialize()
        try await container.eventStoreManager.cacheNewSession(
            sessionId: "sess-local-deep-link",
            workspaceId: "/tmp/tron-fixtures/deep-link",
            model: "test-model",
            workingDirectory: "/tmp/tron-fixtures/deep-link"
        )
        var navigation: (String, ScrollTarget?)?

        coordinator.handleDeepLink(
            sessionId: "sess-local-deep-link",
            scrollTarget: .bottom
        ) { sessionId, target in
            navigation = (sessionId, target)
        }

        XCTAssertEqual(navigation?.0, "sess-local-deep-link")
        XCTAssertEqual(navigation?.1, .bottom)
    }

    func testHandleDeepLinkRefreshesSessionIndexBeforeNavigation() async throws {
        try await container.eventDatabase.initialize()
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:8080/engine")!
        )
        transport.connectionState = .connected
        transport.serverOrigin = container.engineClient.serverOrigin
        var listReads = 0
        transport.readHandler = { functionId, _, _ in
            guard functionId.rawValue == "session::list" else {
                throw EngineConnectionError.invalidResponse
            }
            listReads += 1
            return SessionListResult(
                sessions: [Self.serverSessionInfo(id: "sess-remote-deep-link")],
                totalCount: 1,
                hasMore: false,
                nextCursor: nil,
                snapshotAsOf: "2026-08-06T00:00:00Z",
                snapshotCanReconcile: true
            )
        }
        container.engineClient.session = SessionClient(transport: transport)
        let navigated = expectation(description: "deep link navigated after list refresh")
        var navigation: (String, ScrollTarget?)?

        coordinator.handleDeepLink(
            sessionId: "sess-remote-deep-link",
            scrollTarget: .event(id: "event-1")
        ) { sessionId, target in
            navigation = (sessionId, target)
            navigated.fulfill()
        }

        await fulfillment(of: [navigated], timeout: 1)
        XCTAssertEqual(listReads, 1)
        XCTAssertEqual(navigation?.0, "sess-remote-deep-link")
        XCTAssertEqual(navigation?.1, .event(id: "event-1"))
        XCTAssertTrue(container.eventStoreManager.sessionExists("sess-remote-deep-link"))
    }

    func testCreatedSessionIsPublishedBeforeCoordinatorReturns() async throws {
        try await container.initialize()
        let created = NewSessionCreated(
            sessionId: "sess-configured",
            workspaceId: "/tmp/tron-fixtures/configured",
            model: "test-model",
            workingDirectory: "/tmp/tron-fixtures/configured"
        )

        let publishedId = try await coordinator.publishCreatedSession(created)

        XCTAssertEqual(publishedId, created.sessionId)
        XCTAssertTrue(container.eventStoreManager.sessionExists(created.sessionId))
    }

    private static func serverSessionInfo(id: String) -> SessionInfo {
        SessionInfo(
            sessionId: id,
            model: "test-model",
            createdAt: "2026-08-06T00:00:00Z",
            eventCount: 0,
            turnCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0,
            lastActivity: "2026-08-06T00:00:00Z",
            isActive: false,
            isArchived: false,
            workingDirectory: "/tmp/tron-fixtures/deep-link",
            parentSessionId: nil,
            title: nil,
            lastUserPrompt: nil,
            lastAssistantResponse: nil,
            isRunning: false,
            activityLines: nil
        )
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
                scrollTarget: .toolInvocation(id: "cap_123")
            ),
            PendingSessionDeepLink(
                sessionId: "sess_pending",
                scrollTarget: .toolInvocation(id: "cap_123")
            )
        )
    }
}

// MARK: - Compact Session Presentation

final class CompactSessionRouteTests: XCTestCase {
    func testNilSessionHasNoRoute() {
        XCTAssertNil(makeCompactSessionRoute(sessionId: nil))
    }

    func testRepeatedOpenGetsFreshPresentationIdentity() throws {
        let first = try XCTUnwrap(makeCompactSessionRoute(sessionId: "sess_repeat"))
        let second = try XCTUnwrap(makeCompactSessionRoute(sessionId: "sess_repeat"))

        XCTAssertEqual(first.sessionId, second.sessionId)
        XCTAssertNotEqual(first.presentationId, second.presentationId)
        XCTAssertNotEqual(first, second)
    }

    func testChatIdentityChangesWhenServerSelectionChanges() {
        let first = ChatSessionPresentationIdentity(
            sessionId: "same-session-id",
            serverSelectionVersion: 1
        )
        let second = ChatSessionPresentationIdentity(
            sessionId: "same-session-id",
            serverSelectionVersion: 2
        )

        XCTAssertNotEqual(first, second)
    }
}

final class SettingsServerLoadKeyTests: XCTestCase {
    func testConnectionAndServerGenerationOwnOneSettingsLoadIdentity() {
        let initial = SettingsServerLoadKey(
            serverSelectionVersion: 1,
            continuity: EngineConnectionContinuity(
                state: .disconnected,
                generation: 0
            )
        )
        XCTAssertNotEqual(
            initial,
            SettingsServerLoadKey(
                serverSelectionVersion: 1,
                continuity: EngineConnectionContinuity(
                    state: .connected,
                    generation: 1
                )
            )
        )
        XCTAssertNotEqual(
            initial,
            SettingsServerLoadKey(
                serverSelectionVersion: 2,
                continuity: EngineConnectionContinuity(
                    state: .disconnected,
                    generation: 0
                )
            )
        )
        XCTAssertNotEqual(
            SettingsServerLoadKey(
                serverSelectionVersion: 1,
                continuity: EngineConnectionContinuity(
                    state: .connected,
                    generation: 1
                )
            ),
            SettingsServerLoadKey(
                serverSelectionVersion: 1,
                continuity: EngineConnectionContinuity(
                    state: .connected,
                    generation: 2
                )
            )
        )
    }
}

// MARK: - resolveQuickSessionWorkspace (Pure Function Tests)

/// Tests for the workspace resolution logic used by createQuickSession.
/// This is a free function — no coordinator or DI needed.
@MainActor
final class ResolveQuickSessionWorkspaceTests: XCTestCase {

    private let defaultWorkspace = "/tmp/tron-fixtures/default/workspace"

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

    // MARK: - Current Session Selection

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

    // MARK: - Most Recent Session Selection

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

    // MARK: - Final Default Selection

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
