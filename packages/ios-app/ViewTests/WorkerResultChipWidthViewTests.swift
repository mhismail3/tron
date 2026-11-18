import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class WorkerResultChipWidthViewTests: ShuffledTestCase {
    func testWorkerResultChipTitleWidthLightDarkAndLargeText() async throws {
        for (scheme, large) in [("light", false), ("dark", false), ("light", true), ("dark", true)] {
            try await mounted(["-tron-subagent-parity-fixture", "-home-chip-labels", "-\(scheme)"]
                              + (large ? ["-accessibility-type"] : [])) { app in
                let longLabel = "Worker · Restructure 0.4: compare ownership metadata against every module manifest, Reported"
                let shortLabel = "Worker · Fix typo, Reported"
                @MainActor func chip(_ label: String) -> NSObject? {
                    MountedFixture.elements(in: app.top).last {
                        $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
                    }
                }
                try await app.until("the worker chips") { chip(longLabel) != nil && chip(shortLabel) != nil }
                _ = try await revealed(app, longLabel)
                let widths = try await app.still("the worker chips") {
                    guard let long = chip(longLabel), let short = chip(shortLabel) else { return nil }
                    return [Double(short.accessibilityFrame.width), Double(long.accessibilityFrame.width)]
                }
                XCTAssertLessThan(widths[0], widths[1], "A short title keeps its own width")
                XCTAssertLessThan(widths[1], Double(app.window.bounds.width - 40), "A long title stops short of the chat width")
                guard chip(longLabel)?.accessibilityActivate() == true else {
                    throw FixtureNotReady(description: "the long worker chip refused activation")
                }
                try await app.until("the worker result detail") {
                    MountedFixture.elements(in: app.top).contains {
                        $0.accessibilityLabel?.contains("every module manifest | outcome: final") == true
                    }
                }
            }
        }
    }
}
