import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class FiveSheetPolishViewTests: ShuffledTestCase {
    func testToolsCountSharesHeaderLine() async throws {
        for mode in ["light", "dark"] {
            try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"] + (mode == "dark" ? ["-home-dark", "-settings-renderer-dark"] : []),
                              theme: .burgundy) { app in
                try await openManageHome(app)
                _ = try await revealed(app, "home-manage-settings")
                try await app.activate("home-manage-settings")
                try await app.until("Home Settings opens") { app.navigationTitle("Home Settings") != nil }
                try await app.expandTopSheet()
                let tools = try await revealed(app, "settings-row-tools.active").accessibilityFrame
                var editor: NSObject?
                try await app.until("the tools editor button") {
                    editor = MountedFixture.elements(in: app.top).first { node in
                        let id = MountedFixture.identifier(node) ?? ""
                        return node.isAccessibilityElement && node.accessibilityTraits.contains(.button)
                            && !id.hasSuffix("-source") && !id.hasSuffix("-reset")
                            && tools.contains(CGPoint(x: node.accessibilityFrame.midX, y: node.accessibilityFrame.midY))
                    }
                    return editor != nil
                }
                XCTAssertTrue(editor!.accessibilityActivate())
                try await app.until("the tools editor") {
                    app.element("settings-tools-editor") != nil && app.element("Built-in") != nil && app.element("16 of 16 on") != nil
                }
                let titleNode = app.element("Built-in")!, countNode = app.element("16 of 16 on")!
                XCTAssertFalse(titleNode.accessibilityTraits.contains(.button), "Built-in is static text")
                XCTAssertFalse(countNode.accessibilityTraits.contains(.button), "The count is static text")
                let title = titleNode.accessibilityFrame, count = countNode.accessibilityFrame
                XCTAssertEqual(title.midY, count.midY, accuracy: 3, "Count belongs on the header's baseline")
                XCTAssertGreaterThan(count.minX, title.maxX)
            }
        }
    }
}
