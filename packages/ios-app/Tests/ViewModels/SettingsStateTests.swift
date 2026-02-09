import XCTest
@testable import TronMobile

@MainActor
final class SettingsStateTests: XCTestCase {

    // MARK: - Initial Values

    func testInitialValuesMatchDefaults() {
        let state = SettingsState()
        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertEqual(state.preserveRecentTurns, 5)
        XCTAssertFalse(state.forceAlwaysCompact)
        XCTAssertEqual(state.triggerTokenThreshold, 0.70, accuracy: 0.001)
        XCTAssertEqual(state.defaultTurnFallback, 8)
        XCTAssertFalse(state.memoryAutoInject)
        XCTAssertEqual(state.memoryAutoInjectCount, 5)
        XCTAssertEqual(state.webFetchTimeoutMs, 30000)
        XCTAssertEqual(state.webCacheTtlMs, 900000)
        XCTAssertEqual(state.webCacheMaxEntries, 100)
        XCTAssertFalse(state.isLoaded)
        XCTAssertTrue(state.availableModels.isEmpty)
        XCTAssertFalse(state.isLoadingModels)
        XCTAssertNil(state.loadError)
    }

    // MARK: - Reset

    func testResetToDefaultsRestoresAllValues() {
        let state = SettingsState()

        // Change everything
        state.preserveRecentTurns = 10
        state.forceAlwaysCompact = true
        state.triggerTokenThreshold = 0.90
        state.defaultTurnFallback = 15
        state.memoryAutoInject = true
        state.memoryAutoInjectCount = 8
        state.webFetchTimeoutMs = 60000
        state.webCacheTtlMs = 1800000
        state.webCacheMaxEntries = 200
        state.quickSessionWorkspace = "/some/other/path"

        // Reset
        state.resetToDefaults()

        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertEqual(state.preserveRecentTurns, 5)
        XCTAssertFalse(state.forceAlwaysCompact)
        XCTAssertEqual(state.triggerTokenThreshold, 0.70, accuracy: 0.001)
        XCTAssertEqual(state.defaultTurnFallback, 8)
        XCTAssertFalse(state.memoryAutoInject)
        XCTAssertEqual(state.memoryAutoInjectCount, 5)
        XCTAssertEqual(state.webFetchTimeoutMs, 30000)
        XCTAssertEqual(state.webCacheTtlMs, 900000)
        XCTAssertEqual(state.webCacheMaxEntries, 100)
    }

    // MARK: - Build Update

    func testBuildCompactionUpdate() {
        let state = SettingsState()
        state.preserveRecentTurns = 7
        state.forceAlwaysCompact = true
        state.triggerTokenThreshold = 0.85
        state.defaultTurnFallback = 12

        let update = state.buildResetUpdate()
        XCTAssertNotNil(update.context?.compactor)
    }

    func testBuildResetUpdateIncludesAllSettings() {
        let state = SettingsState()
        let update = state.buildResetUpdate()

        // Verify all sections are populated
        XCTAssertNotNil(update.server)
        XCTAssertNotNil(update.context?.compactor)
        XCTAssertNotNil(update.tools?.web)
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
