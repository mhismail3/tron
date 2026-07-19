import Testing

@testable import TronMobile

@Suite("Hosted unit-test runtime boundary")
@MainActor
struct AppRuntimeModeTests {
    private let markers = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundleInto",
    ]

    @Test("each Apple hosted marker selects the inert process root")
    func markerPresenceSelectsHostedRoot() {
        for marker in markers {
            for value in ["", "test-bundle"] {
                #expect(
                    AppRuntimeMode.resolve(environment: [marker: value]) == .hostedUnitTests,
                    "marker \(marker), value \(value)"
                )
            }
        }
    }

    @Test("environments without Apple hosted markers remain application launches")
    func markerAbsenceSelectsApplicationRoot() {
        #expect(AppRuntimeMode.resolve(environment: [:]) == .application)
        #expect(AppRuntimeMode.resolve(environment: ["UNRELATED": "value"]) == .application)
    }
}
