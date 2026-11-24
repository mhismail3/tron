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

    func testNestedSheetOpensAtItsOwnHeightAndClosingRestoresItsParent() async throws {
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

    func testEditingTheProviderKeyKeepsTheFittedHeight() async throws {
        try await mounted(["-tron-ask-user-fixture", "-tron-provider-key-fixture"]) { app in
            try await app.until("the provider-key review") { app.element("change-review-secret") != nil }
            try await app.waitForTopSheetToSettle()
            let field = try XCTUnwrap(MountedFixture.views(UITextField.self, in: app.top).first)
            let idle = try XCTUnwrap(mainScroll(app)).contentSize.height
            field.inputView = UIView(frame: .zero)
            field.inputAssistantItem.leadingBarButtonGroups = []
            field.inputAssistantItem.trailingBarButtonGroups = []
            XCTAssertTrue(field.becomeFirstResponder())
            field.insertText("sk-fixture-typed-key")
            for _ in 0..<30 { await MountedFixture.nextFrame() }
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
            try await app.waitForTopSheetToSettle()
            XCTAssertTrue(field.isFirstResponder, "the key field is still editing")
            XCTAssertEqual(try XCTUnwrap(mainScroll(app)).contentSize.height, idle, accuracy: 0.5,
                           "The key row keeps its height while its field editor is up")
            let trace = try await SheetTrace.record(app, frames: 90)
            trace.assertStill("Editing the provider key keeps the fitted height", against: app)
            try await assertFitted(app, "provider-key-editing")
            field.resignFirstResponder()
        }
    }

    func testParentSheetAndItsCardsStayStillWhileASubsheetComesAndGoes() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-expanded-review", "-six-ui-surface", "worker-report"]) { app in
            try await app.until("the report sheet") { app.button("Technical details") != nil && sheetChain(app).count == 1 }
            _ = try await app.still("the report sheet") { [Double(sheetFrame(app).minY)] }
            let parent = try XCTUnwrap(sheetChain(app).first)
            XCTAssertGreaterThan(sheetFrame(app).minY, 120, "the report sheet fits its content")
            @MainActor func bottomCard() -> CGRect? {
                MountedFixture.elements(in: parent.view).filter { MountedFixture.identifier($0) == "tron-sheet-surface" }
                    .map(\.accessibilityFrame).max { $0.maxY < $1.maxY }
            }
            let startCard = try XCTUnwrap(bottomCard(), "the bottom card")
            var ys: [CGFloat] = [], cards: [CGFloat] = []
            UIView.setAnimationsEnabled(true)
            defer { UIView.setAnimationsEnabled(false) }
            try await app.activate("Technical details")
            var closed = false
            for index in 0..<200 {
                let layer = parent.view.layer.presentation() ?? parent.view.layer
                ys.append(layer.convert(layer.bounds, to: nil).minY)
                if let card = bottomCard() { cards.append(card.height) }
                if !closed, index > 40, sheetChain(app).count == 2 { try await app.activate("Done"); closed = true }
                await MountedFixture.nextFrame()
            }
            let trace = "PARENT_TRACE " + ys.enumerated().filter { $0.offset == 0 || abs($0.element - ys[$0.offset - 1]) > 0.25 }
                .map { "\($0.offset):\(Int($0.element))" }.joined(separator: " ")
            print(trace)
            let deltas = zip(ys, ys.dropFirst()).map { $1 - $0 }.filter { abs($0) > 0.5 }
            let reversals = zip(deltas, deltas.dropFirst()).filter { ($0 > 0) != ($1 > 0) }.count
            XCTAssertTrue(closed, "the subsheet closed")
            XCTAssertEqual(reversals, 0, "The sheet under a subsheet moves monotonically, never up-down-up\n\(trace)")
            XCTAssertEqual(ys.last!, ys.first!, accuracy: 0.5, "The sheet under a subsheet returns to its own height\n\(trace)")
            XCTAssertTrue(cards.allSatisfy { abs($0 - startCard.height) <= 0.5 },
                          "The bottom card keeps its laid-out height on every frame: \(Set(cards.map { Int($0) }).sorted())")
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
        @MainActor func parentFrame() -> CGRect { parent.view.convert(parent.view.bounds, to: nil) }
        let parentStart = parentFrame()
        let depth = sheetChain(app).count
        UIView.setAnimationsEnabled(true)
        try await open()
        var parentFrames: [CGRect] = []
        let trace = try await SheetTrace.record(app, frames: 120, ready: { sheetChain(app).count == depth + 1 }) { _ in
            let layer = parent.view.layer.presentation() ?? parent.view.layer
            parentFrames.append(layer.convert(layer.bounds, to: nil))
        }
        let moved = parentFrames.filter { abs($0.minY - parentStart.minY) > 0.5 || abs($0.height - parentStart.height) > 0.5 }
        XCTAssertTrue(moved.isEmpty, "\(name): opening a nested sheet moved its parent from \(parentStart) to \(moved)")
        trace.assertStill("\(name): the nested sheet opens at its final height", against: app)
        try await assertFitted(app, "\(name)-over-parent")
        _ = sheetChain(app).last?.presentingViewController?.dismiss(animated: true)
        try await app.until("\(name) closes") { sheetChain(app).count == depth }
        try await app.waitForTopSheetToSettle()
        XCTAssertEqual(parentFrame().minY, parentStart.minY, accuracy: 0.5, "\(name): closing the nested sheet restores its parent")
        XCTAssertEqual(parentFrame().height, parentStart.height, accuracy: 0.5, "\(name): closing the nested sheet restores its parent")
    }

    func testPresentationPreferenceChangesKeepTheFittedHeight() async throws {
        try await mounted(["-tron-settings-fixture", "-dismiss-lock-sheet"]) { app in
            try await app.activate("Open Lock")
            try await app.until("the lock sheet") { app.element("Toggle lock") != nil }
            _ = try await app.still("the fitted lock sheet") { [Double(sheetFrame(app).minY)] }
            XCTAssertGreaterThan(sheetFrame(app).minY, 120, "the lock sheet fits its content")
            let toggle = try XCTUnwrap(app.button("Toggle lock"))
            let sheet = try XCTUnwrap(sheetChain(app).last)
            var locks: [Bool] = []
            let trace = try await SheetTrace.record(app, frames: 120, each: { index in
                if index % 20 == 10 { locks.append(sheet.isModalInPresentation) }
                if index % 20 == 0 { _ = toggle.accessibilityActivate() }
            })
            XCTAssertEqual(locks, [true, false, true, false, true, false], "Each toggle flips interactiveDismissDisabled")
            trace.assertStill("Toggling interactiveDismissDisabled keeps the fitted height", against: app)
        }
    }

    private func goUp(_ arguments: [String], frames: Int, _ check: (CGFloat, SheetTrace) -> Void) async throws {
        try await mounted(["-tron-settings-fixture", "-workspace-browser"] + arguments) { app in
            try await app.activate("Open Workspace")
            try await app.until("the four-folder listing") { app.element("Repo 4") != nil && app.element("Repo 5") == nil }
            _ = try await app.still("the fitted picker") { [Double(sheetFrame(app).minY)] }
            let start = sheetFrame(app).minY
            let goUp = try XCTUnwrap(MountedFixture.elements(in: app.top).last {
                $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("Go Up") == true
            })
            let trace = try await SheetTrace.record(app, frames: frames, each: { index in
                if index == 0 { _ = goUp.accessibilityActivate() }
            })
            XCTAssertLessThan(trace.final.minY, start - 100, "Go Up to twelve folders grows the sheet\n\(trace)")
            check(start, trace)
        }
    }

    func testReduceMotionAppliesHeightChangesAtOnce() async throws {
        try await goUp(["-reduce-motion"], frames: 60) { start, trace in
            let end = trace.final.minY
            let between = trace.samples.map(\.minY).filter { $0 < start - 1 && $0 > end + 1 }
            XCTAssertTrue(between.isEmpty, "Under Reduce Motion the sheet changes height without intermediate frames\n\(trace)")
        }
    }

    func testHeightChangesAfterOpeningAnimateWithTheContent() async throws {
        try await goUp([], frames: 90) { start, trace in
            let end = trace.final.minY
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
        let rest = samples.firstIndex { abs($0.minY - current) <= 0.5 } ?? samples.count
        let moves = samples[rest...].filter { abs($0.minY - current) > 0.5 }
        XCTAssertTrue(moves.isEmpty, "\(message): the sheet reached its height, then moved again\n\(self)", file: file, line: line)
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
