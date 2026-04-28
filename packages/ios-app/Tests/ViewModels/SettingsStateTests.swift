import XCTest
@testable import TronMobile

@MainActor
final class SettingsStateTests: XCTestCase {

    // MARK: - Initial Values

    func testInitialValuesMatchDefaults() {
        let state = SettingsState()
        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertEqual(state.preserveRecentCount, 5)
        XCTAssertEqual(state.triggerTokenThreshold, 0.70, accuracy: 0.001)
        XCTAssertEqual(state.queueDrainMode, "sequential")
        XCTAssertFalse(state.isLoaded)
        XCTAssertTrue(state.availableModels.isEmpty)
        XCTAssertFalse(state.isLoadingModels)
        XCTAssertNil(state.loadError)
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

    // MARK: - Server Switching

    func testApplyServerSettingsClearsWorkspaceWhenActiveServerOmitsIt() throws {
        let state = SettingsState()
        state.quickSessionWorkspace = "/from/previous/server"

        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{}"#.utf8))
        state.applyServerSettings(settings)

        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
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

    func testFailedUpdateRollsBackToLastLoadedServerSettings() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(ServerSettings.self, from: Data(#"{"server":{"defaultWorkspace":"/loaded"}}"#.utf8))
        state.applyServerSettings(settings)
        state.quickSessionWorkspace = "/optimistic"

        state.rollbackToLastLoadedSettings(message: "save failed")

        XCTAssertEqual(state.quickSessionWorkspace, "/loaded")
        XCTAssertEqual(state.loadError, "save failed")
        XCTAssertTrue(state.isLoaded)
    }
}
