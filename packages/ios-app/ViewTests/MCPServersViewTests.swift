import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class MCPServersViewTests: ShuffledTestCase {
    func testServerTheAppCannotManageHasNoManageMenu() async throws {
        try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "mcp-unmanaged"]) { app in
            @MainActor func row(_ name: String) -> String? {
                MountedFixture.elements(in: app.top).first { $0.accessibilityLabel?.hasPrefix("\(name),") == true }?.accessibilityLabel
            }
            try await app.until("both server rows") { row("fixture-managed") != nil && row("fixture-unmanaged") != nil }
            XCTAssertTrue(row("fixture-managed")!.hasSuffix(", Manage"), "A server the app can change offers Manage\n\(app.tree())")
            XCTAssertFalse(row("fixture-unmanaged")!.contains("Manage"), "A server the app cannot change offers no empty Manage menu\n\(app.tree())")
        }
    }
}
