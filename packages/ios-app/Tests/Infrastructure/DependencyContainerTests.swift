import XCTest
@testable import TronMobile

/// Tests for DependencyContainer
/// Uses shared container where possible to avoid expensive per-test initialization.
@MainActor
final class DependencyContainerTests: XCTestCase {

    // Shared container for read-only tests (avoids creating 25 containers)
    private static var sharedContainer: DependencyContainer!

    override class func setUp() {
        super.setUp()
        clearPairings()
        // Create ONE container for all read-only tests
        sharedContainer = DependencyContainer()
    }

    override class func tearDown() {
        sharedContainer = nil
        super.tearDown()
    }

    override func tearDown() {
        Self.clearPairings()
        super.tearDown()
    }

    private static func clearPairings() {
        UserDefaults.standard.removeObject(forKey: PairedServerStore.serversKey)
        UserDefaults.standard.removeObject(forKey: PairedServerStore.activeIdKey)
    }

    private func pairedContainer(
        id: String = "server",
        host: String = "localhost",
        port: Int = 8082
    ) -> (DependencyContainer, PairedServer) {
        Self.clearPairings()
        let server = PairedServer(id: id, label: "Test Server", host: host, port: port)
        let data = try! JSONEncoder().encode([server])
        UserDefaults.standard.set(data, forKey: PairedServerStore.serversKey)
        UserDefaults.standard.set(server.id, forKey: PairedServerStore.activeIdKey)
        return (DependencyContainer(), server)
    }

    // MARK: - Container Lifecycle Tests (use shared container)

    func test_container_providesRPCClient() async throws {
        XCTAssertNotNil(Self.sharedContainer.rpcClient)
        XCTAssert(Self.sharedContainer.rpcClient is RPCClient)
    }

    func test_container_providesEventDatabase() async throws {
        XCTAssertNotNil(Self.sharedContainer.eventDatabase)
        XCTAssert(Self.sharedContainer.eventDatabase is EventDatabase)
    }

    func test_container_providesSkillStore() async throws {
        XCTAssertNotNil(Self.sharedContainer.skillStore)
        XCTAssert(Self.sharedContainer.skillStore is SkillStore)
    }

    func test_container_providesEventStoreManager() async throws {
        XCTAssertNotNil(Self.sharedContainer.eventStoreManager)
        XCTAssert(Self.sharedContainer.eventStoreManager is EventStoreManager)
    }

    func test_container_providesDraftStore() async throws {
        XCTAssertNotNil(Self.sharedContainer.draftStore)
        XCTAssert(Self.sharedContainer.draftStore is DraftStore)
    }

    func test_container_providesPushNotificationService() async throws {
        XCTAssertNotNil(Self.sharedContainer.pushNotificationService)
        XCTAssert(Self.sharedContainer.pushNotificationService is PushNotificationService)
    }

    func test_container_providesDeepLinkRouter() async throws {
        XCTAssertNotNil(Self.sharedContainer.deepLinkRouter)
        XCTAssert(Self.sharedContainer.deepLinkRouter is DeepLinkRouter)
    }

    // MARK: - Singleton Behavior Tests (use shared container)

    func test_rpcClient_returnsSameInstance() async throws {
        let client1 = Self.sharedContainer.rpcClient
        let client2 = Self.sharedContainer.rpcClient

        XCTAssert(client1 === client2, "RPCClient should return same instance")
    }

    func test_eventDatabase_returnsSameInstance() async throws {
        let db1 = Self.sharedContainer.eventDatabase
        let db2 = Self.sharedContainer.eventDatabase

        XCTAssert(db1 === db2, "EventDatabase should return same instance")
    }

    func test_skillStore_returnsSameInstance() async throws {
        let store1 = Self.sharedContainer.skillStore
        let store2 = Self.sharedContainer.skillStore

        XCTAssert(store1 === store2, "SkillStore should return same instance")
    }

    func test_eventStoreManager_returnsSameInstance() async throws {
        let manager1 = Self.sharedContainer.eventStoreManager
        let manager2 = Self.sharedContainer.eventStoreManager

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
        Self.clearPairings()
        let container = DependencyContainer()

        XCTAssertEqual(container.currentServerOrigin, "")
        XCTAssertEqual(container.serverURL.host, "paired-server-required.invalid")
    }

    // MARK: - Active Server Update Tests

