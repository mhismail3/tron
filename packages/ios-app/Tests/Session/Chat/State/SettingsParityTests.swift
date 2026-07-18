import XCTest
@testable import TronMobile

@MainActor
final class SettingsParityTests: XCTestCase {
    func testSixFieldProductProjectionRemainsExplicit() throws {
        let definition = try NativeUIBundledDefinitions.load("settings.engine")
        let encoded = try JSONEncoder().encode(definition)
        let source = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        for path in [
            "/defaultWorkspace", "/defaultModel", "/compactionThreshold",
            "/preserveRecentCount", "/transcriptionEnabled", "/tailscaleAddress",
        ] {
            XCTAssertTrue(source.contains(path), "missing explicit settings projection \(path)")
        }
    }

    func testSettingsStateOwnsOnlyExternalSessionDefaults() {
        let state = SettingsState()
        let fields = Set(Mirror(reflecting: state).children.compactMap { label in
            label.label.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        })

        XCTAssertTrue(fields.contains("sessionDefaults"))
        for forbidden in [
            "tailscaleIp", "preserveRecentCount", "triggerTokenThreshold", "transcriptionEnabled",
        ] {
            XCTAssertFalse(fields.contains(forbidden), "\(forbidden) must remain surface-owned")
        }
    }
}
