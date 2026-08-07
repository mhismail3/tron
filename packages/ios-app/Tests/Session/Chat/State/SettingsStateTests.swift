import XCTest
@testable import TronMobile

@MainActor
final class SettingsStateTests: XCTestCase {

    // MARK: - Initial Values

    func testInitialValuesMatchDefaults() {
        let state = SettingsState()
        XCTAssertEqual(state.defaultModel, "")
        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertNil(state.tailscaleIp)
        XCTAssertEqual(state.ollamaBaseUrl, "http://localhost:11434")
        XCTAssertEqual(state.preserveRecentCount, 5)
        XCTAssertEqual(state.triggerTokenThreshold, 0.70, accuracy: 0.001)
        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.loadError)
    }

    // MARK: - Display Helpers

    func testDisplayQuickSessionWorkspaceCollapsesTilde() {
        let state = SettingsState()
        let homeDirectory = NSHomeDirectory()
        state.quickSessionWorkspace = "\(homeDirectory)/Projects/myapp"
        let display = state.displayQuickSessionWorkspace
        XCTAssertTrue(display.hasPrefix("~/"))
        XCTAssertFalse(display.contains(homeDirectory))
    }

    func testDisplayQuickSessionWorkspaceHandlesNonUserPath() {
        let state = SettingsState()
        state.quickSessionWorkspace = "/tmp/workspace"
        XCTAssertEqual(state.displayQuickSessionWorkspace, "/tmp/workspace")
    }

    // MARK: - Server Switching

    func testApplyServerSettingsClearsWorkspaceWhenActiveServerOmitsIt() throws {
        let state = SettingsState()
        state.quickSessionWorkspace = "/from/previous/server"

        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        state.applyServerSettings(ServerSettingsSnapshot(settings))

        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
    }

    func testApplyServerSettingsLoadsDefaultModelFromServer() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(
            ServerSettings.self,
            from: try ServerSettingsFixture.data(#"{"api":{"ollama":{"baseUrl":"http://192.168.1.5:11434"}},"server":{"defaultModel":"claude-opus-4-6","tailscaleIp":"100.64.0.7"}}"#)
        )

        state.applyServerSettings(ServerSettingsSnapshot(settings))

        XCTAssertEqual(state.defaultModel, "claude-opus-4-6")
        XCTAssertEqual(state.tailscaleIp, "100.64.0.7")
        XCTAssertEqual(state.ollamaBaseUrl, "http://192.168.1.5:11434")
    }

    func testClearServerSnapshotHidesServerSettingsDuringSwitch() {
        let state = SettingsState()
        state.isLoaded = true
        state.loadError = "old error"
        state.tailscaleIp = "100.64.0.7"
        state.ollamaBaseUrl = "http://old:11434"

        state.clearServerSnapshot()

        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.loadError)
        XCTAssertNil(state.tailscaleIp)
        XCTAssertEqual(state.ollamaBaseUrl, "http://localhost:11434")
    }

    func testClearServerSnapshotClearsRollbackAnchor() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/old/server"}}"#))
        state.applyServerSettings(ServerSettingsSnapshot(settings))

        state.clearServerSnapshot()
        state.quickSessionWorkspace = "/optimistic"
        state.rollbackToLastLoadedSettings(message: "save failed")

        XCTAssertEqual(state.quickSessionWorkspace, "/optimistic")
        XCTAssertFalse(state.isLoaded)
        XCTAssertEqual(state.loadError, "save failed")
    }

    func testFailedUpdateRollsBackToLastLoadedServerSettings() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/loaded"}}"#))
        state.applyServerSettings(ServerSettingsSnapshot(settings))
        state.quickSessionWorkspace = "/optimistic"
        state.defaultModel = "locally-selected-before-server-accepted"

        state.rollbackToLastLoadedSettings(message: "save failed")

        XCTAssertEqual(state.quickSessionWorkspace, "/loaded")
        XCTAssertEqual(state.defaultModel, "claude-sonnet-4-6")
        XCTAssertEqual(state.loadError, "save failed")
        XCTAssertTrue(state.isLoaded)
    }

    func testForcedReconciliationPreservesLastSnapshotAcrossTransientFailure() async {
        let initial = ServerSettingsSnapshot(
            defaultModel: "model-a",
            defaultWorkspace: "/workspace-a",
            tailscaleIp: "100.64.0.1",
            ollamaBaseUrl: "http://first:11434",
            compactionPreserveRecentCount: 5,
            compactionTriggerTokenThreshold: 0.7
        )
        let refreshed = ServerSettingsSnapshot(
            defaultModel: "model-b",
            defaultWorkspace: "/workspace-b",
            tailscaleIp: "100.64.0.2",
            ollamaBaseUrl: "http://second:11434",
            compactionPreserveRecentCount: 7,
            compactionTriggerTokenThreshold: 0.8
        )
        let repository = ReconnectingSettingsRepository(result: .success(initial))
        let state = SettingsState()

        await state.load(using: repository)
        repository.result = .failure(EngineConnectionError.notConnected)
        await state.load(using: repository, forceRefresh: true)

        XCTAssertTrue(state.isLoaded)
        XCTAssertEqual(state.defaultModel, "model-a")
        XCTAssertEqual(state.quickSessionWorkspace, "/workspace-a")
        XCTAssertNil(state.loadError)

        repository.result = .success(refreshed)
        await state.load(using: repository, forceRefresh: true)

        XCTAssertEqual(state.defaultModel, "model-b")
        XCTAssertEqual(state.quickSessionWorkspace, "/workspace-b")
        XCTAssertEqual(repository.getCount, 3)
    }
}

@MainActor
private final class ReconnectingSettingsRepository: SettingsRepository {
    var result: Result<ServerSettingsSnapshot, Error>
    private(set) var getCount = 0

    init(result: Result<ServerSettingsSnapshot, Error>) {
        self.result = result
    }

    func get() async throws -> ServerSettingsSnapshot {
        getCount += 1
        return try result.get()
    }

    func update(
        _: SettingsMutation,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws {}

    func resetToDefaults(
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> ServerSettingsSnapshot {
        try result.get()
    }
}
