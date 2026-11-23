import UIKit
import XCTest
@testable import TronMobile

@MainActor
final class ContentFitSheetViewTests: ShuffledTestCase {
    func testToolsSheetOpensAtItsFinalHeight() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", "worker-tools-short"]) { app in
            let trace = try await SheetTrace.record(app, frames: 90)
            trace.assertStill("Tools opens at its final content height")
            XCTAssertGreaterThan(trace.final.minY, app.window.bounds.height * 0.4, "Two tools fit, so the sheet does not open large\n\(trace)")
        }
    }

    func testAccessibilityTextOpensLarge() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", "worker-tools-short"],
                          contentSize: .accessibilityExtraExtraExtraLarge) { app in
            let trace = try await SheetTrace.record(app, frames: 60)
            trace.assertStill("Accessibility text opens large")
            XCTAssertLessThan(trace.final.minY, 120, "\(trace)")
        }
    }

    func testOverflowingSheetOpensLargeWithoutResizing() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", "worker-thinking-long"]) { app in
            let trace = try await SheetTrace.record(app, frames: 90)
            trace.assertStill("An overflowing sheet opens large")
            XCTAssertLessThan(trace.final.minY, 120, "\(trace)")
        }
    }

    func testManageHomeShowsItsStructureBeforeDataAndKeepsItsHeight() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-presentation-loading"]) { app in
            try await app.activate("home-pinned-row")
            UIView.setAnimationsEnabled(true)
            try await app.activate("session-context-button")
            let structure = ["home-context-summary", "home-model-summary", "home-manage-tasks", "home-manage-controls"]
            var opened: [String: Bool] = [:]
            let trace = try await SheetTrace.record(app, frames: 240, ready: { app.element("home-sheet-done-manage") != nil }) { index in
                if index == 0 {
                    for id in structure + ["sheet-loading", "home-manage-placeholder"] { opened[id] = app.element(id) != nil }
                }
                if index == 20 {
                    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName(rawValue: "com.tron.mobile.fixture.home.release-task-list" as CFString), nil, nil, true)
                }
            }
            for id in structure { XCTAssertEqual(opened[id], true, "\(id) is laid out in the first presented frame") }
            XCTAssertEqual(opened["home-manage-placeholder"], true, "Loading content uses the shared placeholder style")
            XCTAssertEqual(opened["sheet-loading"], false, "Manage Home shows its structure, not a sheet-wide pulse")
            try await app.until("Home data arrives") { app.element("home-manage-state") != nil && app.element("home-manage-placeholder") == nil }
            trace.assertStill("Arriving data fills the placeholders without resizing the sheet", against: app)
        }
    }
}

struct SheetTrace: CustomStringConvertible {
    struct Sample { let frame: Int; let minY: CGFloat; let height: CGFloat; let scroll: String }
    let samples: [Sample]
    var final: Sample { samples.last! }

    @MainActor static func record(_ app: MountedFixture, frames: Int, ready: () -> Bool = { true },
                                  each: (Int) -> Void = { _ in }) async throws -> SheetTrace {
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(false) }
        var waited = 0
        while !(ready() && presented(app)) {
            waited += 1
            guard waited < MountedFixture.hangFrames else { throw FixtureNotReady(description: "the sheet never presented") }
            await MountedFixture.nextFrame()
        }
        var samples: [Sample] = []
        for index in 0..<frames {
            each(index)
            let layer = app.top.layer.presentation() ?? app.top.layer
            let frame = layer.convert(layer.bounds, to: nil)
            let scroll = MountedFixture.views(UIScrollView.self, in: app.top).filter { $0.bounds.height > 100 }.map {
                "content \($0.contentSize.height) inset \($0.adjustedContentInset.top)/\($0.adjustedContentInset.bottom) bounds \($0.bounds.height)"
            }.joined(separator: ";")
            samples.append(Sample(frame: index, minY: frame.minY, height: frame.height, scroll: scroll))
            await MountedFixture.nextFrame()
        }
        let trace = SheetTrace(samples: samples)
        print(trace)
        return trace
    }

    @MainActor private static func presented(_ app: MountedFixture) -> Bool {
        let frame = app.top.convert(app.top.bounds, to: nil)
        return frame.minY > 0 && frame.minY < app.window.bounds.height
    }

    @MainActor func assertStill(_ message: String, against app: MountedFixture? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let current = app.map { $0.top.convert($0.top.bounds, to: nil).minY } ?? final.minY
        XCTAssertEqual(final.minY, current, accuracy: 0.5, "\(message): the sheet resized after the trace\n\(self)", file: file, line: line)
        let overshoot = samples.filter { $0.minY < current - 0.5 }
        XCTAssertTrue(overshoot.isEmpty, "\(message): the sheet rose above its final height, then shrank\n\(self)", file: file, line: line)
        let rises = zip(samples, samples.dropFirst()).filter { $1.minY > $0.minY + 0.5 }
        XCTAssertTrue(rises.isEmpty, "\(message): the sheet moved down after it began opening\n\(self)", file: file, line: line)
    }

    var description: String {
        var runs: [String] = []
        var previous: Sample?
        for sample in samples where previous.map({ abs($0.minY - sample.minY) > 0.25 || $0.scroll != sample.scroll }) ?? true {
            runs.append("frame \(sample.frame): minY \(sample.minY) height \(sample.height) [\(sample.scroll)]")
            previous = sample
        }
        return "SHEET_TRACE " + runs.joined(separator: " | ")
    }
}
