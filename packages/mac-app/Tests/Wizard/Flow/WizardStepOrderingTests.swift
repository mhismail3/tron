import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
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

}