    func test_selectPairedServer_recreatesRPCClient() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19000)
        let originalClient = container.rpcClient
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19001)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssert(originalClient !== container.rpcClient, "RPC client should be recreated after settings change")
    }

    func test_selectPairedServer_preservesEventDatabase() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19002)
        let originalDB = container.eventDatabase
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19003)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssert(originalDB === container.eventDatabase, "EventDatabase should NOT be recreated after settings change")
    }

    func test_selectPairedServer_preservesPushNotificationService() async throws {
        let (container, first) = pairedContainer(host: "first.example.com", port: 19004)
        let originalService = container.pushNotificationService
        let second = PairedServer(id: "second", label: "Second", host: "second.example.com", port: 19005)
        container.replacePairedServers([first, second], activeServer: first)

        container.selectPairedServer(second, connectAfterSwitch: false)

        XCTAssert(originalService === container.pushNotificationService, "PushNotificationService should NOT be recreated")
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

    // MARK: - App Settings Tests (use shared container for read, fresh for write)

    func test_effectiveWorkingDirectory_fallsBackToDocuments() async throws {
        // Read-only test on shared container's default behavior
        let effective = Self.sharedContainer.effectiveWorkingDirectory
        XCTAssertFalse(effective.isEmpty)
    }

    func test_effectiveWorkingDirectory_usesWorkingDirectoryWhenSet() async throws {
        let container = DependencyContainer()
        let original = container.workingDirectory
        container.workingDirectory = "/custom/path"
        defer { container.workingDirectory = original }
        XCTAssertEqual(container.effectiveWorkingDirectory, "/custom/path")
    }

    // MARK: - Protocol Conformance Tests (use shared container - compile-time checks)

    func test_container_conformsToDependencyProviding() async throws {
        let _: any DependencyProviding = Self.sharedContainer
        XCTAssertTrue(true)
    }

    func test_container_conformsToServerSettingsProvider() async throws {
        let _: any ServerSettingsProvider = Self.sharedContainer
        XCTAssertTrue(true)
    }

    func test_container_conformsToAppSettingsProvider() async throws {
        let _: any AppSettingsProvider = Self.sharedContainer
        XCTAssertTrue(true)
    }

    // MARK: - Initialization Tests

    func test_container_startsNotInitialized() async throws {
        // Fresh container needed to test initial state
        let container = DependencyContainer()
        XCTAssertFalse(container.isInitialized)
    }

    // MARK: - Telemetry Client Wiring (Phase 7)

    /// The container must initialize `telemetryClient` from the persisted
    /// opt-in (default OFF) on every fresh build. Other call sites depend
    /// on this being non-nil immediately after init — there's no second
    /// "telemetry-ready" hook.
    func test_telemetryClient_initializedFromPersistedOptIn_off() async throws {
        UserDefaults.standard.set(false, forKey: SettingsState.telemetryEnabledStorageKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsState.telemetryEnabledStorageKey) }

        let container = DependencyContainer()
        XCTAssertNotNil(container.telemetryClient)
        XCTAssertFalse(
            container.telemetryClient.isEnabled,
            "Telemetry default is OFF — container should hand out a Null client"
        )
    }

    /// Toggling `telemetryEnabled` mid-session should rebuild the client
    /// (no app restart). The rebuild fires through
    /// `UserDefaults.didChangeNotification` posted to the main queue.
    /// We poll briefly because notification delivery is asynchronous.
    func test_telemetryClient_rebuildsOnPersistedToggle() async throws {
        UserDefaults.standard.set(false, forKey: SettingsState.telemetryEnabledStorageKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsState.telemetryEnabledStorageKey) }

        let container = DependencyContainer()
        let before = ObjectIdentifier(container.telemetryClient as AnyObject)

        UserDefaults.standard.set(true, forKey: SettingsState.telemetryEnabledStorageKey)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline,
              ObjectIdentifier(container.telemetryClient as AnyObject) == before {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNotEqual(
            ObjectIdentifier(container.telemetryClient as AnyObject),
            before,
            "Toggling telemetry on should rebuild the client without an app restart"
        )
    }

    /// Writing the same value (or any other UserDefaults key) must NOT
    /// rebuild the client — that would tear up the live sink on every
    /// `@AppStorage` write across the app.
    func test_telemetryClient_doesNotRebuildOnUnrelatedDefaultsChange() async throws {
        UserDefaults.standard.set(false, forKey: SettingsState.telemetryEnabledStorageKey)
        defer { UserDefaults.standard.removeObject(forKey: SettingsState.telemetryEnabledStorageKey) }

        let container = DependencyContainer()
        let before = ObjectIdentifier(container.telemetryClient as AnyObject)

        // Touch an unrelated key that the container's notification
        // observer will see flying past.
        let canaryKey = "test_telemetry_canary_\(UUID().uuidString)"
        UserDefaults.standard.set("ignored", forKey: canaryKey)
        defer { UserDefaults.standard.removeObject(forKey: canaryKey) }

        // Give the main queue a chance to drain any pending notifications.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            ObjectIdentifier(container.telemetryClient as AnyObject),
            before,
            "Unrelated defaults writes must not rebuild the telemetry client"
        )
    }

}
