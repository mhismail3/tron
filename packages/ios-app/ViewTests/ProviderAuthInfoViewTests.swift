import XCTest
@testable import TronMobile

@MainActor
final class ProviderAuthInfoViewTests: ShuffledTestCase {
    func testInfoLinksStayBesideAPendingManualCodePrompt() async throws {
        try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "provider-info-code"]) { app in
            try await app.activate("Sign in to Fixture OAuth")
            try await app.until("the manual code prompt is shown") { app.element("Fixture code") != nil }
            XCTAssertNotNil(app.staticText("Open the authorization page, approve access, then paste the code shown."), app.tree())
            XCTAssertNotNil(app.button("Fixture authorization"), app.tree())
        }
    }
}
