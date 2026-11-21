import XCTest
@testable import TronMobile

@MainActor
final class NewSessionViewTests: ShuffledTestCase {
    func testRetiredSubmissionCannotSendImplicitTrustToReplacementMac() async throws {
        try await mounted(["-tron-new-session-fixture", "-new-session-scenario", "trust-before-profile"]) { app in
            try await app.activate("Create")
            try await app.until("the submission holds its trust") { text(app, "fixture.trust-counts").contains("held:1") }
            try await app.activate("new-session-card.Server")
            try await app.pressButton(containing: "Replacement fixture")
            try await app.until("the replacement Mac is connected") {
                text(app, "fixture.create-connection").hasPrefix("connected")
                    && text(app, "fixture.create-connection").contains("profile:new-session-replacement")
            }
            try await app.until("the held trust is released") { text(app, "fixture.trust-counts").contains("released:1") }
            try await app.until("Create waits disabled") { app.button("Create")?.accessibilityTraits.contains(.notEnabled) == true }
            XCTAssertTrue(text(app, "fixture.trust-counts").hasPrefix("trusts:0 successor:0"),
                          "Original cwd/trust fallback must never dispatch to a replacement Mac")
            XCTAssertEqual(text(app, "fixture.create-counts"), "creates:0 typed:0")
            XCTAssertEqual(text(app, "fixture.create-result"), "callbacks:0 owned:false")
        }
    }

    func testOriginalUnresolvedTrustFallbackCreatesOnce() async throws {
        try await mounted(["-tron-new-session-fixture", "-new-session-scenario", "trust-original"]) { app in
            try await app.activate("Create")
            try await app.until("the original create runs once") { text(app, "fixture.create-result") == "callbacks:1 owned:true" }
            XCTAssertTrue(text(app, "fixture.trust-counts").hasPrefix("trusts:1 successor:0 fallback:true"))
            XCTAssertEqual(text(app, "fixture.create-counts"), "creates:1 typed:0")
        }
    }

    private func text(_ app: MountedFixture, _ id: String) -> String {
        app.element(id)?.accessibilityLabel ?? ""
    }
}
