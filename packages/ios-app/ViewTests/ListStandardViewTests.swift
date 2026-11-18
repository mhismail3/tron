import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ListStandardViewTests: ShuffledTestCase {
    func testGroupedRowAnatomy() async throws {
        try await mounted(["-tron-agent-instructions-fixture"]) { app in
            try await app.until("the preamble row and its number") {
                app.element("agent-instructions-section-preamble") != nil && app.element("agent-instructions-section-preamble-leading") != nil
            }
            XCTAssertEqual(app.element("agent-instructions-section-preamble-leading")!.accessibilityFrame.midY,
                           app.element("agent-instructions-section-preamble")!.accessibilityFrame.midY, accuracy: 2,
                           "The number is centred vertically in the row")
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-chapters")
            try await app.activate("home-manage-chapters")
            try await app.until("the chapter row and its pill") { app.element("home-chapter-1") != nil && app.element("home-chapter-1-status") != nil }
            let chapter = app.element("home-chapter-1")!.accessibilityFrame, pill = app.element("home-chapter-1-status")!.accessibilityFrame
            XCTAssertGreaterThan(pill.maxX, chapter.maxX - 24, "The pill is at the trailing edge")
            XCTAssertLessThan(pill.minY - chapter.minY, 20, "The pill is on the title line")
            XCTAssertNil(app.element("home-chapter-1-leading"), "Chapters carry no repeated icon")
        }
    }

    func testGroupedSectionsAreSeparateContainersWithHeadersAbove() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-profile")
            try await app.activate("home-manage-profile")
            try await app.until("Profile opens") { app.element("home-profile-items") != nil }
            try await app.expandTopSheet()
            let list = "home-profile-items", titles = ["Communication", "Machines, devices & services"]
            let rowID = "home-profile-item-6a26bfb7-f0d1-44ce-b0ae-9da01da3e55c"
            try await app.until("the sections") {
                (0..<titles.count).allSatisfy { app.element("\(list)-header-\($0)") != nil && app.element("\(list)-section-\($0)") != nil }
                    && app.element(rowID) != nil
            }
            var previousBottom: CGFloat?
            for (index, title) in titles.enumerated() {
                let headerNode = app.element("\(list)-header-\(index)")!
                let header = headerNode.accessibilityFrame, section = app.element("\(list)-section-\(index)")!.accessibilityFrame
                let label = headerNode.accessibilityLabel ?? ""
                XCTAssertTrue(label.hasPrefix(title) && label.rangeOfCharacter(from: .decimalDigits) != nil,
                              "The header names \(title) and its count: \(label)")
                XCTAssertLessThanOrEqual(header.maxY, section.minY + 0.5, "\(title)'s header sits above its container")
                XCTAssertEqual(header.minX, section.minX, accuracy: 1, "\(title)'s header starts on the container's leading edge")
                XCTAssertEqual(header.maxX, section.maxX, accuracy: 1, "\(title)'s count ends on the container's trailing edge")
                if let previousBottom {
                    XCTAssertGreaterThan(header.minY - previousBottom, 8, "\(title) starts apart from the previous container")
                }
                previousBottom = section.maxY
            }
            let first = app.element("\(list)-section-0")!.accessibilityFrame
            let row = try XCTUnwrap(MountedFixture.elements(in: app.top).last {
                MountedFixture.identifier($0) == rowID && $0.accessibilityTraits.contains(.button)
            }, app.tree())
            XCTAssertTrue(first.contains(row.accessibilityFrame.insetBy(dx: 1, dy: 1)), "The first row is inside the first container")
        }
    }
}
