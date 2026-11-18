import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeProfileViewTests: ShuffledTestCase {
    func testProfileGroupsNotesByAreaWithoutBulkConfirmation() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-profile")
            try await app.activate("home-manage-profile")
            try await app.until("Profile opens") { app.element("home-profile-items") != nil }
            try await app.expandTopSheet()
            let titles = ["Communication", "Machines, devices & services", "Unsorted"]
            try await app.until("the profile areas") { titles.allSatisfy { text(app, $0) != nil } }
            let areas = titles.map { text(app, $0)!.accessibilityFrame }
            XCTAssertLessThan(areas[0].minY, areas[1].minY, "Areas keep their order")
            XCTAssertLessThan(areas[1].minY, areas[2].minY, "Unsorted follows the reviewed areas")
            for kind in ["Preferences", "Standing decisions", "Delegation defaults", "Facts"] {
                XCTAssertNil(text(app, kind), "\(kind) is a note's kind, not its group")
            }
            XCTAssertNil(app.element("home-profile-confirm-all"), "No bulk confirmation")
            XCTAssertNil(app.element("home-profile-confirm-all-button"))
            let unsorted = try XCTUnwrap(app.element("home-profile-item-9a364c45-34fe-4f0a-93e6-fc507e2b0bdc"), app.tree())
            let label = unsorted.accessibilityLabel ?? ""
            XCTAssertTrue(label.contains("inferred/needs-split") && label.contains("Inferred"), label)
        }
    }

    private func text(_ app: MountedFixture, _ title: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            $0.isAccessibilityElement && ($0.accessibilityLabel == title || $0.accessibilityLabel.map { label in
                label.hasPrefix(title + ", ") && Int(label.dropFirst(title.count + 2)) != nil } == true)
                && !$0.accessibilityTraits.contains(.button)
        }
    }
}
