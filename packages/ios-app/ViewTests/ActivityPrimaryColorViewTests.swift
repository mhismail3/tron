import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ActivityPrimaryColorViewTests: ShuffledTestCase {
    func testActivityInkFollowsPrimaryThemeLightAndDark() async throws {
        for theme in [ThemeColor.burgundy, .emerald, .oliveGold] {
            for mode in ["light", "dark"] {
                try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-phase-active",
                                   "-home-sheet-dashboard-workers", "-dashboard-view-home"] + (mode == "dark" ? ["-home-dark"] : []),
                                  theme: theme) { app in
                    try await app.until("the dashboard is working") { app.element("dashboard.menu")?.accessibilityValue == "Working" }
                    let home = try XCTUnwrap(app.element("dashboard.menu"))
                    let title = try XCTUnwrap(app.element("dashboard.title"))
                    try await compareInk(app, icon: centered(home.accessibilityFrame, size: 28),
                                         reference: title.accessibilityFrame, name: "dashboard-\(theme)-\(mode)")
                }
                for state in ["active", "recent", "extension"] {
                    try await mounted(["-tron-subagent-parity-fixture", "-\(mode)"]
                                      + (state == "active" ? [] : ["-activity-preview-\(state)"]), theme: theme) { app in
                        let label = state == "extension" ? "Extension content" : "Subagents"
                        var orb: NSObject?
                        try await app.until("the \(state) activity button") {
                            orb = MountedFixture.elements(in: app.top).first {
                                $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
                            }
                            return orb != nil
                        }
                        let plus = try XCTUnwrap(app.element("Add attachment"))
                        try await compareInk(app, icon: centered(try XCTUnwrap(orb).accessibilityFrame, size: 18),
                                             reference: centered(plus.accessibilityFrame, size: 20),
                                             name: "composer-\(state)-\(theme)-\(mode)")
                    }
                }
            }
        }
    }

    func testComposerPlaceholderIsDimmedPrimaryInk() async throws {
        for theme in [ThemeColor.burgundy, .emerald] {
            for mode in ["light", "dark"] {
                try await mounted(["-tron-subagent-parity-fixture", "-\(mode)"], theme: theme) { app in
                    try await app.until("the composer") { app.element("Add attachment") != nil }
                    let plus = try XCTUnwrap(app.element("Add attachment")).accessibilityFrame
                    let field = CGRect(x: plus.maxX + 12, y: plus.midY - 14, width: 220, height: 28)
                    _ = try await app.still("\(theme)-\(mode) placeholder") { inkChroma(app, field) }
                    let image = app.render()
                    guard let placeholder = inkChroma(app, field, image: image),
                          let reference = inkChroma(app, centered(plus, size: 20), image: image) else {
                        return XCTFail("\(theme)-\(mode): placeholder ink has no theme chroma (grey?)")
                    }
                    let distance = zip(placeholder, reference).map { abs($0 - $1) }.max()!
                    XCTAssertLessThan(distance, 0.2, "\(theme)-\(mode): placeholder \(placeholder) must share the primary hue \(reference)")
                }
            }
        }
    }

    private func centered(_ frame: CGRect, size: CGFloat) -> CGRect {
        CGRect(x: frame.midX - size / 2, y: frame.midY - size / 2, width: size, height: size)
    }

    private func compareInk(_ app: MountedFixture, icon: CGRect, reference: CGRect, name: String) async throws {
        _ = try await app.still("\(name) icon ink") { inkChroma(app, icon) }
        let image = app.render()
        guard let actual = inkChroma(app, icon, image: image), let expected = inkChroma(app, reference, image: image) else {
            return XCTFail("No saturated icon/reference ink in \(name)")
        }
        let distance = zip(actual, expected).map { abs($0 - $1) }.max()!
        print("ACTIVITY_INK \(name): icon=\(actual) primary=\(expected) distance=\(distance)")
        XCTAssertLessThan(distance, 0.15, "\(name): rendered activity ink \(actual) must match primary reference \(expected)")
    }

    private func inkChroma(_ app: MountedFixture, _ area: CGRect, image: UIImage? = nil) -> [Double]? {
        app.chroma(area, range: 28, image: image).flatMap { $0.count >= 5 ? $0.ink : nil }
    }
}
