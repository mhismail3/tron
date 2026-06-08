import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("allCases is in canonical order (iOS beta precedes pairing)")
    func canonicalOrder() {
        // Install runs BEFORE permissions on purpose: the wrapper first
        // registers the LaunchAgent with its associated bundle IDs, then
        // probes/prompts the wrapper-owned TCC rows that macOS shows in
        // System Settings. The iOS beta handoff then runs before the
        // pairing QR.
        #expect(WizardStep.allCases == [
            .welcome,
            .tailscale,
            .install,
            .permissions,
            .iosBeta,
            .pairingInfo,
            .done,
        ])
    }

    @Test("rawValues are stable strings (used as UserDefaults keys)")
    func rawValuesStable() {
        #expect(WizardStep.welcome.rawValue == "welcome")
        #expect(WizardStep.tailscale.rawValue == "tailscale")
        #expect(WizardStep.permissions.rawValue == "permissions")
        #expect(WizardStep.install.rawValue == "install")
        #expect(WizardStep.iosBeta.rawValue == "iosBeta")
        #expect(WizardStep.pairingInfo.rawValue == "pairingInfo")
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
