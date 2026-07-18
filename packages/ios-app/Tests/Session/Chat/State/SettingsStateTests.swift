import XCTest
@testable import TronMobile

@MainActor
final class SettingsStateTests: XCTestCase {
    func testInitialProjectionContainsOnlySessionDefaults() {
        let state = SettingsState()
        XCTAssertEqual(state.sessionDefaults, .empty)
        XCTAssertEqual(state.defaultModel, "")
        XCTAssertEqual(state.quickSessionWorkspace, AppConstants.defaultWorkspace)
        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.loadError)
    }

    func testDisplayQuickSessionWorkspaceCollapsesHomeDirectory() {
        let state = SettingsState()
        state.quickSessionWorkspace = "\(NSHomeDirectory())/Projects/myapp"
        XCTAssertTrue(state.displayQuickSessionWorkspace.hasPrefix("~/"))
    }

    func testApplyServerSettingsProjectsOnlyExternalDefaults() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(
            ServerSettings.self,
            from: try ServerSettingsFixture.data(#"{"server":{"defaultModel":"claude-opus-4-6","defaultWorkspace":"/projects","tailscaleIp":"100.64.0.7","transcription":{"enabled":true}},"context":{"compactor":{"preserveRecentCount":9,"triggerTokenThreshold":0.9}}}"#)
        )

        state.applyServerSettings(ServerSettingsSnapshot(settings))

        XCTAssertEqual(state.sessionDefaults, SessionDefaultsSnapshot(
            defaultWorkspace: "/projects",
            defaultModel: "claude-opus-4-6"
        ))
        let fields = Set(Mirror(reflecting: state).children.compactMap(\.label))
        XCTAssertFalse(fields.contains("_tailscaleIp"))
        XCTAssertFalse(fields.contains("_preserveRecentCount"))
        XCTAssertFalse(fields.contains("_triggerTokenThreshold"))
        XCTAssertFalse(fields.contains("_transcriptionEnabled"))
    }

    func testClearServerSnapshotDropsDefaults() throws {
        let state = SettingsState()
        let settings = try JSONDecoder().decode(
            ServerSettings.self,
            from: try ServerSettingsFixture.data(#"{"server":{"defaultWorkspace":"/old/server"}}"#)
        )
        state.applyServerSettings(ServerSettingsSnapshot(settings))
        state.isLoaded = true

        state.clearServerSnapshot()

        XCTAssertEqual(state.sessionDefaults, .empty)
        XCTAssertFalse(state.isLoaded)
        XCTAssertNil(state.loadError)
    }
}
