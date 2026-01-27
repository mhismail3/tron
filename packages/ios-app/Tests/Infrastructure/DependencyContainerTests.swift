import XCTest
@testable import TronMobile

/// Tests for DependencyContainer
@MainActor
final class DependencyContainerTests: XCTestCase {

    // MARK: - Container Lifecycle Tests

    func test_container_providesRPCClient() async throws {
        let container = DependencyContainer()

        XCTAssertNotNil(container.rpcClient)
        XCTAssert(container.rpcClient is RPCClient)
    }

    func test_container_providesEventDatabase() async throws {
        let container = DependencyContainer()

        XCTAssertNotNil(container.eventDatabase)
        XCTAssert(container.eventDatabase is EventDatabase)
    }

    func test_container_providesSkillStore() async throws {
        let container = DependencyContainer()

        XCTAssertNotNil(container.skillStore)
        XCTAssert(container.skillStore is SkillStore)
    }

    func test_container_providesEventStoreManager() async throws {
        let container = DependencyContainer()

        XCTAssertNotNil(container.eventStoreManager)
        XCTAssert(container.eventStoreManager is EventStoreManager)
    }

    func test_container_providesPushNotificationService() async throws {
        let container = DependencyContainer()

        XCTAssertNotNil(container.pushNotificationService)
        XCTAssert(container.pushNotificationService is PushNotificationService)
    }

    func test_container_providesDeepLinkRouter() async throws {
        let container = DependencyContainer()

        XCTAssertNotNil(container.deepLinkRouter)
        XCTAssert(container.deepLinkRouter is DeepLinkRouter)
    }

    // MARK: - Singleton Behavior Tests

    func test_rpcClient_returnsSameInstance() async throws {
        let container = DependencyContainer()

        let client1 = container.rpcClient
        let client2 = container.rpcClient

        XCTAssert(client1 === client2, "RPCClient should return same instance")
    }

    func test_eventDatabase_returnsSameInstance() async throws {
        let container = DependencyContainer()

        let db1 = container.eventDatabase
        let db2 = container.eventDatabase

        XCTAssert(db1 === db2, "EventDatabase should return same instance")
    }

    func test_skillStore_returnsSameInstance() async throws {
        let container = DependencyContainer()

        let store1 = container.skillStore
        let store2 = container.skillStore

        XCTAssert(store1 === store2, "SkillStore should return same instance")
    }

    func test_eventStoreManager_returnsSameInstance() async throws {
        let container = DependencyContainer()

        let manager1 = container.eventStoreManager
        let manager2 = container.eventStoreManager

        XCTAssert(manager1 === manager2, "EventStoreManager should return same instance")
    }

    // MARK: - Server Settings Tests

