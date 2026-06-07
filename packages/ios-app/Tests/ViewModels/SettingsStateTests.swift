import XCTest
@testable import TronMobile

@MainActor
final class SettingsStateTests: XCTestCase {

    // MARK: - Initial Values

    func testInitialValuesMatchDefaults() {
        let state = SettingsState()
        XCTAssertEqual(state.defaultModel, "")
        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertEqual(state.preserveRecentCount, 5)
        XCTAssertEqual(state.triggerTokenThreshold, 0.70, accuracy: 0.001)
        XCTAssertEqual(state.queueDrainMode, "sequential")
        XCTAssertFalse(state.isLoaded)
        XCTAssertTrue(state.availableModels.isEmpty)
        XCTAssertFalse(state.isLoadingModels)
        XCTAssertNil(state.loadError)
        XCTAssertEqual(state.observabilityLogLevel, "info")
        XCTAssertEqual(state.observabilityPayloadCapture, "normal")
        XCTAssertEqual(state.observabilityVerboseRetentionDays, 7)
        XCTAssertEqual(state.observabilityMaxInlinePayloadBytes, 8192)
        XCTAssertTrue(state.storageRetentionEnabled)
        XCTAssertEqual(state.storageMaxDatabaseMb, 512)
    }

    // MARK: - Display Helpers

    func testDisplayQuickSessionWorkspaceCollapsesTilde() {
        let state = SettingsState()
        state.quickSessionWorkspace = "/Users/testuser/Projects/myapp"
        let display = state.displayQuickSessionWorkspace
        XCTAssertTrue(display.hasPrefix("~/"))
        XCTAssertFalse(display.contains("/Users/testuser/"))
    }

    func testDisplayQuickSessionWorkspaceHandlesNonUserPath() {
        let state = SettingsState()
        state.quickSessionWorkspace = "/tmp/workspace"
        XCTAssertEqual(state.displayQuickSessionWorkspace, "/tmp/workspace")
    }

    // MARK: - Update Settings

    func testUpdateSettingsInitialDefaults() {
        let state = SettingsState()
        // Defaults match the Rust UpdateSettings::default():
        // opt-in (off), stable channel, daily check, notify-only.
        XCTAssertFalse(state.updateEnabled)
        XCTAssertEqual(state.updateChannel, "stable")
        XCTAssertEqual(state.updateFrequency, "daily")
        XCTAssertEqual(state.updateAction, "notify")
        XCTAssertFalse(state.transcriptionEnabled)
    }

    func testApplyServerSettingsLoadsDiagnosticsFields() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data("""
        {
          "observability": {
            "logLevel": "debug",
            "payloadCapture": "trace",
            "verboseRetentionDays": 3,
            "maxInlinePayloadBytes": 4096
          },
          "storage": {
            "retentionEnabled": false,
            "maxDatabaseMb": 256
          }
        }
        """))

        state.applyServerSettings(settings)

        XCTAssertEqual(state.observabilityLogLevel, "debug")
        XCTAssertEqual(state.observabilityPayloadCapture, "trace")
        XCTAssertEqual(state.observabilityVerboseRetentionDays, 3)
        XCTAssertEqual(state.observabilityMaxInlinePayloadBytes, 4096)
        XCTAssertFalse(state.storageRetentionEnabled)
        XCTAssertEqual(state.storageMaxDatabaseMb, 256)
    }

    // MARK: - Server Switching

    func testApplyServerSettingsClearsWorkspaceWhenActiveServerOmitsIt() throws {
        let state = SettingsState()
        state.quickSessionWorkspace = "/from/previous/server"

        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data())
        state.applyServerSettings(settings)

        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
    }

    func testApplyServerSettingsLoadsDefaultModelFromServer() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(
            ServerSettings.self,
            from: try ServerSettingsFixture.data(#"{"server":{"defaultModel":"claude-opus-4-6"}}"#)
        )

        state.applyServerSettings(settings)

        XCTAssertEqual(state.defaultModel, "claude-opus-4-6")
    }

    func testClearServerSnapshotHidesServerSettingsDuringSwitch() {
        let state = SettingsState()
        state.isLoaded = true
        state.loadError = "old error"
        state.isLoadingModels = true

        state.clearServerSnapshot()

        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.loadError)
        XCTAssertTrue(state.availableModels.isEmpty)
        XCTAssertFalse(state.isLoadingModels)
    }

    func testClearServerSnapshotClearsRollbackAnchor() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(ServerSettings.self, from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/old/server"}}"#))
        state.applyServerSettings(settings)

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
        state.applyServerSettings(settings)
        state.quickSessionWorkspace = "/optimistic"
        state.defaultModel = "locally-selected-before-server-accepted"

        state.rollbackToLastLoadedSettings(message: "save failed")

        XCTAssertEqual(state.quickSessionWorkspace, "/loaded")
        XCTAssertEqual(state.defaultModel, "claude-sonnet-4-6")
        XCTAssertEqual(state.loadError, "save failed")
        XCTAssertTrue(state.isLoaded)
    }
}
