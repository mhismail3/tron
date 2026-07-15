import XCTest
@testable import TronMobile

/// Tests for EventStoreManager-related types and data structures
/// Note: EventStoreManager integration tests require actual instances since it uses concrete types.
/// These tests focus on the supporting data structures and types.
@MainActor
final class CachedSessionTests: XCTestCase {
    private var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "event-store-manager")
        testState.registerTeardown(with: self)
    }

    override func tearDown() async throws {
        await testState.cleanup()
        testState = nil
    }

    func testCachedSessionIdentifiable() {
        let session = createTestSession(id: "test-123")
        XCTAssertEqual(session.id, "test-123")
    }

    func testCachedSessionDisplayTitle() {
        // Session with title
        let sessionWithTitle = createTestSession(id: "s1", title: "My Project")
        XCTAssertEqual(sessionWithTitle.displayTitle, "My Project")

        // Session without title uses working directory
        let sessionNoTitle = createTestSession(id: "s2", title: nil, workingDirectory: "/tmp/tron-fixtures/test/project")
        XCTAssertEqual(sessionNoTitle.displayTitle, "project")
    }

    func testCachedSessionIsArchived() {
        // Non-archived session (no archivedAt)
        let activeSession = createTestSession(id: "s1", archivedAt: nil)
        XCTAssertFalse(activeSession.isArchived)

        // Archived session
        let archivedSession = createTestSession(id: "s2", archivedAt: "2024-01-01T00:00:00Z")
        XCTAssertTrue(archivedSession.isArchived)
    }

    func testCachedSessionTokenCounts() {
        let session = createTestSession(
            id: "s1",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheCreationTokens: 100
        )

        XCTAssertEqual(session.inputTokens, 1000)
        XCTAssertEqual(session.outputTokens, 500)
        XCTAssertEqual(session.cacheReadTokens, 200)
        XCTAssertEqual(session.cacheCreationTokens, 100)
    }

    func testLocalNewSessionCacheDoesNotPromoteWorkspaceNameToTitle() {
        let session = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "new-local-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: nil,
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(session.title)
        XCTAssertEqual(session.workingDirectory, "/tmp/tron-fixtures/Project")
        XCTAssertEqual(session.listTitle, "New Session")
    }

    func testChatLocalNewSessionCacheKeepsAcceptedChatTitle() {
        let session = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "chat-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: "chat",
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(session.title, "Chat")
        XCTAssertEqual(session.source, "chat")
        XCTAssertEqual(session.listTitle, "New Session")
    }

    func testLocalForkCacheDoesNotPromoteWorkspaceNameToTitle() {
        let untitledSource = createTestSession(
            id: "untitled-source-session",
            title: nil,
            workingDirectory: "/tmp/tron-fixtures/ForkWorkspace"
        )

        let untitledFork = EventStoreManager.makeLocalForkSessionCache(
            result: SessionForkResult(
                newSessionId: "untitled-forked-session",
                forkedFromEventId: "source-event",
                forkedFromSessionId: "untitled-source-session",
                rootEventId: "fork-root"
            ),
            sourceSession: untitledSource,
            now: "2026-06-23T12:05:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(untitledFork.title)
        XCTAssertEqual(untitledFork.workingDirectory, "/tmp/tron-fixtures/ForkWorkspace")
        XCTAssertEqual(untitledFork.listTitle, "New Session")

        var sourceWithPrompt = createTestSession(
            id: "source-session",
            title: nil,
            workingDirectory: "/tmp/tron-fixtures/ForkWorkspace"
        )
        sourceWithPrompt.lastUserPrompt = "Summarize the cache audit finding"
        sourceWithPrompt.lastAssistantResponse = "Working on it"
        sourceWithPrompt.source = nil
        sourceWithPrompt.profile = "default"

        let promptTitleFork = EventStoreManager.makeLocalForkSessionCache(
            result: SessionForkResult(
                newSessionId: "forked-session",
                forkedFromEventId: "source-event",
                forkedFromSessionId: "source-session",
                rootEventId: "fork-root"
            ),
            sourceSession: sourceWithPrompt,
            now: "2026-06-23T12:05:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(promptTitleFork.title)
        XCTAssertEqual(promptTitleFork.workingDirectory, "/tmp/tron-fixtures/ForkWorkspace")
        XCTAssertEqual(promptTitleFork.lastUserPrompt, "Summarize the cache audit finding")
        XCTAssertEqual(promptTitleFork.profile, "default")
        XCTAssertEqual(promptTitleFork.listTitle, "Summarize the cache audit finding")
    }

    func testServerGeneratedTitleReplacesLocalPlaceholderDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        let existing = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "new-local-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: nil,
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: "Fix session list title placeholder",
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(merged.title, "Fix session list title placeholder")
        XCTAssertEqual(merged.listTitle, "Fix session list title placeholder")
    }

    func testServerGeneratedTitleReplacesCachedWorkspaceTitleDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        let existing = createTestSession(
            id: "cached-title-session",
            title: "Project",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: "Fix session list title placeholder",
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(merged.title, "Fix session list title placeholder")
        XCTAssertEqual(merged.listTitle, "Fix session list title placeholder")
    }

    func testNilServerTitleUsesLocalNewSessionPlaceholderDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        let existing = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "new-local-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: nil,
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.listTitle, "New Session")
    }

    func testNilServerTitleClearsCachedWorkspaceTitleDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        let existing = createTestSession(
            id: "cached-title-session",
            title: "Project",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.listTitle, "New Session")
    }

    func testNilServerTitleClearsCachedTitleAndUsesPromptTitleDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        let existing = createTestSession(
            id: "cached-title-session",
            title: "Project",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory,
            lastUserPrompt: "Review cache title sync"
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.lastUserPrompt, "Review cache title sync")
        XCTAssertEqual(merged.listTitle, "Review cache title sync")
    }

    func testNilServerTitleClearsCachedLocalTitleDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: engineClient,
            defaults: testState.defaults
        )
        let existing = createTestSession(
            id: "local-title-session",
            title: "Accepted generated title",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.listTitle, "New Session")
    }

    func testIdleGlobalSubscriptionDoesNotRetainManager() async {
        let stream = ControlledGlobalEventStream()
        let client = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65523/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        weak var weakManager: EventStoreManager?
        var manager: EventStoreManager? = EventStoreManager(
            eventDB: testState.makeDatabase(fileName: "idle-release.db"),
            engineClient: client,
            defaults: testState.defaults,
            globalEventStream: { _ in stream.stream }
        )
        weakManager = manager

        manager = nil

        XCTAssertNil(weakManager)
        stream.finish()
    }

    func testShutdownWaitsForAcceptedEventAndIsIdempotent() async {
        let stream = ControlledGlobalEventStream()
        let gate = AcceptedEventGate()
        let completion = AsyncCompletionProbe()
        let client = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65522/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        let manager = EventStoreManager(
            eventDB: testState.makeDatabase(fileName: "accepted-drain.db"),
            engineClient: client,
            defaults: testState.defaults,
            globalEventStream: { _ in stream.stream },
            acceptedEventHook: { _ in await gate.suspendAcceptedEvent() }
        )

        stream.send(.unknown("accepted.event"))
        await gate.waitUntilAccepted()
        let shutdown = Task { @MainActor in
            await manager.shutdown()
            await completion.markComplete()
        }
        await Task.yield()
        let completedBeforeRelease = await completion.isComplete
        XCTAssertFalse(completedBeforeRelease)

        await gate.releaseAcceptedEvent()
        await shutdown.value
        let completedAfterRelease = await completion.isComplete
        XCTAssertTrue(completedAfterRelease)
        async let repeatedA: Void = manager.shutdown()
        async let repeatedB: Void = manager.shutdown()
        _ = await (repeatedA, repeatedB)
    }

    func testRapidClientReplacementAcceptsOnlyLatestLane() async {
        let clientA = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65521/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        let clientB = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65520/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        let clientC = EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:65519/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        let streams = GlobalEventStreamFactory()
        streams.install(clientA)
        streams.install(clientB)
        streams.install(clientC)
        let accepted = AcceptedEventCapture()
        let manager = EventStoreManager(
            eventDB: testState.makeDatabase(fileName: "replacement-chain.db"),
            engineClient: clientA,
            defaults: testState.defaults,
            globalEventStream: streams.stream,
            acceptedEventHook: { event in await accepted.record(event.eventType) }
        )

        manager.updateEngineClient(clientB)
        manager.updateEngineClient(clientC)
        streams.send(.unknown("old-a"), to: clientA)
        streams.send(.unknown("intermediate-b"), to: clientB)
        streams.send(.unknown("latest-c"), to: clientC)
        await accepted.waitForCount(1)
        await manager.shutdown()

        let acceptedValues = await accepted.values
        XCTAssertEqual(acceptedValues, ["latest-c"])
        XCTAssertEqual(streams.subscriptionCount(for: clientA), 1)
        XCTAssertEqual(streams.subscriptionCount(for: clientB), 1)
        XCTAssertEqual(streams.subscriptionCount(for: clientC), 1)
    }

    func testRetiredClientRefreshDoesNotReconcileItsSnapshot() async throws {
        let database = testState.makeDatabase(fileName: "retired-refresh-success.db")
        try await database.initialize()
        let clientA = makeEngineClient(port: 65513)
        let clientB = makeEngineClient(port: 65512)
        let transportA = makeConnectedTransport(port: 65513)
        let transportB = makeConnectedTransport(port: 65512)
        clientA.session = SessionClient(transport: transportA)
        clientB.session = SessionClient(transport: transportB)

        var manager: EventStoreManager!
        var clientBReads = 0
        transportA.readHandler = { functionId, _, _ in
            guard functionId.rawValue == "session::list" else {
                throw EngineConnectionError.invalidResponse
            }
            manager.updateEngineClient(clientB)
            return SessionListResult(
                sessions: [self.makeSessionInfo(sessionId: "session-from-a", title: "A", workingDirectory: "/a")],
                totalCount: 1,
                hasMore: false,
                nextCursor: nil,
                snapshotAsOf: "2026-07-14T12:00:00Z",
                snapshotCanReconcile: true
            )
        }
        transportB.readHandler = { _, _, _ in
            clientBReads += 1
            throw EngineConnectionError.invalidResponse
        }
        manager = EventStoreManager(
            eventDB: database,
            engineClient: clientA,
            defaults: testState.defaults
        )

        await manager.refreshSessionList()

        let retiredSession = try await database.sessions.get("session-from-a")
        XCTAssertNil(retiredSession)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(clientBReads, 0)
        await manager.shutdown()
    }

    func testRetiredClientRefreshErrorDoesNotRegisterRetryOnReplacement() async throws {
        let database = testState.makeDatabase(fileName: "retired-refresh-error.db")
        try await database.initialize()
        let clientA = makeEngineClient(port: 65511)
        let clientB = makeEngineClient(port: 65510)
        let transportA = makeConnectedTransport(port: 65511)
        let transportB = makeConnectedTransport(port: 65510)
        clientA.session = SessionClient(transport: transportA)
        clientB.session = SessionClient(transport: transportB)
        let connectionProvider = MockConnectionStateProvider()
        connectionProvider.connectionState = .connected
        let connectionManager = ConnectionManager(provider: connectionProvider)

        var manager: EventStoreManager!
        var clientBReads = 0
        transportA.readHandler = { _, _, _ in
            manager.updateEngineClient(clientB)
            throw EngineConnectionError.notConnected
        }
        transportB.readHandler = { _, _, _ in
            clientBReads += 1
            return SessionListResult(
                sessions: [],
                totalCount: 0,
                hasMore: false,
                nextCursor: nil,
                snapshotAsOf: "2026-07-14T12:00:00Z",
                snapshotCanReconcile: true
            )
        }
        manager = EventStoreManager(
            eventDB: database,
            engineClient: clientA,
            defaults: testState.defaults
        )
        manager.attachConnectionManager(connectionManager)

        await manager.refreshSessionList()
        connectionProvider.connectionState = .reconnecting(attempt: 1, nextRetrySeconds: 0)
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(connectionManager.state.isReconnecting)
        connectionProvider.connectionState = .connected
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(connectionManager.state, .connected)
        XCTAssertEqual(clientBReads, 0)
        await manager.shutdown()
    }

    func testRefreshPublishesServerProcessingUnlessNewerLiveStateWins() async throws {
        let database = testState.makeDatabase(fileName: "refresh-processing-order.db")
        try await database.initialize()
        let client = makeEngineClient(port: 65509)
        let transport = makeConnectedTransport(port: 65509)
        client.session = SessionClient(transport: transport)
        let sessionA = "processing-order-a"
        let sessionB = "processing-order-b"
        var cachedA = createTestSession(id: sessionA)
        var cachedB = createTestSession(id: sessionB)
        cachedA.serverOrigin = client.serverOrigin
        cachedB.serverOrigin = client.serverOrigin
        try await database.sessions.insert(cachedA)
        try await database.sessions.insert(cachedB)

        var serverIsRunning = [sessionA: true, sessionB: true]
        var sessionsWithoutProcessingState = Set<String>()
        var newerIdleSessionId: String?
        var manager: EventStoreManager!
        transport.readHandler = { functionId, _, _ in
            guard functionId.rawValue == "session::list" else {
                throw EngineConnectionError.invalidResponse
            }
            if let newerIdleSessionId {
                // The repeated false value is still newer than this in-flight snapshot.
                manager.setSessionProcessing(newerIdleSessionId, isProcessing: false)
            }
            return SessionListResult(
                sessions: [sessionA, sessionB].map { sessionId in
                    self.makeSessionInfo(
                        sessionId: sessionId,
                        title: "Processing order",
                        workingDirectory: "/processing-order",
                        isRunning: sessionsWithoutProcessingState.contains(sessionId)
                            ? nil
                            : serverIsRunning[sessionId] == true
                    )
                },
                totalCount: 2,
                hasMore: false,
                nextCursor: nil,
                snapshotAsOf: "2026-07-14T12:00:00Z",
                snapshotCanReconcile: true
            )
        }
        manager = EventStoreManager(
            eventDB: database,
            engineClient: client,
            defaults: testState.defaults
        )

        manager.setSessions([cachedA, cachedB])
        manager.loadSessions()

        await manager.refreshSessionList()
        var processingById = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0.isProcessing == true) })
        XCTAssertEqual(processingById[sessionA], true)
        XCTAssertEqual(processingById[sessionB], true)

        serverIsRunning = [sessionA: false, sessionB: false]
        await manager.refreshSessionList()
        processingById = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0.isProcessing == true) })
        XCTAssertEqual(processingById[sessionA], false)
        XCTAssertEqual(processingById[sessionB], false)

        serverIsRunning = [sessionA: true, sessionB: true]
        _ = manager.removeSessionLocally(sessionA)
        newerIdleSessionId = sessionA
        await manager.refreshSessionList()
        processingById = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0.isProcessing == true) })
        XCTAssertEqual(processingById[sessionA], false)
        XCTAssertEqual(processingById[sessionB], true)
        let persistedServerSnapshot = try await database.sessions.get(sessionA)
        XCTAssertEqual(persistedServerSnapshot?.isProcessing, true)

        newerIdleSessionId = nil
        sessionsWithoutProcessingState = [sessionA]
        await manager.refreshSessionList()
        processingById = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0.isProcessing == true) })
        XCTAssertEqual(processingById[sessionA], false)
        XCTAssertEqual(processingById[sessionB], true)

        sessionsWithoutProcessingState = []
        await manager.refreshSessionList()
        processingById = Dictionary(uniqueKeysWithValues: manager.sessions.map { ($0.id, $0.isProcessing == true) })
        XCTAssertEqual(processingById[sessionA], true)
        XCTAssertEqual(processingById[sessionB], true)
        await manager.shutdown()
    }

    func testCancellingRefreshLoadPreventsPublication() async throws {
        let database = testState.makeDatabase(fileName: "cancelled-refresh-load.db")
        try await database.initialize()
        let client = makeEngineClient(port: 65508)
        let sessionId = "cancelled-refresh-load"
        var cachedSession = createTestSession(id: sessionId)
        cachedSession.serverOrigin = client.serverOrigin
        try await database.sessions.insert(cachedSession)
        let manager = EventStoreManager(
            eventDB: database,
            engineClient: client,
            defaults: testState.defaults
        )

        let initialLoadPublished = await manager.loadSessionsAfterRefresh(
            using: client,
            acceptingServerProcessingStateAt: manager.processingStateRevision,
            authoritativeProcessingSessionIds: [sessionId]
        )
        XCTAssertTrue(initialLoadPublished)
        XCTAssertEqual(manager.sessions.first?.isProcessing, false)

        cachedSession.isProcessing = true
        try await database.sessions.insert(cachedSession)
        let cancelledLoad = Task { @MainActor in
            await manager.loadSessionsAfterRefresh(
                using: client,
                acceptingServerProcessingStateAt: manager.processingStateRevision,
                authoritativeProcessingSessionIds: [sessionId]
            )
        }
        await Task.yield()
        cancelledLoad.cancel()

        let cancelledLoadPublished = await cancelledLoad.value
        XCTAssertFalse(cancelledLoadPublished)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(manager.sessions.first?.isProcessing, false)
        let persistedServerState = try await database.sessions.get(sessionId)
        XCTAssertEqual(persistedServerState?.isProcessing, true)
        await manager.shutdown()
    }

    func testIncrementalSyncKeepsInitiatingClientAndCommitsCompletedPage() async throws {
        let database = testState.makeDatabase(fileName: "captured-incremental-sync.db")
        try await database.initialize()
        try await database.sessions.insert(createTestSession(id: "session-a"))
        let clientA = makeEngineClient(port: 65518)
        let clientB = makeEngineClient(port: 65517)
        let transportA = makeConnectedTransport(port: 65518)
        let transportB = makeConnectedTransport(port: 65517)
        clientA.eventSync = EventSyncClient(transport: transportA)
        clientB.eventSync = EventSyncClient(transport: transportB)

        var manager: EventStoreManager!
        var clientAReads = 0
        var clientBReads = 0
        transportA.readHandler = { functionId, payload, _ in
            guard functionId.rawValue == "events::get_since",
                  let params = payload as? EventsGetSinceParams else {
                throw EngineConnectionError.invalidResponse
            }
            clientAReads += 1
            if clientAReads == 1 {
                XCTAssertNil(params.afterEventId)
                manager.updateEngineClient(clientB)
                return EventsGetSinceResult(
                    events: [self.makeRawEvent(id: "event-a-1", sessionId: "session-a", sequence: 1)],
                    nextCursor: nil,
                    hasMore: true
                )
            }
            XCTAssertEqual(params.afterEventId, "event-a-1")
            throw EngineConnectionError.invalidResponse
        }
        transportB.readHandler = { _, _, _ in
            clientBReads += 1
            throw EngineConnectionError.invalidResponse
        }
        manager = EventStoreManager(
            eventDB: database,
            engineClient: clientA,
            defaults: testState.defaults
        )

        do {
            try await manager.syncSessionEvents(sessionId: "session-a")
            XCTFail("Expected the second page to fail")
        } catch EngineConnectionError.invalidResponse {
            // The first page is already durable and must have matching metadata.
        }

        let events = try await database.events.getBySession("session-a")
        let syncState = try await database.sync.getState("session-a")
        let cachedSession = try await database.sessions.get("session-a")
        XCTAssertEqual(events.map(\.id), ["event-a-1"])
        XCTAssertEqual(syncState?.lastSyncedEventId, "event-a-1")
        XCTAssertEqual(cachedSession?.eventCount, 1)
        XCTAssertEqual(cachedSession?.headEventId, "event-a-1")
        XCTAssertEqual(clientAReads, 2)
        XCTAssertEqual(clientBReads, 0)
        await manager.shutdown()
    }

    func testFullSyncKeepsInitiatingClientForAncestorFetch() async throws {
        let database = testState.makeDatabase(fileName: "captured-full-sync.db")
        try await database.initialize()
        try await database.events.insert(
            makeSessionEvent(id: "stale-event", sessionId: "session-a", sequence: 0)
        )
        let clientA = makeEngineClient(port: 65516)
        let clientB = makeEngineClient(port: 65515)
        let transportA = makeConnectedTransport(port: 65516)
        let transportB = makeConnectedTransport(port: 65515)
        clientA.eventSync = EventSyncClient(transport: transportA)
        clientB.eventSync = EventSyncClient(transport: transportB)

        var manager: EventStoreManager!
        var clientAAncestorReads = 0
        var clientBReads = 0
        transportA.readHandler = { functionId, _, _ in
            switch functionId.rawValue {
            case "events::get_history":
                manager.updateEngineClient(clientB)
                return EventsGetHistoryResult(
                    events: [
                        self.makeRawEvent(
                            id: "fork-event-a",
                            parentId: "ancestor-a",
                            sessionId: "session-a",
                            sequence: 1
                        )
                    ],
                    hasMore: false,
                    oldestEventId: nil
                )
            case "tree::get_ancestors":
                clientAAncestorReads += 1
                return TreeGetAncestorsResult(
                    events: [
                        self.makeRawEvent(
                            id: "ancestor-a",
                            sessionId: "source-session-a",
                            sequence: 1
                        )
                    ]
                )
            default:
                throw EngineConnectionError.invalidResponse
            }
        }
        transportB.readHandler = { _, _, _ in
            clientBReads += 1
            throw EngineConnectionError.invalidResponse
        }
        manager = EventStoreManager(
            eventDB: database,
            engineClient: clientA,
            defaults: testState.defaults
        )

        try await manager.fullSyncSession("session-a")

        let staleEvent = try await database.events.get("stale-event")
        let forkEvent = try await database.events.get("fork-event-a")
        let ancestorEvent = try await database.events.get("ancestor-a")
        XCTAssertNil(staleEvent)
        XCTAssertNotNil(forkEvent)
        XCTAssertNotNil(ancestorEvent)
        XCTAssertEqual(clientAAncestorReads, 1)
        XCTAssertEqual(clientBReads, 0)
        await manager.shutdown()
    }

    func testFullSyncFetchFailurePreservesExistingProjection() async throws {
        let database = testState.makeDatabase(fileName: "full-sync-fetch-failure.db")
        try await database.initialize()
        let existingEvent = makeSessionEvent(
            id: "existing-event",
            sessionId: "session-a",
            sequence: 1
        )
        let existingSyncState = SyncState(
            key: "session-a",
            lastSyncedEventId: existingEvent.id,
            lastSyncTimestamp: "2026-07-14T12:00:00Z",
            pendingEventIds: []
        )
        try await database.events.insert(existingEvent)
        try await database.sync.update(existingSyncState)
        let client = makeEngineClient(port: 65514)
        let transport = makeConnectedTransport(port: 65514)
        transport.readHandler = { _, _, _ in
            throw EngineConnectionError.invalidResponse
        }
        client.eventSync = EventSyncClient(transport: transport)
        let synchronizer = SessionSynchronizer(eventDB: database)

        do {
            _ = try await synchronizer.fullSync(sessionId: "session-a", using: client)
            XCTFail("Expected the server fetch to fail")
        } catch EngineConnectionError.invalidResponse {
            // Expected: the last usable local projection remains intact.
        }

        let retainedEvent = try await database.events.get("existing-event")
        XCTAssertEqual(retainedEvent?.id, existingEvent.id)
        XCTAssertEqual(retainedEvent?.sessionId, existingEvent.sessionId)
        let retainedSyncState = try await database.sync.getState("session-a")
        XCTAssertEqual(retainedSyncState?.lastSyncedEventId, existingEvent.id)
        XCTAssertEqual(retainedSyncState?.lastSyncTimestamp, existingSyncState.lastSyncTimestamp)
    }

    // MARK: - Helper

    private func makeEngineClient(port: Int) -> EngineClient {
        EngineClient(
            serverURL: URL(string: "ws://127.0.0.1:\(port)/engine")!,
            sessionAttemptDirective: { _ in .handledFailure }
        )
    }

    private func makeConnectedTransport(port: Int) -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(
            serverURL: URL(string: "ws://127.0.0.1:\(port)/engine")!
        )
        transport.connectionState = .connected
        transport.serverOrigin = "127.0.0.1:\(port)"
        return transport
    }

    private func makeRawEvent(
        id: String,
        parentId: String? = nil,
        sessionId: String,
        sequence: Int
    ) -> RawEvent {
        RawEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/tmp/tron-fixtures/workspace",
            type: "message.user",
            timestamp: "2026-07-14T12:00:00Z",
            sequence: sequence,
            payload: [:]
        )
    }

    private func makeSessionEvent(id: String, sessionId: String, sequence: Int) -> SessionEvent {
        SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "/tmp/tron-fixtures/workspace",
            type: "message.user",
            timestamp: "2026-07-14T12:00:00Z",
            sequence: sequence,
            payload: [:]
        )
    }

    private func createTestSession(
        id: String,
        title: String? = nil,
        workingDirectory: String = "/test/dir",
        archivedAt: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) -> CachedSession {
        return CachedSession(
            id: id,
            workspaceId: "/test/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: title,
            latestModel: "claude-sonnet-4-20250514",
            workingDirectory: workingDirectory,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastActivityAt: ISO8601DateFormatter().string(from: Date()),
            archivedAt: archivedAt,
            eventCount: 0,
            messageCount: 0,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            lastTurnInputTokens: 0,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cost: 0.0,
            isProcessing: false,
            isFork: false
        )
    }

    private func makeSessionInfo(
        sessionId: String,
        title: String?,
        workingDirectory: String?,
        lastUserPrompt: String? = nil,
        isRunning: Bool? = false
    ) -> SessionInfo {
        SessionInfo(
            sessionId: sessionId,
            model: "gpt-5",
            createdAt: "2026-06-23T12:00:00Z",
            eventCount: 0,
            turnCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0,
            lastActivity: "2026-06-23T12:10:00Z",
            isActive: false,
            isArchived: false,
            workingDirectory: workingDirectory,
            parentSessionId: nil,
            title: title,
            lastUserPrompt: lastUserPrompt,
            lastAssistantResponse: nil,
            source: nil,
            profile: nil,
            isRunning: isRunning,
            activityLines: nil
        )
    }
}

