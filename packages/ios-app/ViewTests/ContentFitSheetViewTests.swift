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

    func testFittedSheetsNeitherScrollNorClipTheirContent() async throws {
        for surface in ["worker-tools-short", "worker-thinking"] {
            try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", surface]) { app in
                try await assertFitted(app, surface)
            }
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            try await assertFitted(app, "manage-home")
        }
    }

    func testBottomCardIsConcentricWithTheSheet() async throws {
        for surface in ["worker-tools-short", "worker-report"] {
            try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", surface]) { app in
                try await assertConcentricBottom(app, surface)
            }
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            try await assertConcentricBottom(app, "manage-home")
        }
    }

    func testArtifactsOpensAtItsFinalHeightWithEveryRowInside() async throws {
        for delayed in [false, true] {
            try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts"] + (delayed ? ["-artifacts-delay"] : [])) { app in
                try await app.activate("Artifacts")
                var placeholder = false
                let trace = try await SheetTrace.record(app, frames: 150, ready: { app.element("Done") != nil }) { index in
                    if index == 0 { placeholder = app.element("artifacts-placeholder") != nil }
                }
                if delayed { XCTAssertTrue(placeholder, "Artifacts lays out placeholder rows while it loads") }
                trace.assertStill("Artifacts opens at its final height", against: app)
                try await app.until("the artifact rows") { app.element("artifact-card-usage-dashboard-container") != nil }
                try await assertFitted(app, "artifacts\(delayed ? "-delayed" : "")")
            }
        }
    }

    func testNestedSheetLeavesItsParentStillAndOpensAtItsFinalHeight() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-nested", "-settings-expanded-review"]) { app in
            try await app.activate("Open Settings")
            _ = try await revealed(app, "settings-link-Connections")
            try await assertNested(app, "settings-connections") { try await app.activate("settings-link-Connections") }
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            _ = try await revealed(app, "home-manage-controls")
            try await assertNested(app, "manage-home-controls") { try await app.activate("home-manage-controls") }
        }
    }

    private func sheetChain(_ app: MountedFixture) -> [UIViewController] {
        var chain: [UIViewController] = []
        var next = app.window.rootViewController?.presentedViewController
        while let controller = next, !controller.isBeingDismissed { chain.append(controller); next = controller.presentedViewController }
        return chain
    }

    private func assertNested(_ app: MountedFixture, _ name: String, open: () async throws -> Void) async throws {
        try await app.until("\(name) parent settles") { true }
        let parent = try XCTUnwrap(sheetChain(app).last)
        let parentHeight = parent.view.bounds.height
        let depth = sheetChain(app).count
        UIView.setAnimationsEnabled(true)
        try await open()
        var parentHeights: [CGFloat] = []
        let trace = try await SheetTrace.record(app, frames: 120, ready: { sheetChain(app).count == depth + 1 }) { _ in
            parentHeights.append(parent.view.bounds.height)
        }
        let moved = parentHeights.filter { abs($0 - parentHeight) > 0.5 }
        let rest = trace.samples.firstIndex { sample in abs(sample.minY - trace.final.minY) <= 0.5 } ?? trace.samples.count
        let jumps = trace.samples[rest...].filter { abs($0.minY - trace.final.minY) > 0.5 }
        XCTAssertTrue(jumps.isEmpty, "\(name): the nested sheet reached its height, then moved again\n\(trace)")
        XCTAssertTrue(moved.isEmpty, "\(name): opening a nested sheet resized its parent from \(parentHeight) to \(Set(moved))")
        trace.assertStill("\(name): the nested sheet opens at its final height", against: app)
    }

    func testHeightChangesAfterOpeningAnimateWithTheContent() async throws {
        try await mounted(["-tron-settings-fixture", "-workspace-browser"]) { app in
            try await app.activate("Open Workspace")
            try await app.until("the four-folder listing") { app.element("Repo 4") != nil && app.element("Repo 5") == nil }
            _ = try await app.still("the fitted picker") { [Double(sheetFrame(app).minY)] }
            let start = sheetFrame(app).minY
            let goUp = try XCTUnwrap(MountedFixture.elements(in: app.top).last {
                $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Go Up") == true
            })
            let trace = try await SheetTrace.record(app, frames: 90, each: { index in
                if index == 0 { _ = goUp.accessibilityActivate() }
            })
            let end = trace.final.minY
            XCTAssertLessThan(end, start - 100, "Go Up to twelve folders grows the sheet\n\(trace)")
            let steps = zip(trace.samples, trace.samples.dropFirst()).map { abs($1.minY - $0.minY) }
            XCTAssertLessThan(steps.max() ?? .infinity, (start - end) * 0.5,
                              "The sheet grows continuously, never in one frame\n\(trace)")
            let between = Set(trace.samples.map(\.minY).filter { $0 < start - 1 && $0 > end + 1 }.map { Int($0) })
            XCTAssertGreaterThanOrEqual(between.count, 4, "The resize passes through intermediate heights\n\(trace)")
        }
    }

    private func sheetFrame(_ app: MountedFixture) -> CGRect { app.top.convert(app.top.bounds, to: nil) }

    private func mainScroll(_ app: MountedFixture) -> UIScrollView? {
        let width = sheetFrame(app).width
        return MountedFixture.views(UIScrollView.self, in: app.top)
            .filter { $0.bounds.height > 100 && $0.bounds.width > width * 0.8 }.max { $0.bounds.height < $1.bounds.height }
    }

    private func settle(_ app: MountedFixture, _ name: String) async throws {
        _ = try await app.still("\(name) layout") {
            guard let scroll = mainScroll(app) else { return nil }
            return [scroll.contentSize.height, scroll.adjustedContentInset.bottom, scroll.bounds.height, sheetFrame(app).minY].map { Double($0) }
        }
    }

    private func assertFitted(_ app: MountedFixture, _ name: String) async throws {
        try await settle(app, name)
        capture(app, name)
        let sheet = sheetFrame(app)
        XCTAssertGreaterThan(sheet.minY, 120, "\(name) fits its content")
        let scroll = try XCTUnwrap(mainScroll(app))
        let needed = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
        XCTAssertLessThanOrEqual(needed, scroll.bounds.height + 0.5,
            "\(name): a fitted sheet must not scroll (content \(scroll.contentSize.height), insets \(scroll.adjustedContentInset), bounds \(scroll.bounds.height))")
    }

    private func assertConcentricBottom(_ app: MountedFixture, _ name: String) async throws {
        try await app.until("\(name) presents") { app.button("Done") != nil || app.element("home-sheet-done-manage") != nil }
        try await settle(app, name)
        capture(app, "\(name)-corners")
        let surfaces = MountedFixture.elements(in: app.top).filter {
            let id = MountedFixture.identifier($0) ?? ""
            return id == "tron-sheet-surface" || id.hasPrefix("tool-run-summary-")
        }
            .map(\.accessibilityFrame)
        let card = try XCTUnwrap(surfaces.max { $0.maxY < $1.maxY }, "\(name) has a card")
        let sheet = sheetFrame(app)
        XCTAssertGreaterThan(sheet.minY, 120, "\(name) fits its content")
        XCTAssertEqual(sheet.maxY - card.maxY, card.minX - sheet.minX, accuracy: 1,
                       "\(name): the bottom card's concentric corners share the sheet's corner centres only when its bottom gap equals its side gap; card \(card) sheet \(sheet)")
    }

    private func capture(_ app: MountedFixture, _ name: String) {
        let shot = XCTAttachment(image: app.render())
        shot.name = "sheet-\(name)"; shot.lifetime = .keepAlways; add(shot)
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