    func test_serverURL_constructsCorrectlyWithoutTLS() async throws {
        let container = DependencyContainer()

        // Default settings should be localhost:8082 without TLS
        let url = container.serverURL

        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 8082)
    }

    func test_currentServerOrigin_formatsCorrectly() async throws {
        let container = DependencyContainer()

        let origin = container.currentServerOrigin

        XCTAssertEqual(origin, "localhost:8082")
    }

    func test_updateServerSettings_recreatesRPCClient() async throws {
        let container = DependencyContainer()

        let originalClient = container.rpcClient

        // Use a unique port to guarantee settings change (avoids UserDefaults collision)
        let uniquePort = String(Int.random(in: 10000...60000))
        container.updateServerSettings(host: "test-server-\(uniquePort).example.com", port: uniquePort, useTLS: true)

        let newClient = container.rpcClient

        XCTAssert(originalClient !== newClient, "RPC client should be recreated after settings change")
    }

    func test_updateServerSettings_preservesEventDatabase() async throws {
        let container = DependencyContainer()

        let originalDB = container.eventDatabase

        container.updateServerSettings(host: "example.com", port: "9000", useTLS: true)

        let newDB = container.eventDatabase

        XCTAssert(originalDB === newDB, "EventDatabase should NOT be recreated after settings change")
    }

    func test_updateServerSettings_preservesPushNotificationService() async throws {
        let container = DependencyContainer()

        let originalService = container.pushNotificationService

        container.updateServerSettings(host: "example.com", port: "9000", useTLS: true)

        let newService = container.pushNotificationService

        XCTAssert(originalService === newService, "PushNotificationService should NOT be recreated after settings change")
    }

    func test_updateServerSettings_preservesDeepLinkRouter() async throws {
        let container = DependencyContainer()

        let originalRouter = container.deepLinkRouter

        container.updateServerSettings(host: "example.com", port: "9000", useTLS: true)

        let newRouter = container.deepLinkRouter

        XCTAssert(originalRouter === newRouter, "DeepLinkRouter should NOT be recreated after settings change")
    }

    func test_updateServerSettings_incrementsVersion() async throws {
        let container = DependencyContainer()

        let originalVersion = container.serverSettingsVersion

        container.updateServerSettings(host: "example.com", port: "9000", useTLS: true)

        let newVersion = container.serverSettingsVersion

        XCTAssertEqual(newVersion, originalVersion + 1, "serverSettingsVersion should increment after settings change")
    }

    func test_updateServerSettings_noChangeDoesNotIncrementVersion() async throws {
        let container = DependencyContainer()

        let originalVersion = container.serverSettingsVersion

        // Update with same settings
        container.updateServerSettings(
            host: container.serverHost,
            port: container.serverPort,
            useTLS: container.useTLS
        )

        let newVersion = container.serverSettingsVersion

        XCTAssertEqual(newVersion, originalVersion, "serverSettingsVersion should NOT increment when settings unchanged")
    }

    func test_updateServerSettings_updatesServerURL() async throws {
        let container = DependencyContainer()

        container.updateServerSettings(host: "newhost.com", port: "9999", useTLS: true)

        let url = container.serverURL

        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "newhost.com")
        XCTAssertEqual(url.port, 9999)
    }

    // MARK: - App Settings Tests

    func test_effectiveWorkingDirectory_fallsBackToDocuments() async throws {
        let container = DependencyContainer()

        // When workingDirectory is empty, should fall back to documents
        container.workingDirectory = ""

        let effective = container.effectiveWorkingDirectory

        XCTAssertFalse(effective.isEmpty)
        XCTAssertNotEqual(effective, "~")
    }

    func test_effectiveWorkingDirectory_usesWorkingDirectoryWhenSet() async throws {
        let container = DependencyContainer()

        container.workingDirectory = "/custom/path"

        let effective = container.effectiveWorkingDirectory

        XCTAssertEqual(effective, "/custom/path")
    }

    // MARK: - Protocol Conformance Tests

    func test_container_conformsToDependencyProviding() async throws {
        let container = DependencyContainer()

        // This test verifies protocol conformance at compile time
        let _: any DependencyProviding = container

        XCTAssertTrue(true, "Container conforms to DependencyProviding")
    }

    func test_container_conformsToServerSettingsProvider() async throws {
        let container = DependencyContainer()

        // This test verifies protocol conformance at compile time
        let _: any ServerSettingsProvider = container

        XCTAssertTrue(true, "Container conforms to ServerSettingsProvider")
    }

    func test_container_conformsToAppSettingsProvider() async throws {
        let container = DependencyContainer()

        // This test verifies protocol conformance at compile time
        let _: any AppSettingsProvider = container

        XCTAssertTrue(true, "Container conforms to AppSettingsProvider")
    }

    // MARK: - Initialization Tests

    func test_container_startsNotInitialized() async throws {
        let container = DependencyContainer()

        XCTAssertFalse(container.isInitialized)
    }

    // Note: Full initialization test requires database setup which may not be available in test environment
    // Integration tests should cover the full initialization flow
}
