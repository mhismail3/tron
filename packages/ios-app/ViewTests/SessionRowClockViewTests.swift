import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class SessionRowClockViewTests: ShuffledTestCase {
    func testDashboardMetadataUsesSharedCodeTypography() async throws {
        let fonts = FontSettings.shared
        let saved = (fonts.selectedFamily, fonts.selectedMonoFamily)
        fonts.selectedFamily = .sourceSerif4
        fonts.selectedMonoFamily = .jetBrainsMono
        defer { (fonts.selectedFamily, fonts.selectedMonoFamily) = saved }
        try await mounted(["-tron-session-row-clock-fixture", "-dashboard-row-typography"]) { app in
            @MainActor func subtitle(_ sample: String) -> NSObject? {
                MountedFixture.elements(in: app.top).first {
                    $0.isAccessibilityElement && $0.accessibilityLabel == sample && !$0.accessibilityTraits.contains(.button)
                        && !(MountedFixture.identifier($0) ?? "").hasPrefix("subtitle-reference-")
                }
            }
            let samples = ["iiiiiiii", "WWWWWWWW"]
            try await app.until("the typography rows") {
                samples.allSatisfy { sample in
                    subtitle(sample) != nil && app.element("timestamp-\(sample)") != nil
                        && app.element("subtitle-reference-\(sample)") != nil && app.element("timestamp-reference-\(sample)") != nil
                }
            }
            for sample in samples {
                for (actual, reference) in [(subtitle(sample)!, app.element("subtitle-reference-\(sample)")!),
                                            (app.element("timestamp-\(sample)")!, app.element("timestamp-reference-\(sample)")!)] {
                    XCTAssertEqual(actual.accessibilityFrame.width, reference.accessibilityFrame.width, accuracy: 0.5,
                                   "\(sample): metadata must use shared code glyph advances")
                    XCTAssertEqual(actual.accessibilityFrame.height, reference.accessibilityFrame.height, accuracy: 0.5,
                                   "\(sample): metadata must keep shared code caption metrics")
                }
            }
        }
    }

    func testRelativeTimeReadsNowAndKeepsOneWidthAsItTicks() async throws {
        try await mounted(["-tron-session-row-clock-fixture"]) { app in
            let prefix = "Refactor the gateway reconnect handshake so phones resume cleanly, "
            @MainActor func rows() -> [NSObject] {
                MountedFixture.elements(in: app.top).filter { $0.isAccessibilityElement && $0.accessibilityLabel?.hasPrefix(prefix) == true }
                    .sorted { $0.accessibilityFrame.minY < $1.accessibilityFrame.minY }
            }
            try await app.until("the session rows and the probe") {
                rows().count == 4 && app.element("row-clock-label") != nil && app.element("row-clock-label-width") != nil
            }
            XCTAssertEqual(rows().map { $0.accessibilityLabel?.components(separatedBy: ", ").last ?? "" }, ["now", "now", "12s ago", "47m ago"])
            let laidOut = app.element("row-clock-label-width")!.accessibilityLabel ?? ""
            XCTAssertGreaterThan(Double(laidOut) ?? 0, 0)
            var labels = [app.element("row-clock-label")!.accessibilityLabel ?? ""]
            for _ in 1..<8 {
                try await app.activate("row-clock-next")
                await MountedFixture.nextFrame()
                await MountedFixture.nextFrame()
                try await app.until("the probe label settles") { app.element("row-clock-label-width") != nil }
                labels.append(app.element("row-clock-label")!.accessibilityLabel ?? "")
                XCTAssertEqual(app.element("row-clock-label-width")!.accessibilityLabel, laidOut,
                               "laid-out width changed at \(labels.last ?? "")")
            }
            XCTAssertEqual(labels, ["now", "now", "now", "5s ago", "59s ago", "1m ago", "12m ago", "3h ago"])
        }
    }
}
