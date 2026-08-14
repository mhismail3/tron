import Testing
@testable import TronMac

@Suite("Wizard layout")
struct WizardLayoutTests {
    @Test("fixed regions exactly partition the window")
    func fixedRegionsPartitionWindow() {
        let occupiedHeight = WizardLayout.topPadding
            + WizardLayout.headerHeight
            + WizardLayout.headerBodySpacing
            + WizardLayout.bodyHeight
            + WizardLayout.footerHeight
            + WizardLayout.bottomPadding

        #expect(abs(occupiedHeight - WizardLayout.height) < 0.001)
        #expect(WizardLayout.contentWidth == 416)
        #expect(WizardLayout.bodyHeight == 264)
    }

    @Test("the longest title retains a dedicated single-line slot")
    func titleSlotDoesNotCollapse() {
        #expect(WizardLayout.headerTitleAvailableWidth >= 220)
        #expect(WizardStep.connectIPhone.displayTitle == "Connect your iPhone")
    }

    @Test("the first backward and forward reversals use their page pair")
    func firstReversalDirectionIsDeterministic() {
        let backward = WizardPageMotion(
            source: .connectIPhone,
            destination: .permissions
        )
        #expect(backward.direction == .backward)
        #expect(backward.incomingOffset(progress: 0, distance: 100) == -100)
        #expect(backward.outgoingOffset(progress: 1, distance: 100) == 100)

        let forward = WizardPageMotion(
            source: .permissions,
            destination: .connectIPhone
        )
        #expect(forward.direction == .forward)
        #expect(forward.incomingOffset(progress: 0, distance: 100) == 100)
        #expect(forward.outgoingOffset(progress: 1, distance: 100) == -100)
    }
}
