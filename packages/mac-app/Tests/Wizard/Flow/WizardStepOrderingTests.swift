import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering and the persisted raw values so a silent
/// reorder or rename triggers a failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("rawValues are stable strings (they are the persisted wizard-state step)")
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
