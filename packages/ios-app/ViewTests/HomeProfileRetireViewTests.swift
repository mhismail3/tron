import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeProfileRetireViewTests: ShuffledTestCase {
    func testRetireIconAndSubtextUseDestructiveInk() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-profile")
            try await app.activate("home-manage-profile")
            try await app.until("Profile opens") { app.element("home-profile-items") != nil }
            try await app.expandTopSheet()
            _ = try await revealed(app, "home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc")
            try await app.activate("home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc")
            try await app.until("the profile item opens") { app.element("home-profile-item-detail") != nil }
            try await app.expandTopSheet()
            _ = try await revealed(app, "home-profile-item-retire")
            try await app.until("the Retire row and its subtext") {
                app.element("home-profile-item-retire") != nil && app.element("home-profile-item-retire-subtext") != nil
            }
            let icon = try await app.inked("the Retire row icon") {
                app.element("home-profile-item-retire").map { frame in
                    var area = frame.accessibilityFrame; area.size.width = 44; return area
                }
            }
            let subtext = try await app.inked("the Retire subtext") { app.element("home-profile-item-retire-subtext")?.accessibilityFrame }
            for color in [icon, subtext] {
                XCTAssertGreaterThan(color[0], color[1] + 0.2)
                XCTAssertGreaterThan(color[0], color[2] + 0.2)
            }
        }
    }
}
