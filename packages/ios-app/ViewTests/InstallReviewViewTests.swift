import XCTest
@testable import TronMobile

@MainActor
final class InstallReviewViewTests: ShuffledTestCase {
    func testOfferOpensOnlyInstallReview() async throws {
        try await mounted(readonlyArguments("display-swift-install-review-inline-light")) { app in
            try await app.activate("swiftApp.card")
            try await app.until("the install review") { app.element("apps.install.review") != nil }
            try await app.until("the mounted sheet titles") { titles(app).contains("Install App") }
            let mounted = titles(app)
            XCTAssertFalse(mounted.contains("Builds"), "Transient runner chrome must never mount: \(mounted)")
            XCTAssertEqual(mounted.filter { $0 == "Install App" }.count, 1, "\(mounted)")
        }
    }

    func testToolbarInstallUsesReviewedOffer() async throws {
        try await mounted(readonlyArguments("display-swift-install-review-inline-light")) { app in
            try await openReview(app)
            let install = try XCTUnwrap(app.button("apps.install.confirm"))
            XCTAssertEqual(install.accessibilityLabel, "Install")
            XCTAssertEqual(MountedFixture.elements(in: app.top).filter {
                MountedFixture.identifier($0) == "apps.install.confirm" && $0.accessibilityTraits.contains(.button)
            }.count, 1)
            XCTAssertNil(app.button("apps.install.open"))
            try await app.activate("apps.install.confirm")
            try await app.until("the installed app's Open") { app.button("apps.install.open") != nil }
            XCTAssertTrue(app.button("apps.install.confirm")?.accessibilityTraits.contains(.notEnabled) == true,
                          "Accepted installation must not be submitted twice")
        }
    }

    func testDetailsAndSourceLight() async throws { try await detailsJourney(dark: false) }
    func testDetailsAndSourceDark() async throws { try await detailsJourney(dark: true) }
    func testDetailsAndSourceLightXXXL() async throws { try await detailsJourney(dark: false, large: true) }
    func testDetailsAndSourceDarkXXXL() async throws { try await detailsJourney(dark: true, large: true) }

    private func detailsJourney(dark: Bool, large: Bool = false) async throws {
        let scenario = "display-swift-install-review-inline-\(dark ? "dark" : "light")"
        try await mounted(readonlyArguments(scenario),
                          contentSize: large ? .accessibilityExtraExtraExtraLarge : .large) { app in
            try await openReview(app)
            if large {
                try await app.until("the iOS builds footer") {
                    app.staticText("Builds reads your iOS builds feed when opened.") != nil
                }
                let footer = try XCTUnwrap(app.staticText("Builds reads your iOS builds feed when opened."))
                try await app.reveal(footer)
                XCTAssertTrue(app.onScreen(footer), app.tree())
            }
            try await app.activate("apps.install.info")
            try await app.until("the details sheet") { app.element("apps.install.details") != nil }
            try await app.until("the View Source row") { app.button("apps.install.source") != nil }
            let source = try XCTUnwrap(app.button("apps.install.source"))
            try await app.reveal(source)
            XCTAssertTrue(app.onScreen(source), app.tree())
            try await app.activate("apps.install.source")
            try await app.until("the Builds.swift source") { app.navigationTitle("Builds.swift") != nil }
            try await app.until("the source reader") {
                MountedFixture.views(UITextView.self, in: app.top).contains { $0.text.contains("Fixture app") }
            }
        }
    }

    private func openReview(_ app: MountedFixture) async throws {
        try await app.activate("swiftApp.card")
        try await app.until("the install review is ready") {
            app.button("apps.install.confirm").map { !$0.accessibilityTraits.contains(.notEnabled) } == true
        }
    }

    private func titles(_ app: MountedFixture) -> [String] {
        let probe = MountedFixture.elements(in: app.window).last { MountedFixture.identifier($0) == "fixture.install-review-titles" }
        return (probe?.accessibilityValue ?? "").components(separatedBy: "|")
    }

    private func readonlyArguments(_ scenario: String) -> [String] {
        ["-tron-readonly-attachment-fixture", "-readonly-preview-scenario", scenario]
    }
}
