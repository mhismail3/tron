import XCTest
@testable import TronMobile

@MainActor
final class SettingsStateTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "cachedConnectionPresets")
        super.tearDown()
    }

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

    // MARK: - Preset Caching

    func testInitLoadsEmptyPresetsWhenNoCacheExists() {
        let state = SettingsState()
        XCTAssertTrue(state.connectionPresets.isEmpty)
    }

    func testInitRestoresCachedPresets() {
        let presets = [
            ConnectionPreset(id: "p1", label: "Server A", host: "10.0.0.1", port: 9847),
            ConnectionPreset(id: "p2", label: "Server B", host: "10.0.0.2", port: 9848),
        ]
        let data = try! JSONEncoder().encode(presets)
        UserDefaults.standard.set(data, forKey: "cachedConnectionPresets")

        let state = SettingsState()
        XCTAssertEqual(state.connectionPresets.count, 2)
        XCTAssertEqual(state.connectionPresets[0].label, "Server A")
        XCTAssertEqual(state.connectionPresets[1].host, "10.0.0.2")
    }

    func testInitHandlesCorruptedCacheGracefully() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: "cachedConnectionPresets")

        let state = SettingsState()
        XCTAssertTrue(state.connectionPresets.isEmpty)
    }
}
