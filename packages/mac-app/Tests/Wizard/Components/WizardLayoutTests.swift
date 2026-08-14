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
}
