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
        XCTAssertEqual(state.maxConcurrentSessions, 10)
        XCTAssertFalse(state.isLoaded)
        XCTAssertTrue(state.availableModels.isEmpty)
        XCTAssertFalse(state.isLoadingModels)
        XCTAssertNil(state.loadError)
    }

    // MARK: - Reset

    func testResetToDefaultsRestoresAllValues() {
        let state = SettingsState()

        // Change everything
        state.preserveRecentCount = 10
        state.triggerTokenThreshold = 0.90
        state.maxConcurrentSessions = 25
        state.quickSessionWorkspace = "/some/other/path"

        // Reset
        state.resetToDefaults()

        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertEqual(state.preserveRecentCount, 5)
        XCTAssertEqual(state.triggerTokenThreshold, 0.70, accuracy: 0.001)
        XCTAssertEqual(state.maxConcurrentSessions, 10)
    }

    // MARK: - Build Update

    func testBuildCompactionUpdate() {
        let state = SettingsState()
        state.preserveRecentCount = 7
        state.triggerTokenThreshold = 0.85

        let update = state.buildResetUpdate()
        XCTAssertNotNil(update.context?.compactor)
    }

    func testBuildResetUpdateIncludesAllSettings() {
        let state = SettingsState()
        let update = state.buildResetUpdate()

        // Verify all sections are populated
        XCTAssertNotNil(update.server)
        XCTAssertEqual(update.server?.maxConcurrentSessions, 10)
        XCTAssertNotNil(update.context?.compactor)
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
}
