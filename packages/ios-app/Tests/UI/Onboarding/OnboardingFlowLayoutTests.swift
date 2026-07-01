import XCTest

/// Source-level guards for the onboarding sheet's chrome. The flow is heavily
/// visual, so these tests pin the structural placement that keeps controls from
/// floating over compact sheet content.
final class OnboardingFlowLayoutTests: XCTestCase {

    func testBackAndNextUseTopBarOverlay() throws {
        let content = try source(pathComponents: [
            "Sources",
            "UI",
            "Onboarding",
            "Flow",
            "OnboardingFlowView.swift",
        ])

        XCTAssertTrue(
            content.contains("TronNavigationTopBarOverlay"),
            "Back/Next navigation should use the app-owned top bar overlay"
        )
        XCTAssertTrue(
            content.contains(".toolbar(.hidden, for: .navigationBar)"),
            "The native navigation bar should stay hidden so it cannot intercept top-bar taps"
        )
        XCTAssertTrue(
            content.contains("toolbarNavigationButton("),
            "Back/Next should share the toolbar navigation button helper"
        )
        XCTAssertFalse(
            content.contains("ToolbarItemGroup(placement: .topBarLeading)"),
            "Back navigation should not use the native toolbar host that can deform circular buttons"
        )
        XCTAssertFalse(
            content.contains("ToolbarItem(placement: .topBarTrailing)"),
            "Next navigation should not use the native toolbar host that can deform button containers"
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

    func testOnboardingLaunchesUseOneLargeSheetPresenter() throws {
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
            presentation.contains("static let detents: Set<PresentationDetent> = [.large]"),
            "Onboarding and pairing should share one large sheet policy"
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
        XCTAssertFalse(
            app.contains(".adaptivePresentationDetents([.medium, .large]"),
            "Onboarding should not reintroduce a separate medium-detent connect flow"
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
