import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("allCases is in canonical order (install precedes permissions)")
    func canonicalOrder() {
        // Install runs BEFORE permissions on purpose: macOS TCC grants
        // are tied to the process running when the user granted them,
        // so we need the agent to exist on disk and be running under
        // launchd before asking the user to grant permissions to it.
        // The permissions step then `launchctl kickstart -k`s the
        // agent after each grant so the new extension takes effect
        // without a visible restart prompt. Swapping these two steps
        // back would silently break the seamless-grant flow.
        #expect(WizardStep.allCases == [
            .welcome,
            .tailscale,
            .existingInstall,
            .install,
            .permissions,
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
    @Test("stages run prepare app → plist → load → ping")
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

    @Test("opening gate steps share one no-resize band")
    func openingStepsShareNoResizeBand() {
        let gateHeight = WizardStep.welcome.preferredHeight
        #expect(WizardStep.tailscale.preferredHeight == gateHeight)
        #expect(WizardStep.existingInstall.preferredHeight == gateHeight)
        #expect(WizardLayout.shouldResizeWindow(from: .welcome, to: .tailscale) == false)
        #expect(WizardLayout.shouldResizeWindow(from: .tailscale, to: .existingInstall) == false)
    }

    @Test("install step leaves room for explicit confirmation without becoming tallest")
    func installStepConfirmationBand() {
        #expect(WizardStep.install.preferredHeight > WizardStep.existingInstall.preferredHeight)
        #expect(WizardStep.install.preferredHeight < WizardStep.permissions.preferredHeight)
    }

    @Test("window resize math is content-delta based")
    func contentDeltaDrivesResize() {
        #expect(WizardLayout.contentHeightDelta(from: .welcome, to: .tailscale) == 0)
        #expect(WizardLayout.contentHeightDelta(from: .existingInstall, to: .install) == 80)
        #expect(WizardLayout.contentHeightDelta(from: .install, to: .permissions) == 40)
    }
}
