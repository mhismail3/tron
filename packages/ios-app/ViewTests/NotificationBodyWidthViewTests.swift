import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class NotificationBodyWidthViewTests: ShuffledTestCase {
    func testNotificationBodyFillsSheetWidth() async throws {
        for scheme in ["light", "dark"] {
            try await mounted(["-tron-subagent-parity-fixture", "-presentation-polish", "-\(scheme)"]
                              + (scheme == "dark" ? ["-accessibility-type"] : [])) { app in
                @MainActor func errors() -> [NSObject] {
                    MountedFixture.elements(in: app.top).filter {
                        $0.accessibilityLabel == "Tron · Notification, Error" && $0.accessibilityTraits.contains(.button)
                    }.sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY }
                }
                try await app.until("the error notifications") { !errors().isEmpty }
                XCTAssertEqual(errors().count, 2, app.tree())
                for index in 0..<2 {
                    guard errors()[index].accessibilityActivate() else {
                        throw FixtureNotReady(description: "error notification \(index) refused activation")
                    }
                    let text = index == 0 ? "HTTP 429" : "Long error context"
                    try await app.until("the notification detail") {
                        MountedFixture.elements(in: app.top).contains {
                            !$0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains(text) == true
                        }
                    }
                    let widths = try await app.still("the notification card") {
                        guard let card = app.element("chat-notification-body") else { return nil }
                        let frame = card.accessibilityFrame
                        let viewport = MountedFixture.views(UIScrollView.self, in: app.top)
                            .filter { !($0 is UITextView) && $0.window != nil }
                            .map { $0.convert($0.bounds, to: nil) }
                            .filter { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
                            .max { $0.width < $1.width }
                        return viewport.map { [Double(frame.width), Double($0.width)] }
                    }
                    XCTAssertGreaterThanOrEqual(widths[0], widths[1] - 40, "Short and long cards use the same standard content width")
                    try await app.activate("Done")
                    try await app.until("the notification detail closes") { app.element("chat-notification-body") == nil }
                }
            }
        }
    }
}
