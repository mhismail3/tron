import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("allCases is in canonical order")
    func canonicalOrder() {
        #expect(WizardStep.allCases == [
            .welcome,
            .tailscale,
            .existingInstall,
            .permissions,
            .install,
            .pairingInfo,
            .done,
        ])
    }

    @Test("rawValues are stable strings (used as UserDefaults keys)")
    func rawValuesStable() {
        #expect(WizardStep.welcome.rawValue == "welcome")
        #expect(WizardStep.tailscale.rawValue == "tailscale")
        #expect(WizardStep.existingInstall.rawValue == "existingInstall")
        #expect(WizardStep.permissions.rawValue == "permissions")
        #expect(WizardStep.install.rawValue == "install")
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

@Suite("InstallPipelineStage ordering")
struct InstallPipelineStageOrderingTests {
    @Test("stages run copy → plist → load → ping")
    func canonicalOrder() {
        #expect(InstallPipelineStage.allCases == [
            .copyBinary,
            .writePlist,
            .loadAgent,
            .awaitPing,
        ])
    }
}

@Suite("Permission ordering")
struct PermissionOrderingTests {
    @Test("FDA, screen recording, accessibility")
    func canonicalOrder() {
        #expect(Permission.allCases == [
            .fullDiskAccess,
            .screenRecording,
            .accessibility,
        ])
    }
}

@Suite("WizardStep preferred heights")
struct WizardStepPreferredHeightTests {
    @Test("every step has a plausible height in [280, 560]")
    func heightsAreInRange() {
        // Guards against accidental 0/negative heights and against
        // runaway numbers that would break the 480×H canvas.
        for step in WizardStep.allCases {
            let h = step.preferredHeight
            #expect(h >= 280, "\(step) height \(h) is below the 280pt floor")
            #expect(h <= 560, "\(step) height \(h) is above the 560pt ceiling")
        }
    }

    @Test("Permissions is the tallest step (three cards)")
    func permissionsIsTallest() {
        let heights = WizardStep.allCases.map { $0.preferredHeight }
        let max = heights.max() ?? 0
        #expect(WizardStep.permissions.preferredHeight == max,
                "Permissions must be tallest so all three cards fit without scrolling")
    }
}
