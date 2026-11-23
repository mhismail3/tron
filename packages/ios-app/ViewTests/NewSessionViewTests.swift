import XCTest
@testable import TronMobile

@MainActor
final class NewSessionViewTests: ShuffledTestCase {
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
