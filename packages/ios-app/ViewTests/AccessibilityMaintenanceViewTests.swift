import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class AccessibilityMaintenanceViewTests: ShuffledTestCase {
    func testMaintenanceActionGeometry() async throws {
        try await mounted(["-tron-accessibility-fixture", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
            try await app.activate("Maintenance")
            let frames = try await actionFrames(app, ["Rebuild from Source", "Roll Back", "Restart", "Disable", "Forget Server"])
            XCTAssertEqual(frames[0].minX, frames[2].minX, accuracy: 1)
            XCTAssertEqual(frames[1].minX, frames[3].minX, accuracy: 1)
            XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
            XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
            XCTAssertEqual(frames[2].minY, frames[3].minY, accuracy: 1)
            XCTAssertGreaterThan(frames[2].minY, frames[0].maxY)
            XCTAssertGreaterThan(frames[4].width, frames[0].width * 1.5)
            XCTAssertGreaterThan(frames[4].minY, frames[2].maxY)
        }
    }

    func testLoneMaintenanceActionUsesFullContentWidth() async throws {
        for arguments in [[], ["-fixture-light"], ["-fixture-large-type"]] {
            try await mounted(["-tron-accessibility-fixture", "-fixture-lone-maintenance", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                              + arguments) { app in
                try await app.activate("Maintenance")
                let labels = ["Rebuild from Source", "Restart", "Disable", "Forget Server"]
                let frames = try await actionFrames(app, labels)
                XCTAssertEqual(frames[2].minX, frames[3].minX, accuracy: 1)
                XCTAssertEqual(frames[2].maxX, frames[3].maxX, accuracy: 1, "Disable must reach the same trailing edge as Forget Server")
                XCTAssertEqual(frames[2].width, frames[3].width, accuracy: 1)
                XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
                XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
                XCTAssertGreaterThan(frames[2].minY, max(frames[0].maxY, frames[1].maxY))
                XCTAssertGreaterThan(frames[3].minY, frames[2].maxY)
                for label in labels {
                    let frame = try XCTUnwrap(button(app, label)).accessibilityFrame
                    XCTAssertTrue(app.window.bounds.contains(frame), "\(label) is on screen")
                    XCTAssertGreaterThanOrEqual(frame.height, 44)
                }
            }
        }
    }

    private func actionFrames(_ app: MountedFixture, _ labels: [String]) async throws -> [CGRect] {
        try await app.until("the maintenance actions") { labels.allSatisfy { button(app, $0) != nil } }
        return labels.map { button(app, $0)!.accessibilityFrame }
    }

    private func button(_ app: MountedFixture, _ label: String) -> NSObject? {
        MountedFixture.elements(in: app.top).last { $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button) }
    }
}