@MainActor
private final class ControlledGlobalEventStream {
    let stream: AsyncStream<ParsedEventV2>
    private let continuation: AsyncStream<ParsedEventV2>.Continuation

    init() {
        var captured: AsyncStream<ParsedEventV2>.Continuation!
        stream = AsyncStream { captured = $0 }
        continuation = captured
    }

    func send(_ event: ParsedEventV2) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

@MainActor
private final class GlobalEventStreamFactory {
    private var streams: [ObjectIdentifier: ControlledGlobalEventStream] = [:]
    private var subscriptions: [ObjectIdentifier: Int] = [:]

    func install(_ client: EngineClient) {
        streams[ObjectIdentifier(client)] = ControlledGlobalEventStream()
    }

    func stream(for client: EngineClient) -> AsyncStream<ParsedEventV2> {
        let key = ObjectIdentifier(client)
        subscriptions[key, default: 0] += 1
        return streams[key]!.stream
    }

    func send(_ event: ParsedEventV2, to client: EngineClient) {
        streams[ObjectIdentifier(client)]?.send(event)
    }

    func subscriptionCount(for client: EngineClient) -> Int {
        subscriptions[ObjectIdentifier(client), default: 0]
    }
}

private actor AcceptedEventGate {
    private var accepted = false
    private var acceptedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendAcceptedEvent() async {
        accepted = true
        acceptedWaiters.forEach { $0.resume() }
        acceptedWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilAccepted() async {
        if accepted { return }
        await withCheckedContinuation { acceptedWaiters.append($0) }
    }

    func releaseAcceptedEvent() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor AsyncCompletionProbe {
    private(set) var isComplete = false

    func markComplete() {
        isComplete = true
    }
}

private actor AcceptedEventCapture {
    private var captured: [String] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ value: String) {
        captured.append(value)
        let ready = waiters.filter { captured.count >= $0.0 }
        waiters.removeAll { captured.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitForCount(_ count: Int) async {
        if captured.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    var values: [String] { captured }
}

// MARK: - SyncState Tests

@MainActor
final class SyncStateTests: XCTestCase {

    func testSyncStateInitialization() {
        let state = SyncState(
            key: "session-123",
            lastSyncedEventId: "event-456",
            lastSyncTimestamp: "2024-01-01T00:00:00Z",
            pendingEventIds: ["e1", "e2"]
        )

        XCTAssertEqual(state.key, "session-123")
        XCTAssertEqual(state.lastSyncedEventId, "event-456")
        XCTAssertEqual(state.pendingEventIds.count, 2)
    }

    func testSyncStateWithNilValues() {
        let state = SyncState(
            key: "session-123",
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )

        XCTAssertNil(state.lastSyncedEventId)
        XCTAssertNil(state.lastSyncTimestamp)
        XCTAssertTrue(state.pendingEventIds.isEmpty)
    }
}

// MARK: - SessionEvent Tests

@MainActor
final class SessionEventTests: XCTestCase {

    func testSessionEventCreation() {
        let event = SessionEvent(
            id: "event-1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "message.user",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: ["content": AnyCodable("Hello")]
        )

        XCTAssertEqual(event.id, "event-1")
        XCTAssertNil(event.parentId)
        XCTAssertEqual(event.sessionId, "session-1")
        XCTAssertEqual(event.type, "message.user")
        XCTAssertEqual(event.sequence, 1)
    }

    func testSessionEventWithParent() {
        let event = SessionEvent(
            id: "event-2",
            parentId: "event-1",
            sessionId: "session-1",
            workspaceId: "/test",
            type: "message.assistant",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 2,
            payload: [:]
        )

        XCTAssertEqual(event.parentId, "event-1")
    }

    func testSessionEventPayload() {
        let event = SessionEvent(
            id: "event-1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "capability.invocation.started",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "arguments": AnyCodable(["command": "ls -la"])
            ]
        )

        XCTAssertNotNil(event.payload["modelPrimitiveName"])
        XCTAssertNotNil(event.payload["arguments"])
    }
}
