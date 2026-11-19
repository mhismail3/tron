import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class TaskToolSheetViewTests: ShuffledTestCase {
    func testStatusShowsRecordedWorkerCheckinAndSpend() async throws {
        try await mounted(["-tron-tool-sheets-polish-fixture", "-polish-scenario", "task-status",
                           "-polish-light", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]) { app in
            try await app.until("the task status sheet") { app.element("Technical details") != nil }
            XCTAssertTrue(MountedFixture.elements(in: app.top).contains {
                let label = $0.accessibilityLabel ?? ""
                return !$0.accessibilityTraits.contains(.button) && (label == "Keep Send disabled while photos prepare"
                    || label.hasPrefix("Keep Send disabled while photos prepare, "))
            }, app.tree())
            for (row, value) in [("Model", "Sol"), ("Check-in", "Attachment readiness now has one owner."), ("Tokens", "18K in")] {
                let node = try await revealed(app, "home-tool-row-\(row)")
                let label = (app.element("home-tool-row-\(row)") ?? node).accessibilityLabel ?? ""
                XCTAssertTrue(label.contains(value), "\(row) row: \(label)")
            }
        }
    }
}
