import Foundation
import Testing
@testable import TronMac

@Suite("InstallPipelineStage ordering")
struct InstallPipelineStageOrderingTests {
    @Test("stages run validate app, validate helper, register, ping")
    func canonicalOrder() {
        #expect(InstallPipelineStage.allCases == [
            .validateApplication,
            .validateHelper,
            .registerAgent,
            .awaitPing,
        ])
    }

    @Test("each install stage has visible labels and deliberate pacing")
    func installStageCopyAndPacing() {
        #expect(InstallStepContent.intro == "Install Tron Server on this Mac. It runs quietly in the background so your iPhone can connect.")
        #expect(InstallStepContent.notStartedPlaceholder == "Installation not started")
        #expect(InstallStepContent.stagePaceDelayNanoseconds >= 300_000_000)
        #expect(InstallStepContent.stagePaceDelayNanoseconds <= 600_000_000)
        #expect(InstallStepLayout.sectionSpacing >= 16)
        #expect(InstallStepLayout.completedStageSpacing <= InstallStepLayout.runningStageSpacing)
        #expect(InstallStepLayout.stageIconColumnWidth == 24)
        #expect(InstallStepLayout.stageRowMinHeight >= 22)
        #expect(InstallStepLayout.stageIconGlyphSize <= 13)
        #expect(InstallStepContent.label(for: .validateApplication) == "Confirm app location")
        #expect(InstallStepContent.label(for: .registerAgent) == "Register Login Item")
        for stage in InstallPipelineStage.allCases {
            #expect(!InstallStepContent.label(for: stage).isEmpty)
        }
    }

    @Test("successful install stage rows restore synchronously on remount")
    func successfulInstallStageRowsRestoreSynchronously() throws {
        let packageRoot = macAppRoot()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private func stageState(for stage"))
        #expect(source.contains("stageState(for: stage)"))
        #expect(source.contains("case .success:"))
        #expect(source.contains("guard !stages.isEmpty else { return false }"))
        #expect(!source.contains("case .alreadyInstalled:"))
        #expect(source.contains("private func stageIcon"))
    }

    @Test("install progress is hidden until stages actually start")
    func installProgressRevealsOnlyActiveStages() throws {
        let packageRoot = macAppRoot()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var visibleStages"))
        #expect(source.contains("stageState(for: stage) != .pending"))
        #expect(source.contains("private var stageProgressArea"))
        #expect(source.contains("Text(InstallStepContent.notStartedPlaceholder)"))
        #expect(source.contains("ForEach(visibleStages"))
        #expect(source.contains("stages[.validateApplication] = .running"))
        #expect(source.contains("completedStageSpacing"))
        #expect(source.contains("if shouldShowRegisteredServiceLayout"))
        #expect(source.contains("private var registeredServiceSummary"))
        #expect(source.contains("Open the logs window from the Tron menu bar"))
        #expect(!source.contains("Check Console.app"))
    }

    @Test("completed install page shows a status banner")
    func completedInstallPageShowsStatusBanner() throws {
        let packageRoot = macAppRoot()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var serverReadyBanner"))
        #expect(source.contains("Tron Server is ready"))
        #expect(source.contains("Current status:"))
        #expect(source.contains("refreshInstallStatus"))
        #expect(source.contains("private var currentInstallRunSucceeded"))
        #expect(source.contains("InstallPipelineStage.allCases.allSatisfy"))
        #expect(source.contains("readySummaryCards"))
        #expect(source.contains("readySummaryTransition"))
        #expect(source.contains(".animation(WizardLayout.transitionAnimation, value: installIsComplete)"))
        #expect(source.contains("withAnimation(WizardLayout.transitionAnimation)"))
        #expect(source.contains("stages[.awaitPing] = .succeeded"))
        #expect(!source.contains("cleanupMessage"))
        #expect(!source.contains("Need a fresh start?"))
    }
}
