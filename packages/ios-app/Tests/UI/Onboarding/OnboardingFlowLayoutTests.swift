import XCTest

/// Source-level guards for the onboarding sheet's chrome. The flow is heavily
/// visual, so these tests pin the structural placement that keeps controls from
/// floating over compact sheet content.
final class OnboardingFlowLayoutTests: XCTestCase {

    func testBackAndNextStayInSheetToolbar() throws {
        let content = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingFlowView.swift",
        ])

        XCTAssertTrue(
            content.contains("ToolbarItemGroup(placement: .topBarLeading)"),
            "Back navigation should live in the sheet toolbar leading group"
        )
        XCTAssertTrue(
            content.contains("ToolbarItem(placement: .topBarTrailing)"),
            "Next navigation should live in the sheet toolbar trailing item"
        )
        XCTAssertTrue(
            content.contains("toolbarNavigationButton("),
            "Back/Next should share the toolbar navigation button helper"
        )
        XCTAssertFalse(
            content.contains("OnboardingNavigationControls(state: state)"),
            "Back/Next must not be rendered in the bottom content overlay"
        )
        XCTAssertFalse(
            content.contains("private struct OnboardingNavigationControls"),
            "Footer navigation controls should not be reintroduced"
        )
    }

    func testOnboardingLaunchesUseOneMediumFirstExpandableSheetPresenter() throws {
        let app = try source(pathComponents: [
            "Sources",
            "App",
            "Lifecycle",
            "ProductionAppRoot.swift",
        ])
        let presentation = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingFlowPresentation.swift",
        ])

        XCTAssertTrue(
            presentation.contains("static let detents: Set<PresentationDetent> = [.medium, .large]"),
            "Onboarding and pairing should share one medium-first expandable sheet policy"
        )
        XCTAssertTrue(
            presentation.contains("static let initialDetent: PresentationDetent = .medium"),
            "Onboarding should initially present at the medium detent"
        )
        XCTAssertTrue(
            app.contains("private func presentOnboarding("),
            "App lifecycle should centralize onboarding sheet presentation"
        )
        XCTAssertTrue(
            app.contains("presentOnboarding(.firstRun)"),
            "First-run launch should use the central presenter"
        )
        XCTAssertTrue(
            app.contains("presentOnboarding(.serverSettings)"),
            "Server-page pairing launch should use the central presenter"
        )
        XCTAssertTrue(
            app.contains("presentOnboarding(.pairingURL)"),
            "Pairing URLs should use the central presenter"
        )
        XCTAssertTrue(
            app.contains("selectedDetent: $onboardingDetent"),
            "The onboarding view should know whether the sheet is medium or large"
        )
        XCTAssertTrue(
            app.contains(".adaptivePresentationDetents(OnboardingSheetPresentation.detents"),
            "The sheet modifier should consume the central onboarding detent policy"
        )
        XCTAssertTrue(
            app.contains(".adaptivePresentationDetents(OnboardingSheetPresentation.detents, selection: $onboardingDetent, ipadSizing: .compactForm, phoneBackground: .clear)"),
            "Onboarding should use the compact iPad form now that the flow is medium-first"
        )
        XCTAssertTrue(
            app.contains(".presentationContentInteraction(.resizes)"),
            "Onboarding should prefer native sheet resizing before content scrolling"
        )
        XCTAssertFalse(
            app.contains(".adaptivePresentationDetents([.medium, .large]"),
            "Onboarding should not bypass the central medium/large detent policy"
        )
        XCTAssertFalse(
            app.contains("ipadSizing: .largeForm, phoneBackground: .clear"),
            "Onboarding should not silently return to the large iPad form"
        )
        XCTAssertFalse(
            app.contains("onboardingComplete = false\n        return true"),
            "Pairing URLs should not fake first-run onboarding completion state"
        )
    }

    func testOnboardingPagesOnlyScrollAtLargeDetent() throws {
        let app = try source(pathComponents: [
            "Sources",
            "App",
            "Lifecycle",
            "ProductionAppRoot.swift",
        ])
        let flow = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingFlowView.swift",
        ])
        let shell = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingShell.swift",
        ])

        XCTAssertTrue(
            flow.contains("selectedDetent: Binding<PresentationDetent>"),
            "The flow should receive the selected sheet detent instead of guessing from content height"
        )
        XCTAssertTrue(
            flow.contains(#".environment(\.onboardingScrollsEnabled, onboardingScrollsEnabled)"#),
            "The selected detent should drive page scroll policy through the onboarding environment"
        )
        XCTAssertTrue(
            flow.contains("selectedDetent == .large"),
            "Phone onboarding pages should only allow scroll once the sheet is expanded"
        )
        XCTAssertTrue(
            flow.contains("applyPreferredDetent(for: state.currentStep)"),
            "The flow should move form-heavy setup pages to their preferred detent instead of clipping them at the bottom edge"
        )
        XCTAssertTrue(
            flow.contains("case .workspace, .anthropic, .openAI, .providers, .services, .model:"),
            "Post-pairing setup pages should be treated as large-detent form pages"
        )
        XCTAssertTrue(
            shell.contains(#"@Environment(\.onboardingScrollsEnabled)"#),
            "Shared onboarding pages should read the central scroll policy"
        )
        XCTAssertTrue(
            shell.contains(".scrollDisabled(!onboardingScrollsEnabled)"),
            "Medium onboarding pages should not consume drag gestures as scroll"
        )
        XCTAssertFalse(
            app.contains("dragIndicator: .visible"),
            "Onboarding should not opt back into native sheet drag handles"
        )
        XCTAssertFalse(
            flow.contains("DragGesture(") || shell.contains("DragGesture("),
            "Onboarding should not use custom drag recognizers for native sheet resizing"
        )
    }

    func testOnboardingCompletionPersistenceIsOwnedByProductionRoot() throws {
        let app = try source(pathComponents: [
            "Sources", "App", "Lifecycle", "ProductionAppRoot.swift",
        ])
        let state = try source(pathComponents: [
            "Sources", "Session", "Chat", "State", "OnboardingState.swift",
        ])
        let flow = try source(pathComponents: [
            "Sources", "UI", "Onboarding", "Flow", "OnboardingFlowView.swift",
        ])

        XCTAssertEqual(
            app.components(separatedBy: #""onboardingComplete""#).count - 1,
            1,
            "The completion key literal should have one production owner"
        )
        XCTAssertFalse(
            state.contains(#""onboardingComplete""#) || flow.contains(#""onboardingComplete""#),
            "Transient onboarding owners should not duplicate the root persistence key"
        )
        XCTAssertTrue(
            app.contains("@AppStorage(ProductionAppStorageKeys.onboardingComplete)"),
            "The production root should persist the completion truth it uses for lifecycle gating"
        )
        XCTAssertTrue(
            app.contains("onboardingComplete = true"),
            "The root completion callback should make the single persistence write"
        )
        for forbidden in ["completionStorageKey", "private let defaults", "func complete()", "func reset()"] {
            XCTAssertFalse(
                state.contains(forbidden),
                "Transient onboarding state should not own persistence marker \(forbidden)"
            )
        }
        XCTAssertFalse(
            flow.contains("state.complete()"),
            "The child flow should emit completion without duplicating persistence"
        )
        XCTAssertEqual(
            flow.components(separatedBy: "onComplete()").count - 1,
            2,
            "Both repair and first-run terminal paths should emit completion to the root"
        )
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try projectRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        return fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
