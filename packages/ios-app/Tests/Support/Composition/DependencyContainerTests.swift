import XCTest
@testable import TronMobile

/// Tests for DependencyContainer
/// Every container uses an isolated pairing domain so tests cannot mutate the
/// installed app's active server or depend on test execution order.
@MainActor
final class DependencyContainerTests: XCTestCase {
    private var testState: IsolatedTestState!
    private var sharedContainer: DependencyContainer!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "dependency-container")
        testState.registerTeardown(with: self)
        sharedContainer = testState.makeContainer()
    }

    override func tearDown() async throws {
        sharedContainer = nil
        await testState.cleanup()
    }

    private func pairedContainer(
        id: String = "server",
        host: String = "localhost",
        port: Int = 8082
    ) -> (DependencyContainer, PairedServer) {
        let defaults = testState.defaults
        let server = PairedServer(id: id, label: "Test Server", host: host, port: port)
        let data = try! JSONEncoder().encode([server])
        defaults.set(data, forKey: PairedServerStore.serversKey)
        defaults.set(server.id, forKey: PairedServerStore.activeIdKey)
        return (testState.makeContainer(), server)
    }

    private func yieldUntilAttempt(
        _ recorder: HostedEngineAttemptRecorder,
        exceeds count: Int
    ) async {
        for _ in 0..<100 where recorder.requests.count <= count {
            await Task.yield()
        }
    }

    private func drainScheduledTasks() async {
        for _ in 0..<100 {
            await Task.yield()
        }
    }

    // MARK: - Container Lifecycle Tests (use shared container)

    func test_container_providesEngineClient() async throws {
        XCTAssertNotNil(sharedContainer.engineClient)
        XCTAssert(sharedContainer.engineClient is EngineClient)
    }

    func test_container_providesEventDatabase() async throws {
        XCTAssertNotNil(sharedContainer.eventDatabase)
        XCTAssert(sharedContainer.eventDatabase is EventDatabase)
    }

    func test_container_providesEventStoreManager() async throws {
        XCTAssertNotNil(sharedContainer.eventStoreManager)
        XCTAssert(sharedContainer.eventStoreManager is EventStoreManager)
    }

    func test_container_providesDraftStore() async throws {
        XCTAssertNotNil(sharedContainer.draftStore)
        XCTAssert(sharedContainer.draftStore is DraftStore)
    }

    func test_container_providesDeepLinkRouter() async throws {
        XCTAssertNotNil(sharedContainer.deepLinkRouter)
        XCTAssert(sharedContainer.deepLinkRouter is DeepLinkRouter)
    }

    // MARK: - Singleton Behavior Tests (use shared container)

    func test_engineClient_returnsSameInstance() async throws {
        let client1 = sharedContainer.engineClient
        let client2 = sharedContainer.engineClient

        XCTAssert(client1 === client2, "EngineClient should return same instance")
    }

    func test_eventDatabase_returnsSameInstance() async throws {
        let db1 = sharedContainer.eventDatabase
        let db2 = sharedContainer.eventDatabase

        XCTAssert(db1 === db2, "EventDatabase should return same instance")
    }

    func test_eventStoreManager_returnsSameInstance() async throws {
        let manager1 = sharedContainer.eventStoreManager
        let manager2 = sharedContainer.eventStoreManager

        XCTAssert(manager1 === manager2, "EventStoreManager should return same instance")
    }

    // MARK: - Server Settings Tests
    // Note: These tests verify URL construction logic, not default values
    // (UserDefaults may have values from previous test runs)

    func test_serverURL_constructsCorrectlyWithoutTLS() async throws {
        let (container, _) = pairedContainer(host: "localhost", port: 8082)
        let url = container.serverURL

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 8082)
    }

    func test_currentServerOrigin_formatsCorrectly() async throws {
        let (container, _) = pairedContainer(host: "testhost", port: 9999)
        let origin = container.currentServerOrigin

        XCTAssertEqual(origin, "testhost:9999")
    }

    func test_noPairedServerDoesNotUseLocalhostFallback() async throws {
        let container = testState.makeContainer()

        XCTAssertEqual(container.currentServerOrigin, "")
        XCTAssertEqual(container.serverURL.host, "paired-server-required.invalid")
    }

    func test_hostedContainerRetryAndRepositoryAreHandledBeforeSocketCreation() async {
        let (container, _) = pairedContainer(host: "127.0.0.1", port: 65528)
        let recorder = testState.attemptRecorders.last!

        await container.manualRetry()
        await container.connectionRepository.disconnect()
        await container.connectionRepository.connect()
        await container.connectionRepository.disconnect()

        XCTAssertGreaterThanOrEqual(recorder.requests.count, 2)
        XCTAssertNil(container.engineClient.engineConnection?.urlSession)
        XCTAssertNil(container.engineClient.engineConnection?.engineConnectionTask)
        let pairingOutcome = await container.pairingProbe.probe(
            host: "hosted-tests.invalid",
            port: 1,
            token: "fixture"
        )
        XCTAssertEqual(pairingOutcome, .ok(serverVersion: nil))
    }

    func test_rebuiltClientPreservesHandledAttemptPolicy() async {
        let (container, first) = pairedContainer(host: "127.0.0.1", port: 65527)
        let recorder = testState.attemptRecorders.last!
        let second = PairedServer(id: "rebuilt", label: "Rebuilt", host: "127.0.0.1", port: 65526)

        container.replacePairedServers([first, second], activeServer: second)
        await container.connectionRepository.connect()

        XCTAssertEqual(recorder.requests.last?.url?.port, 65526)
        XCTAssertNil(container.engineClient.engineConnection?.urlSession)
        await container.connectionRepository.disconnect()
    }

    func test_defaultServerSwitchAndForgetNextServerRemainHandled() async throws {
        let first = PairedServer(id: "first-switch", label: "First", host: "127.0.0.1", port: 65525)
        let second = PairedServer(id: "second-switch", label: "Second", host: "127.0.0.1", port: 65524)
        let data = try JSONEncoder().encode([first, second])
        testState.defaults.set(data, forKey: PairedServerStore.serversKey)
        testState.defaults.set(first.id, forKey: PairedServerStore.activeIdKey)
        let container = testState.makeContainer()
        let recorder = testState.attemptRecorders.last!

        let beforeSwitch = recorder.requests.count
        container.selectPairedServer(second)
        await yieldUntilAttempt(recorder, exceeds: beforeSwitch)
        XCTAssertGreaterThan(recorder.requests.count, beforeSwitch)
        XCTAssertNil(container.engineClient.engineConnection?.urlSession)

        try container.pairedServerTokenStore.setToken("fixture", forServerId: second.id)
        let beforeForget = recorder.requests.count
        _ = try container.forgetPairedServer(second)
        await yieldUntilAttempt(recorder, exceeds: beforeForget)
        XCTAssertGreaterThan(recorder.requests.count, beforeForget)
        XCTAssertEqual(container.pairedServerStore.activeServerId, first.id)
        XCTAssertNil(container.engineClient.engineConnection?.urlSession)
        await container.connectionRepository.disconnect()
    }

    func test_supersededAutoConnectCannotConnectNoConnectGeneration() async throws {
        let first = PairedServer(id: "generation-a", label: "A", host: "127.0.0.1", port: 65523)
        let second = PairedServer(id: "generation-b", label: "B", host: "127.0.0.1", port: 65522)
        let third = PairedServer(id: "generation-c", label: "C", host: "127.0.0.1", port: 65521)
        let data = try JSONEncoder().encode([first, second, third])
        testState.defaults.set(data, forKey: PairedServerStore.serversKey)
        testState.defaults.set(first.id, forKey: PairedServerStore.activeIdKey)
        let container = testState.makeContainer()
        let recorder = testState.attemptRecorders.last!
        let attemptsBeforeSwitch = recorder.requests.count

        container.selectPairedServer(second)
        container.selectPairedServer(third, connectAfterSwitch: false)
        await drainScheduledTasks()

        XCTAssertEqual(container.pairedServerStore.activeServerId, third.id)
        XCTAssertEqual(container.engineClient.serverOrigin, third.origin)
        XCTAssertEqual(recorder.requests.count, attemptsBeforeSwitch)
    }

    func test_serverSwitchRetiresReplacedClientBeforeInstallingReplacement() async {
        let (container, first) = pairedContainer(host: "127.0.0.1", port: 65505)
        let replacedClient = container.engineClient
        await replacedClient.connect()
        XCTAssertNotNil(replacedClient.engineConnection)

        let second = PairedServer(
            id: "replacement",
            label: "Replacement",
            host: "127.0.0.1",
            port: 65504
        )
        container.replacePairedServers([first, second], activeServer: second)

        XCTAssertNil(replacedClient.engineConnection)
        XCTAssertEqual(replacedClient.connectionState, .disconnected)
        XCTAssert(container.engineClient !== replacedClient)
    }

    // MARK: - Active Server Update Tests

    func test_selectPairedServer_recreatesEngineClient() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19000)
        let originalClient = container.engineClient
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19001)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssert(originalClient !== container.engineClient, "engine client should be recreated after settings change")
    }

    func test_selectPairedServer_preservesEventDatabase() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19002)
        let originalDB = container.eventDatabase
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19003)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssert(originalDB === container.eventDatabase, "EventDatabase should NOT be recreated after settings change")
    }

    func test_selectPairedServer_preservesDeepLinkRouter() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19006)
        let originalRouter = container.deepLinkRouter
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19007)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssert(originalRouter === container.deepLinkRouter, "DeepLinkRouter should NOT be recreated")
    }

    func test_selectPairedServer_incrementsVersion() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19008)
        let originalVersion = container.activeServerSelectionVersion
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19009)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssertEqual(container.activeServerSelectionVersion, originalVersion + 2, "activeServerSelectionVersion should increment for replace and select")
    }

    func test_selectPairedServer_noChangeDoesNotIncrementVersion() async throws {
        let (container, server) = pairedContainer(host: "same.example.com", port: 19010)
        let originalVersion = container.activeServerSelectionVersion

        container.selectPairedServer(server)

        XCTAssertEqual(container.activeServerSelectionVersion, originalVersion, "Version should NOT increment when unchanged")
    }

    func test_selectPairedServer_updatesServerURL() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19011)
        let second = PairedServer(id: "second", label: "Second", host: "newhost.example.com", port: 19012)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        let url = container.serverURL
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertTrue(url.host?.contains("newhost") ?? false)
    }

    func test_forgetPairedServer_removesTokenBeforeMetadataCompletes() async throws {
        let id = "forget-\(UUID().uuidString)"
        let (container, server) = pairedContainer(id: id, host: "forget.example.com", port: 19013)
        try container.pairedServerTokenStore.setToken("tok-forget", forServerId: server.id)
        defer { try? container.pairedServerTokenStore.remove(serverId: server.id) }

        let plan = try container.forgetPairedServer(server)

        XCTAssertTrue(plan.removedWasActive)
        XCTAssertTrue(plan.shouldReturnToOnboarding)
        XCTAssertNil(container.pairedServerTokenStore.token(forServerId: server.id))
        XCTAssertFalse(container.pairedServerStore.servers.contains(where: { $0.id == server.id }))
        XCTAssertNil(container.pairedServerStore.activeServerId)
    }

    // MARK: - App Settings Tests (use shared container for read, fresh for write)

    func test_effectiveWorkingDirectory_fallsBackToDocuments() async throws {
        // Read-only test on shared container's default behavior
        let effective = sharedContainer.effectiveWorkingDirectory
        XCTAssertFalse(effective.isEmpty)
    }

    func test_effectiveWorkingDirectory_usesWorkingDirectoryWhenSet() async throws {
        let container = testState.makeContainer()
        container.workingDirectory = "/custom/path"
        XCTAssertEqual(container.effectiveWorkingDirectory, "/custom/path")
    }

    // MARK: - Protocol Conformance Tests (use shared container - compile-time checks)

    func test_container_conformsToDependencyProviding() async throws {
        let _: any DependencyProviding = sharedContainer
        XCTAssertTrue(true)
    }

    func test_container_conformsToServerSettingsProvider() async throws {
        let _: any ServerSettingsProvider = sharedContainer
        XCTAssertTrue(true)
    }

    func test_container_conformsToAppSettingsProvider() async throws {
        let _: any AppSettingsProvider = sharedContainer
        XCTAssertTrue(true)
    }

    // MARK: - Initialization Tests

    func test_container_startsNotInitialized() async throws {
        // Fresh container needed to test initial state
        let container = testState.makeContainer()
        XCTAssertFalse(container.isInitialized)
    }

    func test_storageOwnsDefaultsDocumentsDatabaseAndFallback() {
        let container = testState.makeContainer()
        container.workingDirectory = ""
        container.defaultModel = "fixture-model"
        container.quickSessionWorkspace = "/fixture/workspace"

        XCTAssertEqual(container.effectiveWorkingDirectory, testState.documentsURL.path)
        XCTAssertEqual(testState.defaults.string(forKey: "defaultModel"), "fixture-model")
        XCTAssertEqual(testState.defaults.string(forKey: "quickSessionWorkspace"), "/fixture/workspace")
        XCTAssertTrue(container.eventDatabase.dbPath.hasPrefix(testState.rootURL.path))
    }

    func test_productionStorageCanBeCharacterizedWithInjectedResolvers() {
        let database = testState.makeDatabase(fileName: "characterized.db")
        let storage = DependencyContainerStorage.production(
            defaults: { testState.defaults },
            documentsURL: { testState.documentsURL },
            eventDatabase: { database }
        )

        XCTAssertTrue(storage.defaults === testState.defaults)
        XCTAssertEqual(storage.documentsURL, testState.documentsURL)
        XCTAssertTrue(storage.eventDatabase === database)
    }

}
