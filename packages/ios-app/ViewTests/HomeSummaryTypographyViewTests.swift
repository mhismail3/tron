import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class HomeSummaryTypographyViewTests: ShuffledTestCase {
    func testHomeStatsUseSharedCodeTypographyAndScaleWithDynamicType() async throws {
        let fonts = FontSettings.shared
        let saved = (fonts.selectedFamily, fonts.selectedMonoFamily)
        fonts.selectedFamily = .sourceSerif4
        fonts.selectedMonoFamily = .jetBrainsMono
        defer { (fonts.selectedFamily, fonts.selectedMonoFamily) = saved }
        var heights: [CGFloat] = []
        for largeType in [false, true] {
            try await mounted(["-tron-home-summary-typography-fixture"] + (largeType ? ["-home-stats-large-type"] : [])) { app in
                try await app.until("the stats") { app.element("home-context-detail") != nil && app.element("home-stats-code-reference") != nil }
                let actual = app.element("home-context-detail")!, reference = app.element("home-stats-code-reference")!
                XCTAssertEqual(actual.accessibilityLabel, reference.accessibilityLabel, "Compare the same rendered stats, not unrelated text")
                let a = actual.accessibilityFrame, r = reference.accessibilityFrame
                let observed = "\(largeType ? "xxxLarge" : "large"): stats=\(a), code reference=\(r)"
                print("Home stats typography: \(observed)")
                XCTAssertEqual(a.width, r.width, accuracy: 0.5, "Stats must use shared code glyph advances; \(observed)")
                XCTAssertEqual(a.height, r.height, accuracy: 0.5, "Stats must use shared code line metrics; \(observed)")
                heights.append(a.height)
            }
        }
        XCTAssertEqual(heights.count, 2)
        if heights.count == 2 { XCTAssertGreaterThan(heights[1], heights[0], "Home stats must grow with Dynamic Type") }
    }
}
