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
        // Create ONE container for all read-only tests
        sharedContainer = DependencyContainer()
    }

    override class func tearDown() {
        sharedContainer = nil
        super.tearDown()
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
        // Test URL construction logic by setting known values
        let container = DependencyContainer()
        // Reset to known defaults
        container.updateServerSettings(host: "localhost", port: "8082", useTLS: false)
        let url = container.serverURL

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 8082)
    }

    func test_currentServerOrigin_formatsCorrectly() async throws {
        // Test origin formatting with known values
        let container = DependencyContainer()
        container.updateServerSettings(host: "testhost", port: "9999", useTLS: false)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }
        let origin = container.currentServerOrigin

        XCTAssertEqual(origin, "testhost:9999")
    }

    // MARK: - Server Settings Update Tests (need fresh container - modifies state)
    // Each test restores defaults after mutating, so UserDefaults don't leak
    // garbage values (like "newhost-36060.com") into the real app on the simulator.

    func test_updateServerSettings_recreatesRPCClient() async throws {
        let container = DependencyContainer()
        let originalClient = container.rpcClient

        container.updateServerSettings(host: "test-server.example.com", port: "19001", useTLS: true)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }

        XCTAssert(originalClient !== container.rpcClient, "RPC client should be recreated after settings change")
    }

    func test_updateServerSettings_preservesEventDatabase() async throws {
        let container = DependencyContainer()
        let originalDB = container.eventDatabase

        container.updateServerSettings(host: "test.example.com", port: "19002", useTLS: true)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }

        XCTAssert(originalDB === container.eventDatabase, "EventDatabase should NOT be recreated after settings change")
    }

    func test_updateServerSettings_preservesPushNotificationService() async throws {
        let container = DependencyContainer()
        let originalService = container.pushNotificationService

        container.updateServerSettings(host: "test.example.com", port: "19003", useTLS: true)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }

        XCTAssert(originalService === container.pushNotificationService, "PushNotificationService should NOT be recreated")
    }

    func test_updateServerSettings_preservesDeepLinkRouter() async throws {
        let container = DependencyContainer()
        let originalRouter = container.deepLinkRouter

        container.updateServerSettings(host: "test.example.com", port: "19004", useTLS: true)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }

        XCTAssert(originalRouter === container.deepLinkRouter, "DeepLinkRouter should NOT be recreated")
    }

    func test_updateServerSettings_incrementsVersion() async throws {
        let container = DependencyContainer()
        let originalVersion = container.serverSettingsVersion

        container.updateServerSettings(host: "test.example.com", port: "19005", useTLS: true)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }

        XCTAssertEqual(container.serverSettingsVersion, originalVersion + 1, "serverSettingsVersion should increment")
    }

    func test_updateServerSettings_noChangeDoesNotIncrementVersion() async throws {
        let originalVersion = Self.sharedContainer.serverSettingsVersion

        // Update with same settings - should be a no-op
        Self.sharedContainer.updateServerSettings(
            host: Self.sharedContainer.serverHost,
            port: Self.sharedContainer.serverPort,
            useTLS: Self.sharedContainer.useTLS
        )

        XCTAssertEqual(Self.sharedContainer.serverSettingsVersion, originalVersion, "Version should NOT increment when unchanged")
    }

    func test_updateServerSettings_updatesServerURL() async throws {
        let container = DependencyContainer()

        container.updateServerSettings(host: "newhost.example.com", port: "19006", useTLS: true)
        defer { container.updateServerSettings(host: "localhost", port: "8082", useTLS: false) }

        let url = container.serverURL
        XCTAssertEqual(url.scheme, "wss")
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
}
