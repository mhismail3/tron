import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class MCPSignInCardViewTests: ShuffledTestCase {
    func testManageSessionShowsSignInOnlyWhenAServerNeedsItAndOpensTheAuthSheet() async throws {
        try await mounted(["-tron-session-configuration-fixture", "-manage-session-review", "-fixture-appearance", "light", "-mcp-needs-auth"]) { app in
            try await app.activate("Stop session")
            try await app.until("Manage Session opens") { app.element("session-usage-summary") != nil }
            try await app.expandTopSheet()
            try await app.until("the sign-in card") { app.element("mcp-sign-in-card") != nil }
            let card = app.element("mcp-sign-in-card")!.accessibilityFrame
            let model = try await revealed(app, "session-model-summary").accessibilityFrame
            XCTAssertLessThan(card.minY, model.minY, "The sign-in card sits above the model card")
            try await app.activate("mcp-sign-in-fixture-mcp")
            try await app.until("the MCP sign-in sheet") { app.navigationTitle("MCP Sign In") != nil }
        }
        try await mounted(["-tron-session-configuration-fixture", "-manage-session-review", "-fixture-appearance", "light"]) { app in
            try await app.activate("Stop session")
            try await app.until("Manage Session opens") { app.element("session-usage-summary") != nil }
            try await app.expandTopSheet()
            _ = try await revealed(app, "session-model-summary")
            XCTAssertNil(app.element("mcp-sign-in-card"), "No card when no server needs sign-in\n\(app.tree())")
        }
    }
}
