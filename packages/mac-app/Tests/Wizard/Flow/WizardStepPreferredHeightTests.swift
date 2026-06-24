import Foundation
import Testing
@testable import TronMac

@Suite("Permission ordering")
struct PermissionOrderingTests {
    @Test("only FDA is required")
    func canonicalOrder() {
        #expect(Permission.allCases == [
            .fullDiskAccess,
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

    @Test("Install is the tallest step")
    func installIsTallest() {
        let heights = WizardStep.allCases.map { $0.preferredHeight }
        let max = heights.max() ?? 0
        #expect(WizardStep.install.preferredHeight == max,
                "Install must be tallest so the explicit confirmation fits without scrolling")
    }

    @Test("opening gate steps share one lower-height band")
    func openingStepsShareLowerHeightBand() {
        let gateHeight = WizardStep.welcome.preferredHeight
        #expect(WizardStep.tailscale.preferredHeight == gateHeight)
        #expect(WizardStep.permissions.preferredHeight == gateHeight)
        #expect(gateHeight < WizardLayout.height)
    }

    @Test("install step leaves room for explicit confirmation")
    func installStepConfirmationBand() {
        #expect(WizardStep.install.preferredHeight > WizardStep.tailscale.preferredHeight)
        #expect(WizardStep.install.preferredHeight == WizardLayout.height)
    }

    @Test("wizard canvas is fixed to the tallest step height")
    func wizardCanvasUsesTallestStepHeight() throws {
        let tallestStepHeight = try #require(WizardStep.allCases.map { $0.preferredHeight }.max())
        #expect(WizardLayout.height == tallestStepHeight)
        #expect(WizardLayout.height == WizardStep.install.preferredHeight)

        let packageRoot = macAppRoot()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/Flow/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)

        #expect(source.contains(".frame(width: WizardLayout.width, height: WizardLayout.height)"))
        #expect(!source.contains("animateHostingWindow"))
        #expect(!source.contains("displayStep.preferredHeight"))
    }
}
