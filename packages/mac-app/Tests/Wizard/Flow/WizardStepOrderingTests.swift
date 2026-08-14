import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("allCases is the paved onboarding flow")
    func canonicalOrder() {
        #expect(WizardStep.allCases == [
            .welcome,
            .tailscale,
            .install,
            .permissions,
            .connectIPhone,
            .done,
        ])
    }

    @Test("raw values are stable for accessibility and diagnostics")
    func rawValuesStable() {
        #expect(WizardStep.welcome.rawValue == "welcome")
        #expect(WizardStep.tailscale.rawValue == "tailscale")
        #expect(WizardStep.permissions.rawValue == "permissions")
        #expect(WizardStep.install.rawValue == "install")
        #expect(WizardStep.connectIPhone.rawValue == "connectIPhone")
        #expect(WizardStep.done.rawValue == "done")
    }

    @Test("WizardStep round-trips through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for step in WizardStep.allCases {
            let data = try encoder.encode(step)
            let decoded = try decoder.decode(WizardStep.self, from: data)
            #expect(decoded == step)
        }
    }
}
