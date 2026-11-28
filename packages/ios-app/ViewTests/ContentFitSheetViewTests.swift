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

    func testManageHomeShowsItsStructureBeforeDataAndKeepsItsHeight() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-sheet-presentation-loading"]) { app in
            try await app.activate("home-pinned-row")
            UIView.setAnimationsEnabled(true)
            try await app.activate("session-context-button")
            let structure = ["home-context-summary", "home-model-summary", "home-manage-tasks"]
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

    func testScrollingFeedShowsThePositionChipWhereItRests() async throws {
        try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts", "-artifacts-reports", "40"]) { app in
            try await app.activate("Artifacts")
            var chips: [CGFloat?] = []
            let trace = try await SheetTrace.record(app, frames: 150, ready: { app.element("Done") != nil }) { _ in
                chips.append(app.element("feed-position-chip").map { $0.accessibilityFrame.maxY - sheetFrame(app).maxY })
            }
            try await app.waitForTopSheetToSettle()
            try await settle(app, "artifacts-40")
            let rests = app.element("feed-position-chip").map { $0.accessibilityFrame.maxY - sheetFrame(app).maxY }
            let scroll = try XCTUnwrap(mainScroll(app))
            let scrolls = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height + 1
            let log = "chip offsets per frame: \(chips.map { $0.map { "\(Int($0))" } ?? "-" }.joined(separator: " "))\n\(trace)"
            XCTAssertTrue(scrolls, "Forty reports scroll in the full-height sheet")
            let rest = try XCTUnwrap(rests, "A feed that scrolls shows the position chip\n\(log)")
            let first = try XCTUnwrap(chips.firstIndex { $0 != nil }, "The chip appears while the sheet opens\n\(log)")
            XCTAssertTrue(chips[first...].allSatisfy { $0.map { abs($0 - rest) <= 0.5 } ?? false },
                          "Once shown, the chip stays at its resting position on every frame\n\(log)")
        }
    }

    func testFeedThatFitsItsViewportNeverShowsThePositionChip() async throws {
        for delayed in [false, true] {
            try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts", "-artifacts-reports", "2"] + (delayed ? ["-artifacts-delay"] : [])) { app in
                try await app.activate("Artifacts")
                var chips: [Bool] = []
                let trace = try await SheetTrace.record(app, frames: 150, ready: { app.element("Done") != nil }) { _ in
                    chips.append(app.element("feed-position-chip") != nil)
                }
                try await app.until("the report rows") { MountedFixture.elements(in: app.top).contains { (MountedFixture.identifier($0) ?? "").hasSuffix("_report-1-container") } }
                try await settle(app, "artifacts-2\(delayed ? "-delayed" : "")")
                let scroll = try XCTUnwrap(mainScroll(app))
                let needed = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
                XCTAssertLessThanOrEqual(needed, scroll.bounds.height + 0.5, "Two reports fit their viewport (delayed \(delayed))\n\(trace)")
                XCTAssertNil(app.element("feed-position-chip"), "A feed that fits its viewport shows no position chip (delayed \(delayed))\n\(trace)")
                XCTAssertFalse(chips.contains(true), "A feed that fits never shows the chip while its sheet opens (delayed \(delayed)): \(chips.map { $0 ? "C" : "-" }.joined())\n\(trace)")
            }
        }
    }

    func testArtifactsNearTheFitBoundaryKeepTheirHeightAndChipStill() async throws {
        for reports in 7...12 {
            try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts", "-artifacts-reports", "\(reports)"]) { app in
                try await app.activate("Artifacts")
                var chips: [CGFloat?] = []
                let trace = try await SheetTrace.record(app, frames: 150, ready: { app.element("Done") != nil }) { _ in
                    chips.append(app.element("feed-position-chip").map { $0.accessibilityFrame.maxY - sheetFrame(app).maxY })
                }
                let log = "\(reports) reports; chip offsets per frame: \(chips.map { $0.map { "\(Int($0))" } ?? "-" }.joined(separator: " "))\n\(trace)"
                trace.assertStill("\(reports) reports open at their final height", against: app)
                try await settle(app, "artifacts-\(reports)")
                let scroll = try XCTUnwrap(mainScroll(app))
                let overflows = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height + 0.5
                let rest = app.element("feed-position-chip").map { $0.accessibilityFrame.maxY - sheetFrame(app).maxY }
                XCTAssertEqual(rest != nil, overflows, "The chip shows exactly when the feed overflows its viewport\n\(log)")
                let first = chips.firstIndex { $0 != nil } ?? chips.endIndex
                XCTAssertTrue(chips[first...].allSatisfy { chip in chip.map { abs($0 - (rest ?? .nan)) <= 0.5 } ?? false },
                              "Once shown, the chip never hides or moves while the sheet opens\n\(log)")
            }
        }
    }

    func testFittedArtifactsMeasureTheSameContentWhateverTheirViewport() async throws {
        for (tools, days) in [(1, [1, 1, 2, 3]), (2, [1, 1, 2, 3, 3, 4])] {
            var measured: [String: Int] = [:]
            for band in ["0", "34", "120", "300"] {
                try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts", "-artifacts-tools", "\(tools)",
                                   "-artifacts-scroll-above-home-indicator", band,
                                   "-artifacts-reports", "\(days.count)", "-artifacts-report-days", days.map(String.init).joined(separator: ",")]) { app in
                    try await app.activate("Artifacts")
                    try await app.until("the listing") { MountedFixture.elements(in: app.top).contains { (MountedFixture.identifier($0) ?? "").hasSuffix("_report-0-container") } }
                    try await settle(app, "band \(band)")
                    XCTAssertGreaterThan(sheetFrame(app).minY, 120, "band \(band): the sheet is fitted")
                    measured[band] = Int(try XCTUnwrap(mainScroll(app)).contentSize.height.rounded())
                }
            }
            XCTAssertEqual(Set(measured.values).count, 1, "\(tools) tools, reports on days \(days): a fitted feed's content height must not depend on how much of it is in view, or the sheet's detent chases it: \(measured)")
        }
    }

    func testNestedSheetFitsItsOwnContentWhileItsParentStepsBackUnresized() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-nested", "-settings-expanded-review"]) { app in
            try await app.activate("Open Settings")
            _ = try await revealed(app, "settings-link-Connections")
            try await assertNested(app, "settings-connections") { try await app.activate("settings-link-Connections") }
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready"]) { app in
            try await openManageHome(app)
            try await app.until("the Disable Home toolbar control") { app.element("home-manage-disable") != nil }
            try await assertNested(app, "manage-home-disable-confirmation") { try await app.activate("home-manage-disable") }
        }
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-browser-loading"]) { app in
            try await openManageHome(app)
            try await app.activate("home-manage-memory-browser")
            try await app.until("the memory list loads") { app.element("home-memory-row-39") != nil }
            try await app.waitForTopSheetToSettle()
            XCTAssertLessThan(sheetFrame(app).minY, 120, "the memory list is a full-height parent")
            try await assertNested(app, "memory-item-over-large-list") { try await app.activate("home-memory-row-39") }
        }
    }

    func testSwipeDownDismissesOnlyTheTopSheet() async throws {
        try await mounted(["-tron-settings-fixture", "-settings-nested", "-settings-expanded-review"]) { app in
            try await app.activate("Open Settings")
            try await app.until("Settings opens") { sheetChain(app).count == 1 }
            try await app.waitForTopSheetToSettle()
            _ = try await revealed(app, "settings-link-Connections")
            let parentStart = rendered(sheetChain(app)[0])
            try await app.activate("settings-link-Connections")
            try await app.until("Connections over Settings") { sheetChain(app).count == 2 }
            try await app.waitForTopSheetToSettle()
            let drag = try XCTUnwrap(HostedPresentationProbe.sheetDrag, "the sheet presenter takes drags")
            let parent = sheetChain(app)[0], child = sheetChain(app)[1]
            let childStart = rendered(child)
            UIView.setAnimationsEnabled(true)
            defer { UIView.setAnimationsEnabled(false) }
            drag(child, .began, 0, 0)
            for step in 1...6 {
                drag(child, .changed, CGFloat(step) * 8, 0)
                await MountedFixture.nextFrame()
            }
            XCTAssertEqual(rendered(child).minY, childStart.minY + 48, accuracy: 1, "The top sheet follows the finger down")
            XCTAssertEqual(rendered(child).height, childStart.height, accuracy: 0.5, "A dragged sheet keeps its height")
            drag(child, .ended, 48, 0)
            try await app.until("a short slow drag springs back") { sheetChain(app).count == 2 && abs(rendered(child).minY - childStart.minY) <= 0.5 }
            drag(child, .began, 0, 0)
            drag(child, .changed, 40, 0)
            await MountedFixture.nextFrame()
            drag(child, .ended, 40, 1800)
            try await app.until("a flick dismisses the top sheet") { sheetChain(app).count == 1 }
            try await app.waitForTopSheetToSettle()
            XCTAssertTrue(sheetChain(app).first === parent, "Only the top sheet closes; its parent stays presented")
            XCTAssertEqual(rendered(parent).minY, parentStart.minY, accuracy: 0.5, "The parent is restored where it rested")
            XCTAssertEqual(rendered(parent).width, parentStart.width, accuracy: 0.5, "The parent is restored to its width")
            UIView.setAnimationsEnabled(false)
            try await app.activate("settings-link-Connections")
            try await app.until("the swiped-away sheet opens again") { sheetChain(app).count == 2 }
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

    func testQuestionPagesAreMeasuredBeforeTheSwipeAndTheSheetFollowsTheTurn() async throws {
        try await mounted(["-tron-ask-user-fixture", "-tron-ask-user-four-pages", "-tron-ask-user-styled"]) { app in
            try await app.until("the form") { app.element("Submit all answers") != nil }
            try await app.waitForTopSheetToSettle()
            @MainActor func pages() -> [UIScrollView] {
                MountedFixture.views(UIScrollView.self, in: app.top).filter { $0.bounds.width > 300 && $0.contentSize.height > 100 }
            }
            for turn in 1...3 {
                _ = try await app.still("page \(turn) settled") { [Double(sheetFrame(app).minY)] }
                XCTAssertEqual(pages().count, 4, "Turn \(turn): every page is laid out and measured before the finger moves")
                let drag = try XCTUnwrap(HostedPresentationProbe.questionPageDrag)
                let steps = 12
                var dragYs: [CGFloat] = []
                let trace = try await SheetTrace.record(app, frames: steps + 60, each: { index in
                    if index == 0 { drag(.began, -1, 0) }
                    if index > 0, index <= steps { drag(.changed, -CGFloat(index) * 22, 0) }
                    if index == steps + 1 { drag(.ended, -CGFloat(steps) * 22, -600) }
                    if index <= steps { dragYs.append(sheetFrame(app).minY) }
                })
                XCTAssertTrue(dragYs.allSatisfy { abs($0 - dragYs[0]) <= 0.5 }, "Turn \(turn): the sheet keeps its height under the finger: \(dragYs.map { Int($0) })")
                let moves = zip(trace.samples, trace.samples.dropFirst()).map { $1.minY - $0.minY }.filter { abs($0) > 0.5 }
                XCTAssertTrue(zip(moves, moves.dropFirst()).allSatisfy { ($0 > 0) == ($1 > 0) },
                              "Turn \(turn): the sheet takes the new page's height in one move\n\(trace)")
                XCTAssertEqual(trace.final.minY, sheetFrame(app).minY, accuracy: 0.5, "Turn \(turn): the sheet settles\n\(trace)")
            }
        }
    }

    func testKeyboardLiftsTheFittedSheetAboveIt() async throws {
        try await mounted(["-tron-ask-user-fixture"]) { app in
            try await app.until("the form") { app.element("Submit all answers") != nil }
            try await app.waitForTopSheetToSettle()
            _ = try await app.still("the fitted form") { [Double(sheetFrame(app).minY)] }
            let start = sheetFrame(app).minY
            let idle = try XCTUnwrap(mainScroll(app)).bounds.height
            XCTAssertGreaterThan(start, 120, "the form fits its content")
            let window = app.window.bounds
            let keyboard = CGRect(x: 0, y: window.maxY - 336, width: window.width, height: 336)
            let shown = try await SheetTrace.record(app, frames: 90, each: { index in
                guard index == 0 else { return }
                NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil,
                                                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: keyboard)])
            })
            let height = sheetFrame(app).height
            XCTAssertLessThanOrEqual(sheetFrame(app).maxY, keyboard.minY, "The sheet rests above the keyboard\n\(shown)")
            XCTAssertGreaterThanOrEqual(sheetFrame(app).maxY, keyboard.minY - 16, "The sheet sits on the keyboard\n\(shown)")
            XCTAssertEqual(try XCTUnwrap(mainScroll(app)).bounds.height, idle, accuracy: 0.5, "The lifted sheet keeps its fitted height\n\(shown)")
            XCTAssertTrue(shown.samples.allSatisfy { abs($0.height - height) <= 0.5 }, "The sheet lifts without resizing\n\(shown)")
            shown.assertStill("The sheet rises above the keyboard in one move", against: app)
            let hidden = try await SheetTrace.record(app, frames: 90, each: { index in
                if index == 0 { NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil) }
            })
            XCTAssertEqual(hidden.final.minY, start, accuracy: 0.5, "Hiding the keyboard restores the fitted height\n\(hidden)")
        }
    }

    func testArtifactsErrorStaysInsideTheSheetInsets() async throws {
        try await mounted(["-tron-integrations-fixture", "-integrations-scenario", "artifacts-error"]) { app in
            try await app.activate("Artifacts")
            try await app.until("the artifacts error") { app.element("artifacts-error") != nil }
            try await assertFitted(app, "artifacts-error")
            let sheet = sheetFrame(app)
            let notice = try XCTUnwrap(app.element("artifacts-error")).accessibilityFrame
            XCTAssertGreaterThanOrEqual(sheet.maxY - notice.maxY, notice.minX - sheet.minX - 1,
                "The error card keeps at least its side inset above the sheet's bottom edge: card \(notice) sheet \(sheet)")
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
            @MainActor func laidOut(_ card: CGRect) -> CGFloat {
                card.height * parent.view.bounds.height / parent.view.convert(parent.view.bounds, to: nil).height
            }
            let startCard = laidOut(try XCTUnwrap(bottomCard(), "the bottom card"))
            var ys: [CGFloat] = [], cards: [CGFloat] = []
            UIView.setAnimationsEnabled(true)
            defer { UIView.setAnimationsEnabled(false) }
            try await app.activate("Technical details")
            var closedAt: Int?
            for index in 0..<200 {
                let layer = parent.view.layer.presentation() ?? parent.view.layer
                let frame = layer.convert(layer.bounds, to: nil)
                ys.append(frame.minY)
                if let card = bottomCard() { cards.append(laidOut(card)) }
                if closedAt == nil, index > 40, sheetChain(app).count == 2 { try await app.activate("Done"); closedAt = index }
                await MountedFixture.nextFrame()
            }
            let trace = "PARENT_TRACE " + ys.enumerated().filter { $0.offset == 0 || abs($0.element - ys[$0.offset - 1]) > 0.25 }
                .map { "\($0.offset):\(Int($0.element))" }.joined(separator: " ")
            print(trace)
            let close = try XCTUnwrap(closedAt, "the subsheet closed")
            for phase in [Array(ys[..<close]), Array(ys[close...])] {
                let deltas = zip(phase, phase.dropFirst()).map { $1 - $0 }.filter { abs($0) > 0.5 }
                XCTAssertTrue(zip(deltas, deltas.dropFirst()).allSatisfy { ($0 > 0) == ($1 > 0) },
                              "The sheet under a subsheet steps back in one move and returns in one move, never up-down-up\n\(trace)")
            }
            XCTAssertEqual(ys.last!, ys.first!, accuracy: 0.5, "The sheet under a subsheet returns to its own height\n\(trace)")
            XCTAssertTrue(cards.allSatisfy { abs($0 - startCard) <= 0.5 },
                          "The bottom card keeps its laid-out height on every frame: \(Set(cards.map { Int($0) }).sorted())")
        }
    }

    func testMemorySubsheetOpensAtTheHeightItLoadsInto() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-browser-loading"]) { app in
            try await openManageHome(app)
            UIView.setAnimationsEnabled(true)
            try await app.activate("home-manage-memory-browser")
            var loadingAtOpen = false
            var loadedAt: Int?
            let trace = try await SheetTrace.record(app, frames: 420, ready: { app.element("home-sheet-done-memory") != nil }) { index in
                if index == 0 { loadingAtOpen = app.element("sheet-loading") != nil }
                if index == 20 { capture(app, "memory-loading") }
                if loadedAt == nil, app.element("home-memory-row-39") != nil { loadedAt = index; capture(app, "memory-loaded") }
            }
            XCTAssertTrue(loadingAtOpen, "The memory sheet opens while its first page is still loading\n\(app.tree())")
            let loaded = try XCTUnwrap(loadedAt, "The first memory page arrives during the trace\n\(trace)")
            XCTAssertEqual(trace.samples[loaded].minY, trace.final.minY, accuracy: 0.5,
                           "The sheet already stands at its loaded height when the first page arrives\n\(trace)")
            trace.assertStill("The memory sheet opens once, at the height it loads into", against: app)
        }
    }

    func testMemorySubsheetLoadsOnceWhileHomeIsLive() async throws {
        try await mounted(["-tron-home-dashboard-fixture", "-home-shell-ready", "-home-live-session"]) { app in
            try await openManageHome(app)
            try await app.activate("home-manage-memory-browser")
            try await app.until("the memory sheet") { app.element("home-sheet-done-memory") != nil }
            let startRevision = fixtureCount(app, "fixture.home-session-revision", "home-session-revision:")
            for _ in 0..<240 { await MountedFixture.nextFrame() }
            XCTAssertGreaterThan(fixtureCount(app, "fixture.home-session-revision", "home-session-revision:"), startRevision + 3,
                                 "Home's session stays live while the memory sheet is open")
            XCTAssertEqual(fixtureCount(app, "fixture.home-read-counts", "home.memory.view.first="), 1,
                           "An open memory sheet reads its first page once; live Home events never reload it")
            XCTAssertNotNil(app.element("home-memory-row-39"), "The first page stays on screen\n\(app.tree())")
            XCTAssertNil(app.element("sheet-loading"), "The sheet is not loading again")
        }
    }

    private func fixtureCount(_ app: MountedFixture, _ id: String, _ prefix: String) -> Int {
        let label = app.element(id, in: app.window)?.accessibilityLabel ?? ""
        guard let range = label.range(of: prefix) else { return -1 }
        return Int(label[range.upperBound...].prefix { $0.isNumber }) ?? -1
    }

    private func openManageHome(_ app: MountedFixture) async throws {
        try await app.activate("home-pinned-row")
        try await app.activate("session-context-button")
        try await app.until("Manage Home opens") { app.element("home-manage-state") != nil }
        try await app.waitForTopSheetToSettle()
    }

    private func revealed(_ app: MountedFixture, _ key: String) async throws -> NSObject {
        var node: NSObject?
        try await app.until("\(key) exists") {
            node = app.element(key)
            return node != nil
        }
        try await app.reveal(node!)
        return app.element(key) ?? node!
    }

    private func sheetChain(_ app: MountedFixture) -> [UIViewController] {
        var chain: [UIViewController] = []
        var next = app.window.rootViewController?.presentedViewController
        while let controller = next, !controller.isBeingDismissed { chain.append(controller); next = controller.presentedViewController }
        return chain
    }

    private func rendered(_ controller: UIViewController) -> CGRect {
        let layer = controller.view.layer.presentation() ?? controller.view.layer
        return layer.convert(layer.bounds, to: nil)
    }

    private func assertNested(_ app: MountedFixture, _ name: String, open: () async throws -> Void) async throws {
        try await app.waitForTopSheetToSettle()
        let parent = try XCTUnwrap(sheetChain(app).last)
        let depth = sheetChain(app).count
        let start = rendered(parent)
        let model = parent.view.bounds.size
        var frames: [CGRect] = [], sizes: [CGSize] = []
        @MainActor func sample() {
            frames.append(rendered(parent))
            sizes.append((parent.view.layer.presentation() ?? parent.view.layer).bounds.size)
        }
        UIView.setAnimationsEnabled(true)
        try await open()
        let trace = try await SheetTrace.record(app, frames: 120, ready: { sheetChain(app).count == depth + 1 }) { _ in sample() }
        trace.assertStill("\(name): the nested sheet opens at its final height", against: app)
        try await assertFitted(app, "\(name)-over-parent")
        let child = sheetFrame(app)
        let scroll = try XCTUnwrap(mainScroll(app))
        let needed = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom
        XCTAssertGreaterThanOrEqual(needed, scroll.bounds.height - 1,
            "\(name): the nested sheet is sized by its own content, not its parent (content \(needed), sheet \(scroll.bounds.height))")
        let covered = rendered(parent)
        XCTAssertLessThan(covered.width, child.width - 10, "\(name): the parent steps back narrower than the sheet over it, a deck card: \(covered) under \(child)")
        XCTAssertLessThanOrEqual(covered.minY, child.minY - 11.5, "\(name): the parent's top peeks above the sheet over it: \(covered) under \(child)")
        UIView.setAnimationsEnabled(true)
        _ = sheetChain(app).last?.presentingViewController?.dismiss(animated: true)
        for _ in 0..<90 { sample(); await MountedFixture.nextFrame() }
        UIView.setAnimationsEnabled(false)
        try await app.until("\(name) closes") { sheetChain(app).count == depth }
        let log = "\(name) parent frames: " + frames.map { "\(Int($0.minY))/\(Int($0.width))x\(Int($0.height))" }.joined(separator: " ")
        XCTAssertTrue(sizes.allSatisfy { abs($0.height - model.height) <= 0.5 && abs($0.width - model.width) <= 0.5 },
                      "\(name): the parent never resizes while a nested sheet comes and goes: \(Set(sizes.map { "\(Int($0.width))x\(Int($0.height))" }))")
        XCTAssertTrue(frames.allSatisfy { abs($0.width / $0.height - start.width / start.height) <= 0.005 },
                      "\(name): the parent only scales as a card, never reflows\n\(log)")
        XCTAssertTrue(frames.allSatisfy { $0.minY <= start.minY + 0.5 }, "\(name): the parent is never tucked down under the nested sheet\n\(log)")
        try await app.waitForTopSheetToSettle()
        XCTAssertEqual(rendered(parent).minY, start.minY, accuracy: 0.5, "\(name): closing the nested sheet restores its parent")
        XCTAssertEqual(rendered(parent).width, start.width, accuracy: 0.5, "\(name): closing the nested sheet restores its parent")
        XCTAssertEqual(rendered(parent).height, start.height, accuracy: 0.5, "\(name): closing the nested sheet restores its parent")
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
