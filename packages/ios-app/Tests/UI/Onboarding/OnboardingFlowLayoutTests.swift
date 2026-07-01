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

    func testOnboardingLaunchesUseOneMediumSheetPresenter() throws {
        let app = try source(pathComponents: [
            "Sources",
            "App",
            "Lifecycle",
            "TronMobileApp.swift",
        ])
        let presentation = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingFlowPresentation.swift",
        ])

        XCTAssertTrue(
            presentation.contains("static let detents: Set<PresentationDetent> = [.medium]"),
            "Onboarding and pairing should share one medium sheet policy"
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
            app.contains(".adaptivePresentationDetents(OnboardingSheetPresentation.detents"),
            "The sheet modifier should consume the central onboarding detent policy"
        )
        XCTAssertTrue(
            app.contains(".adaptivePresentationDetents(OnboardingSheetPresentation.detents, selection: $onboardingDetent, ipadSizing: .compactForm, phoneBackground: .clear)"),
            "Onboarding should use the compact iPad form now that the flow is medium-first"
        )
        XCTAssertFalse(
            app.contains(".adaptivePresentationDetents([.medium, .large]"),
            "Onboarding should not reintroduce a mixed medium/large connect flow"
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
