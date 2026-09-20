import SwiftUI
import Observation
import UIKit
import XCTest
import WebKit
@testable import TronMobile

@MainActor
final class SessionSheetPresentationTests: XCTestCase {
    func testOnboardingNextToolbarRendersTrailingChevron() async throws {
        try await withModel { model in
            try await withSheet(OnboardingView(selectedDetent: .constant(.medium), onComplete: {})
                .environment(model).preferredColorScheme(.light)) { controller in
                let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                self.assertToolbarPaint(.tronEmerald, bar: bar, leading: false, controller: controller)
                // Keep the actual toolbar rendering for visual review of Next ›.
                self.capture(controller, name: "onboarding-next-trailing-chevron")
            }
        }
    }

    func testSessionHistoryUsesTighterSummaryAndTopPagingGaps() {
        XCTAssertEqual(SessionHistoryLayout.summaryBottomPadding, 4)
        XCTAssertEqual(SessionHistoryLayout.pagingTopPadding, 4)
        XCTAssertEqual(SessionHistoryLayout.topPagingBottomPadding, 2)
        XCTAssertLessThan(SessionHistoryLayout.topPagingBottomPadding, SessionHistoryLayout.regularPagingBottomPadding)
    }

    func testAutomationTimeEditorUsesTimeOnlyPickerAndPreservesDate() async throws {
        for field in [AutomationDateField.once, .intervalAnchor, .localTime] {
            let route = AutomationDateSelection(field: field, component: .time)
            XCTAssertEqual(route.components, .hourAndMinute)
            XCTAssertNotEqual(route.id, AutomationDateSelection(field: field, component: .date).id)
            var value = Date(timeIntervalSince1970: 1_789_459_200)
            let original = value
            try await withSheet(AutomationDatePickerSheet(
                selection: route,
                date: Binding(get: { value }, set: { value = $0 })
            )) { controller in
                let picker = try XCTUnwrap(self.views(of: UIDatePicker.self, in: controller.view).first)
                XCTAssertEqual(picker.datePickerMode, .time)
                XCTAssertEqual(picker.preferredDatePickerStyle, .wheels)
                let changed = original.addingTimeInterval(1_800)
                picker.setDate(changed, animated: false)
                picker.sendActions(for: .valueChanged)
                XCTAssertEqual(value.timeIntervalSince1970, changed.timeIntervalSince1970, accuracy: 1)
                XCTAssertTrue(Calendar.current.isDate(value, inSameDayAs: original))
                self.capture(controller, name: "automation-time-editor-\(field.id)")
            }
        }
    }

    func testPackageRemovalConfirmationHasShortActionAndCenteredTitle() async throws {
        try await withSheet(TronConfirmationSheet(
            title: "Remove this package?", message: "npm:sample-package", confirmTitle: "Remove",
            destructive: true, centersTitle: true, icon: "shippingbox.and.arrow.down", onConfirm: {}
        )) { controller in
            let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
            XCTAssertEqual(bar.topItem?.largeTitleDisplayMode, .never)
            self.capture(controller, name: "package-remove-short-action")
        }
    }

    func testAutomationSessionPickerUsesLargeSelectionSheet() async throws {
        let sessions = [
            SessionSummary(id: "session-a", name: "Daily Review", cwd: "/workspace/tron", parentSessionId: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z", messageCount: 4, firstMessage: "Review", phase: .idle),
            SessionSummary(id: "session-b", name: "Release Notes", cwd: "/workspace/docs", parentSessionId: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z", messageCount: 2, firstMessage: "Notes", phase: .idle)
        ]
        try await withSheet(AutomationSessionPickerSheet(sessions: sessions, selectedID: "session-a", onSelect: { _ in })) { controller in
            XCTAssertEqual(controller.sheetPresentationController?.detents.count, 1)
            XCTAssertEqual(controller.sheetPresentationController?.detents.first?.identifier, .large)
            XCTAssertNotNil(self.views(of: UITextField.self, in: controller.view).first)
            self.capture(controller, name: "automation-session-picker")
        }
    }

    func testAutomationFormUsesCompactInlineSettingsChrome() async throws {
        try await withModel { model in
            for variant in [
                (name: "light", scheme: ColorScheme.light, size: DynamicTypeSize.large),
                (name: "dark", scheme: ColorScheme.dark, size: DynamicTypeSize.large),
                (name: "accessibility", scheme: ColorScheme.dark, size: DynamicTypeSize.accessibility3)
            ] {
                try await self.withSheet(
                    AutomationFormView(selection: nil, onSaved: {})
                        .environment(model)
                        .environment(\.dynamicTypeSize, variant.size)
                        .preferredColorScheme(variant.scheme)
                ) { controller in
                    let navigationBar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    XCTAssertEqual(navigationBar.topItem?.largeTitleDisplayMode, .never,
                                   "Automation form must not reserve a large-title region")
                    self.capture(controller, name: "automation-form-inline-settings-\(variant.name)")
                    if let scrollView = self.views(of: UIScrollView.self, in: controller.view).first {
                        let targetOffset = min(900, max(0, scrollView.contentSize.height - scrollView.bounds.height))
                        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: false)
                        controller.view.layoutIfNeeded()
                        self.capture(controller, name: "automation-form-target-schedule-\(variant.name)")
                    }
                }
            }
        }
    }

    func testKnowledgeObservationAndTechnicalDetailsStartAtMediumAndExpand() async throws {
        let record = KnowledgeObservationFixture.record()
        let presentation = try XCTUnwrap(KnowledgeObservationPresentation(record: record))
        try await withModel { model in
            for _ in 0..<2 {
                try await self.withSheet(KnowledgeDetailSheet(record: record, origin: model.knowledgePresentationIdentity,
                    onChanged: {}, onOpenDraft: { _ in }, onOpenSession: { _, _ in }).environment(model)) { controller in
                    let sheet = try XCTUnwrap(controller.sheetPresentationController)
                    XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
                    XCTAssertEqual(sheet.selectedDetentIdentifier, .medium, "Each record opens compactly, including after a previous expansion")
                    XCTAssertFalse(sheet.prefersGrabberVisible)
                    sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
                    try await self.waitForRouting { sheet.selectedDetentIdentifier == .large }
                }
            }
        }
        try await withSheet(KnowledgeObservationTechnicalDetailsSheet(presentation: presentation)) { controller in
            let sheet = try XCTUnwrap(controller.sheetPresentationController)
            XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
            XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
            XCTAssertFalse(sheet.prefersGrabberVisible)
        }
    }

    func testKnowledgeOriginCitationOpensExactOffPageHistoryEntry() async throws {
        let gateway = ProcessSheetGatewayFixture()
        try await withModel(client: gateway.client) { model in
            try await gateway.connect(model: model, capabilities: ["session-history-pages.v1"])
            let snapshot = try SessionScenarioBuilder(seed: 9_401).openingTail(targetEncodedBytes: 4_096)
            model.installHostedSubscribedSnapshot(snapshot)
            let targetEntry = "synthetic-history-entry"
            let list = try SessionHistoryStoreTests.window(1...100, total: 101)
            let listResponse = Task {
                try await gateway.respond(at: 1, method: "session.history.list", result: JSONValue.encode(SessionHistoryPage(
                    runtimeGeneration: snapshot.runtimeGeneration, nodes: list.nodes, older: list.older,
                    newer: list.newer, totalEntries: 101)))
            }
            defer { listResponse.cancel() }
            try await self.withSheet(SessionTreeSheet(sessionID: snapshot.sessionId, initialEntryID: targetEntry,
                onForkCreated: { _ in }, onNavigated: {}).environment(model)) { controller in
                try await listResponse.value
                try await gateway.waitForRequest(at: 2)
                let first = String(repeating: "a", count: 24_000)
                let exact = SessionHistoryEntryPage(runtimeGeneration: snapshot.runtimeGeneration, entryId: targetEntry,
                    text: first, offset: 0, nextOffset: 24_000, previousOffset: nil, totalCharacters: 24_028,
                    metadata: .object(["type": .string("message"), "role": .string("user"), "timestamp": .string("2026-01-01T00:00:00Z")]))
                try await gateway.respond(at: 2, method: "session.history.entry", result: JSONValue.encode(exact))
                try await self.waitForRouting {
                    guard let detail = controller.presentedViewController else { return false }
                    return self.views(of: UITextView.self, in: detail.view).contains { $0.text == first }
                }
                let detail = try XCTUnwrap(controller.presentedViewController)
                XCTAssertTrue(self.views(of: UITextView.self, in: detail.view).contains { $0.text == first })
                let requests = await gateway.socket.sentFrames()
                let decoded = try requests.compactMap { try? JSONDecoder.gateway.decode(JSONValue.self, from: $0) }
                XCTAssertTrue(decoded.contains { value in
                    value.objectValue?["method"]?.stringValue == "session.history.entry"
                        && value.objectValue?["params"]?.objectValue?["entryId"]?.stringValue == targetEntry
                })
            }
            await gateway.client.close()
        }
    }

    func testSessionHistoryPagingStartsNewNativeBatchAtTopAndRetainsFailures() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            let gateway = ProcessSheetGatewayFixture()
            try await withModel(client: gateway.client) { model in
                try await gateway.connect(model: model, capabilities: ["session-history-pages.v1"])
                let snapshot = try SessionScenarioBuilder(seed: 8_941).openingTail(targetEncodedBytes: 4_096)
                model.installHostedSubscribedSnapshot(snapshot)
                let probe = SessionHistoryPagingProbe()
                let activity = WorkspaceRefreshActivity()
                func page(_ range: ClosedRange<Int>, total: Int = 293) throws -> JSONValue {
                    let source = SessionHistoryStoreTests.window(range, total: total)
                    return try JSONValue.encode(SessionHistoryPage(runtimeGeneration: snapshot.runtimeGeneration,
                        nodes: source.nodes, older: source.older, newer: source.newer, totalEntries: total))
                }
                let initial = Task { try await gateway.respond(at: 1, method: "session.history.list", result: page(194...293)) }
                defer { initial.cancel() }
                try await self.withSheet(HistoryPagingFixture(model: model, sessionID: snapshot.sessionId,
                    probe: probe, activity: activity).preferredColorScheme(scheme)) { controller in
                    try await initial.value
                    try await self.waitForRouting { probe.store?.page?.entryRange == 194...293 }
                    let first = try await self.historyFirstRow("293", controller: controller)
                    let original = try XCTUnwrap(self.historyScroll(containing: first))
                    original.setContentOffset(CGPoint(x: 0, y: original.contentSize.height - original.bounds.height + original.adjustedContentInset.bottom), animated: false)
                    for _ in 0..<5 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    XCTAssertGreaterThan(original.contentOffset.y, 1_000, "Start in the real native old batch, not at a synthetic policy position")
                    XCTAssertEqual(original.contentOffset.y, original.contentSize.height - original.bounds.height + original.adjustedContentInset.bottom, accuracy: 1, "Start at the actual native bottom after lazy materialization")
                    self.capture(controller, name: "history-paging-first-bottom-\(scheme)")
                    let retainedOffset = original.contentOffset.y
                    probe.older?()
                    probe.older?() // Repeated synchronous taps must not acquire duplicate reads.
                    try await gateway.waitForRequest(at: 2)
                    try await gateway.respond(at: 2, method: "session.history.list", result: .null)
                    try await self.waitForRouting { probe.store?.error != nil }
                    XCTAssertTrue(original.window != nil)
                    XCTAssertEqual(original.contentOffset.y, retainedOffset, accuracy: 1)
                    XCTAssertEqual(probe.store?.page?.entryRange, 194...293)
                    probe.refresh?()
                    try await gateway.respond(at: 3, method: "session.history.list", result: page(194...293))
                    try await self.waitForRouting { probe.store?.loading == false }
                    XCTAssertNil(probe.store?.error, "A bookmark refresh must read the installed page, not the failed cursor")
                    XCTAssertEqual(original.contentOffset.y, retainedOffset, accuracy: 1)
                    probe.older?()
                    try await gateway.respond(at: 4, method: "session.history.list", result: .null)
                    try await self.waitForRouting { probe.store?.error != nil }
                    probe.retry?()
                    try await gateway.respond(at: 5, method: "session.history.list", result: page(94...193))
                    let middle = try await self.historyFirstRow("193", controller: controller)
                    let middleScroll = try XCTUnwrap(self.historyScroll(containing: middle))
                    XCTAssertFalse(middleScroll === original)
                    XCTAssertEqual(middleScroll.contentOffset.y + middleScroll.adjustedContentInset.top, 0, accuracy: 1)
                    let firstRowFrame = middle.convert(middle.bounds, to: middleScroll)
                    XCTAssertGreaterThanOrEqual(firstRowFrame.minY, middleScroll.contentOffset.y + middleScroll.adjustedContentInset.top)
                    XCTAssertLessThanOrEqual(firstRowFrame.maxY, middleScroll.contentOffset.y + middleScroll.bounds.height - middleScroll.adjustedContentInset.bottom, "The complete new first row is natively visible")
                    XCTAssertEqual(probe.store?.page?.entryRange, 94...193)
                    self.capture(controller, name: "history-paging-middle-\(scheme)")
                    // Bookmark/label refresh shares the real production refresh
                    // entrypoint but must not replace the native viewport.
                    middleScroll.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
                    let middleOffset = middleScroll.contentOffset.y
                    probe.refresh?()
                    try await gateway.respond(at: 6, method: "session.history.list", result: page(94...193))
                    try await self.waitForRouting { probe.store?.loading == false }
                    XCTAssertTrue(middleScroll.window != nil)
                    XCTAssertEqual(middleScroll.contentOffset.y, middleOffset, accuracy: 1)
                    activity.value = .covered
                    for _ in 0..<4 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    activity.value = .active
                    for _ in 0..<4 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    XCTAssertTrue(middleScroll.window != nil)
                    XCTAssertEqual(middleScroll.contentOffset.y, middleOffset, accuracy: 1)
                    let retainedRequests = await gateway.socket.sentFrames().count
                    XCTAssertEqual(retainedRequests, 7, "Unchanged-identity reactivation does not replay a completed read")
                    // An admitted request that loses its surface cannot move or
                    // replace the displayed batch with its late response.
                    probe.older?()
                    try await gateway.waitForRequest(at: 7)
                    activity.value = .covered
                    for _ in 0..<4 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    try await gateway.respond(at: 7, method: "session.history.list", result: page(1...93))
                    for _ in 0..<4 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    XCTAssertEqual(probe.store?.page?.entryRange, 94...193)
                    XCTAssertEqual(middleScroll.contentOffset.y, middleOffset, accuracy: 1)
                    activity.value = .active
                    try await gateway.respond(at: 8, method: "session.history.list", result: page(1...93))
                    let last = try await self.historyFirstRow("93", controller: controller)
                    let lastScroll = try XCTUnwrap(self.historyScroll(containing: last))
                    XCTAssertEqual(lastScroll.contentOffset.y + lastScroll.adjustedContentInset.top, 0, accuracy: 1)
                    XCTAssertNil(probe.store?.page?.older)
                    XCTAssertNotNil(probe.store?.page?.newer)
                    self.capture(controller, name: "history-paging-last-\(scheme)")
                    lastScroll.setContentOffset(CGPoint(x: 0, y: lastScroll.contentSize.height - lastScroll.bounds.height + lastScroll.adjustedContentInset.bottom), animated: false)
                    for _ in 0..<5 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    XCTAssertEqual(lastScroll.contentOffset.y, lastScroll.contentSize.height - lastScroll.bounds.height + lastScroll.adjustedContentInset.bottom, accuracy: 1)
                    self.capture(controller, name: "history-paging-last-bottom-\(scheme)")
                    probe.newer?()
                    try await gateway.respond(at: 9, method: "session.history.list", result: page(94...193))
                    let back = try await self.historyFirstRow("193", controller: controller)
                    let backScroll = try XCTUnwrap(self.historyScroll(containing: back))
                    XCTAssertEqual(backScroll.contentOffset.y + backScroll.adjustedContentInset.top, 0, accuracy: 1)
                    let requests = await gateway.socket.sentFrames().count
                    XCTAssertEqual(requests, 10)
                }
                await gateway.client.close()
            }
        }
    }

    private func historyScroll(containing view: UIView) -> UIScrollView? {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let scroll = candidate as? UIScrollView { return scroll }
            ancestor = candidate.superview
        }
        return nil
    }

    private func historyFirstRow(_ id: String, controller: UIViewController) async throws -> UIView {
        // Wait for the actual new lazy row, its native scroll owner, and the
        // completed fade. Metadata admission alone does not prove placement.
        try await waitForRouting {
            self.views(of: UIView.self, in: controller.view).contains {
                guard $0.accessibilityIdentifier == "history-first-\(id)",
                      let scroll = self.historyScroll(containing: $0) else { return false }
                return $0.window != nil && $0.bounds.height > 0
                    && abs(scroll.contentOffset.y + scroll.adjustedContentInset.top) <= 1
            }
        }
        for _ in 0..<15 { try await DisplayFrameScheduler.displayLink.nextFrame() }
        return try XCTUnwrap(self.views(of: UIView.self, in: controller.view).first { $0.accessibilityIdentifier == "history-first-\(id)" })
    }

    func testSessionHistoryUnifiedFeedAndFullNativeEntryPreviews() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            let gateway = ProcessSheetGatewayFixture()
            try await withModel(client: gateway.client) { model in
                try await gateway.connect(model: model, capabilities: ["session-history-pages.v1"])
                var snapshot = try SessionScenarioBuilder(seed: 8_940).openingTail(targetEncodedBytes: 4_096)
                snapshot.stats = SessionStats(userMessages: 192, assistantMessages: 192, toolCalls: 96, toolResults: 96,
                    totalMessages: 480, tokens: snapshot.stats.tokens, latestCacheHitRate: nil, cost: 0)
                model.installHostedSubscribedSnapshot(snapshot)
                let identity = try XCTUnwrap(SessionHistoryReadIdentity.current(model: model, sessionID: snapshot.sessionId))
                let rows = [
                    SessionTreeNode(id: "response", parentId: "prompt", timestamp: "2026-01-01T10:03:00Z", kind: "message", label: nil,
                        preview: "The focused checks passed. History now preserves the complete selected message and its original line breaks.", role: .assistant, depth: 0, childCount: 0, isCurrentPath: true),
                    SessionTreeNode(id: "prompt", parentId: "branch", timestamp: "2026-01-01T10:02:00Z", kind: "message", label: "Review checkpoint",
                        preview: "Keep the feed compact and make older entries easy to inspect.", role: .user, depth: 0, childCount: 1, isCurrentPath: true),
                    SessionTreeNode(id: "branch", parentId: "tool", timestamp: "2026-01-01T10:01:00Z", kind: "branchSummary", label: nil,
                        preview: "Continue with the simpler approach; preserve the original branch.", role: nil, depth: 0, childCount: 1, isCurrentPath: true),
                    SessionTreeNode(id: "tool", parentId: nil, timestamp: "2026-01-01T10:00:00Z", kind: "message", label: nil,
                        preview: "read: inspected the selected source files", role: .toolResult, depth: 0, childCount: 1, isCurrentPath: true),
                ]
                let response = Task {
                    try await gateway.respond(at: 1, method: "session.history.list", result: JSONValue.encode(SessionHistoryPage(
                        runtimeGeneration: snapshot.runtimeGeneration, nodes: rows,
                        older: .init(ordinal: 1_101, entryId: "tool", direction: "older"), newer: nil, totalEntries: 1_105)))
                }
                defer { response.cancel() }
                try await self.withSheet(SessionTreeSheet(sessionID: snapshot.sessionId, onForkCreated: { _ in }, onNavigated: {})
                    .environment(model).preferredColorScheme(scheme)) { controller in
                    try await response.value
                    for _ in 0..<8 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    let sentCount = await gateway.socket.sentFrames().count
                    XCTAssertEqual(sentCount, 2, "Feed does not eagerly request entry bodies")
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronSessionTeal, bar: bar, leading: true, controller: controller)
                    self.capture(controller, name: "session-history-medium-\(scheme)")
                    controller.sheetPresentationController?.selectedDetentIdentifier = .large
                    controller.presentationController?.containerView?.layoutIfNeeded()
                    for _ in 0..<8 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    self.capture(controller, name: "session-history-large-\(scheme)")
                }
                let content = (0..<35).map { "Paragraph \($0 + 1)\nOriginal lines remain selectable. Unicode survives unchanged: café 😀.\n" }.joined(separator: "\n") + "FINAL AUTHORED LINE"
                let details = Task {
                    try await gateway.respond(at: 2, method: "session.history.entry", result: JSONValue.encode(SessionHistoryEntryPage(
                        runtimeGeneration: snapshot.runtimeGeneration, entryId: "response", text: content, offset: 0,
                        nextOffset: nil, previousOffset: nil, totalCharacters: content.utf16.count,
                        metadata: .object(["role": .string("assistant"), "model": .string("fixture-model")]))))
                }
                defer { details.cancel() }
                try await self.withSheet(HistoryEntryDetailsSheet(node: rows[0], identity: identity)
                    .environment(model).preferredColorScheme(scheme)) { controller in
                    try await details.value
                    try await self.waitForRouting { self.views(of: UITextView.self, in: controller.view).contains { $0.text == content } }
                    let reader = try XCTUnwrap(self.views(of: UITextView.self, in: controller.view).first { $0.text == content })
                    XCTAssertTrue(reader.isSelectable && !reader.isEditable && reader.isScrollEnabled)
                    XCTAssertTrue(reader.text.hasSuffix("FINAL AUTHORED LINE"))
                    XCTAssertGreaterThan(reader.contentSize.height, reader.bounds.height)
                    self.capture(controller, name: "session-history-entry-medium-\(scheme)")
                    controller.sheetPresentationController?.selectedDetentIdentifier = .large
                    controller.presentationController?.containerView?.layoutIfNeeded()
                    for _ in 0..<8 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    self.capture(controller, name: "session-history-entry-large-\(scheme)")
                }
                await gateway.client.close()
            }
        }
    }

    func testQuestionSheetStartsBelowTopBlurAtMediumAndLargeDetents() async throws {
        let form = ExtensionFormDescriptor(
            version: 1,
            title: "Questions",
            questions: [
                ExtensionFormQuestion(
                    id: "strategy", header: "Strategy", question: "How should we proceed?",
                    context: "Choose an approach.",
                    options: [ExtensionFormOption(id: "one", label: "One app", description: "Keep the current state.")],
                    multiSelect: false, allowOther: true
                ),
                ExtensionFormQuestion(
                    id: "notes", header: "Notes", question: "Anything else?",
                    context: nil, options: [ExtensionFormOption(id: "none", label: "Nothing else")],
                    multiSelect: false, allowOther: true
                ),
            ],
            allowCancel: true
        )
        let interaction = ExtensionInteraction(
            id: "question-sheet-fixture", hostEpoch: "host", presentationRevision: 1,
            method: .form, title: "Questions", form: form
        )
        try await withModel { model in
            try await self.withSheet(ExtensionFormSheet(
                sessionID: "question-sheet-session", interaction: interaction,
                onResolved: {}, onLocallyClosed: {}
            ).environment(model)) { controller in
                let sheet = try XCTUnwrap(controller.sheetPresentationController)
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                let navigationBar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                XCTAssertGreaterThanOrEqual(
                    scroll.convert(scroll.bounds, to: controller.view).minY,
                    navigationBar.convert(navigationBar.bounds, to: controller.view).maxY - 1,
                    "Question content must begin below the custom navigation blur"
                )
                guard sheet.detents.contains(where: { $0.identifier == .large }) else { return }
                sheet.selectedDetentIdentifier = .large
                controller.presentationController?.containerView?.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                XCTAssertGreaterThanOrEqual(
                    scroll.convert(scroll.bounds, to: controller.view).minY,
                    navigationBar.convert(navigationBar.bounds, to: controller.view).maxY - 1,
                    "Expanding the question sheet must preserve the top clearance"
                )
                XCTAssertTrue(scroll.isScrollEnabled)
            }
        }
    }

    func testServerFilterStartsMediumAndExpandsBeforeScrolling() async throws {
        for presentation in 0..<2 {
            try await withSheet(TronDashboardFilterSheet(
                title: "Filter Servers", accent: .tronEmerald,
                detents: [.medium, .large], onDone: {}
            ) {
                TronDashboardFilterSectionTitle(title: "Servers")
                ForEach(0..<20) { index in
                    TronDashboardFilterOption(
                        title: "Server \(index)", detail: "Available sessions",
                        selected: index == 0, accent: .tronEmerald, inactiveAccent: .tronCyan
                    ) {}
                }
            }) { controller in
                let sheet = try XCTUnwrap(controller.sheetPresentationController)
                XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
                guard sheet.detents.contains(where: { $0.identifier == .large }) else { return }
                XCTAssertEqual(sheet.selectedDetentIdentifier, .medium, "Reopening must not retain the previous large detent")
                XCTAssertTrue(sheet.prefersScrollingExpandsWhenScrolledToEdge, "Content gestures must expand before scrolling")
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                self.capture(controller, name: "server-filter-medium-\(presentation)")
                let mediumHeight = controller.view.bounds.height
                sheet.selectedDetentIdentifier = .large
                controller.presentationController?.containerView?.layoutIfNeeded()
                controller.view.layoutIfNeeded()
                XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
                XCTAssertGreaterThan(controller.view.bounds.height, mediumHeight, "The native sheet must actually expand")
                XCTAssertTrue(scroll.isScrollEnabled, "The large sheet must keep its native scroll owner")
                scroll.setContentOffset(CGPoint(x: 0, y: 150), animated: false)
                XCTAssertEqual(scroll.contentOffset.y, 150, accuracy: 1)
                self.capture(controller, name: "server-filter-expanded-scrolled-\(presentation)")
            }
        }
    }

    func testMountedGroupedRowsActivateCustomDisplaysInsteadOfGenericDetails() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 7_829).openingTail(targetEncodedBytes: 4_096)
        let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
        try await withModel { model in
            for kind: DisplayKind in [.markdown, .browserLive] {
                let display = self.routingDisplay(kind: kind)
                let selected = self.routingTool(id: "custom", display: display)
                let tools = [self.routingTool(id: "ordinary"), selected]
                var activated: DisplayPresentationCommand?
                let probe = HostedToolActionProbe()
                let content = LiveToolRunDetails(initial: ToolRunResolvedState(installationTag: tag,
                    run: ChatToolRunPresentation(tools: tools), tools: tools), detent: .constant(.medium),
                    onDisplay: { _, command in activated = command }, onDismiss: {})
                    .environment(model).environment(\.canonicalResourceSessionID, snapshot.sessionId)
                    .environment(\.hostedToolActionProbe, probe)
                try await self.withSheet(content) { controller in
                    XCTAssertTrue(probe.activate("row:custom"))
                    let route = DisplayRoute(sessionID: snapshot.sessionId, display: display)
                    XCTAssertEqual(activated, kind == .browserLive ? .showFloating(route) : .showSheet(route))
                    XCTAssertNil(controller.presentedViewController, "Custom content must not nest generic tool details")
                }
                XCTAssertEqual(probe.count, 0, "Dismissed rows must release their callbacks")
            }
        }
    }

    func testGroupedCustomRouteWaitsForOuterSheetRetirement() async throws {
        try await checkGroupedHandoff(replacement: .none)
    }

    func testGroupedHandoffRejectsSameRuntimeBranchReplacement() async throws {
        try await checkGroupedHandoff(replacement: .source)
    }

    func testGroupedHandoffRejectsNewInstallationWithUnchangedSelectedResult() async throws {
        try await checkGroupedHandoff(replacement: .installation)
    }

    private enum GroupedReplacement { case none, source, installation }

    private func checkGroupedHandoff(replacement: GroupedReplacement) async throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_831).openingTail(targetEncodedBytes: 4_096)
        let display = routingDisplay(kind: .browserLive)
        snapshot.transcript.append(.message(.init(id: "custom-result", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
            kind: .message, role: .toolResult, presentationId: "custom-result", content: [], toolCallId: "custom", toolName: "agent_browser", display: display)))
        snapshot.transcriptTotal = (snapshot.transcriptStart ?? 0) + snapshot.transcript.count
        let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
        let tools = [routingTool(id: "ordinary"), routingTool(id: "custom", display: display)]
        let run = ChatToolRunPresentation(tools: tools)
        try await withModel { model in
            model.installHostedAuthoritativeSnapshot(snapshot)
            let coordinator = PresentationActivityCoordinator()
            let probe = HostedToolActionProbe()
            var activated: DisplayPresentationCommand?
            let content = ToolRunView(run: run, installationTag: tag, resolveDetails: { _, _ in tools }, recordChip: { _ in })
                .environment(model).environment(\.canonicalResourceSessionID, snapshot.sessionId)
                .environment(\.displayPresentationHandler, { activated = $0 })
                .environment(\.hostedToolActionProbe, probe)
                .environment(\.scenePhase, .active)
                .tronPresentationSurface(id: "routing-fixture")
                .environment(\.tronPresentationActivityCoordinator, coordinator)
            try await self.withSheet(content) { controller in
                XCTAssertTrue(probe.activate("run:\(run.id)"))
                try await self.waitForRouting { probe.contains("row:custom") }
                XCTAssertNotNil(controller.presentedViewController)
                XCTAssertTrue(probe.activate("row:custom"))
                XCTAssertNil(activated, "Never publish while the grouped sheet still covers the chat")
                if replacement == .installation {
                    model.installHostedAuthoritativeSnapshot(snapshot)
                    XCTAssertNotEqual(model.presentationGeneration(for: snapshot.sessionId), tag.presentationGeneration)
                } else if replacement == .source {
                    var replaced = snapshot
                    replaced.transcript = []
                    replaced.transcriptStart = 0
                    replaced.transcriptTotal = 0
                    replaced.revision += 1
                    model.replaceHostedAuthoritativeSnapshot(replaced)
                    XCTAssertEqual(model.presentationGeneration(for: snapshot.sessionId), tag.presentationGeneration)
                }
                try await self.waitForRouting { coordinator.mountedSurfaceCount == 1 }
                XCTAssertNil(controller.presentedViewController)
                XCTAssertEqual(activated, replacement == .none ? .showFloating(DisplayRoute(sessionID: snapshot.sessionId, display: display)) : nil)
            }
            XCTAssertEqual(probe.count, 0)
            XCTAssertEqual(coordinator.mountedSurfaceCount, 0)
        }
    }

    private func waitForRouting(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Mounted routing did not settle before its deadline")
    }

    func testMountedSingleBrowserRunUsesTheSameCustomActivation() async throws {
        let snapshot = try SessionScenarioBuilder(seed: 7_830).openingTail(targetEncodedBytes: 4_096)
        let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
        let display = routingDisplay(kind: .browserLive)
        let tool = routingTool(id: "browser", display: display)
        try await withModel { model in
            var activated: DisplayPresentationCommand?
            let probe = HostedToolActionProbe()
            let run = ChatToolRunPresentation(tools: [tool])
            let content = VStack {
                ToolRunView(run: run, installationTag: tag,
                    resolveDetails: { _, _ in XCTFail("Bound browser chip fell back to generic details"); return nil }, recordChip: { _ in })
                ToolCard(data: tool)
            }
                .environment(model).environment(\.canonicalResourceSessionID, snapshot.sessionId)
                .environment(\.displayPresentationHandler, { activated = $0 })
                .environment(\.hostedToolActionProbe, probe)
            try await self.withSheet(content) { _ in
                XCTAssertTrue(probe.activate("run:\(run.id)"))
                XCTAssertEqual(activated, .showFloating(DisplayRoute(sessionID: snapshot.sessionId, display: display)))
                activated = nil
                XCTAssertTrue(probe.activate("card:browser"))
                XCTAssertEqual(activated, .showFloating(DisplayRoute(sessionID: snapshot.sessionId, display: display)))
            }
            XCTAssertEqual(probe.count, 0)
        }
    }

    private func routingDisplay(kind: DisplayKind) -> DisplayProjection {
        DisplayProjection(displayId: "route", title: "Browser", altText: "Preview", kind: kind,
            presentation: .init(requestedSurface: .sheet, inlineTapAction: .sheet),
            eligibleSurfaces: DisplayPresentationPolicy.eligibleSurfaces(for: kind), fallbackText: "Unavailable",
            liveView: kind == .browserLive ? .init(schema: "tron.browser-live-view.v1", viewId: "view", generation: "generation",
                title: "Browser", fallbackText: "Unavailable") : nil)
    }

    private func routingTool(id: String, display: DisplayProjection? = nil) -> ChatToolPresentation {
        ChatToolPresentation(id: id, title: display == nil ? "Read" : "Browser", toolName: display?.kind == .browserLive ? "agent_browser" : "display",
            subtitle: "Completed", request: nil, response: nil, content: "Result", fallbackContent: nil, error: false,
            startedAt: nil, completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil, display: display)
    }

    func testBrowserExpansionUsesStandardChromeAndReopensAtMedium() async throws {
        let display = DisplayProjection(displayId: "browser-sheet", title: "Browser", altText: "Browser", kind: .browserLive,
            presentation: .init(requestedSurface: .floating, inlineTapAction: .sheet), eligibleSurfaces: [.sheet, .floating],
            fallbackText: "Unavailable", liveView: .init(schema: "tron.browser-live-view.v1", viewId: "view", generation: "generation",
                title: "Browser", fallbackText: "Unavailable"))
        try await withModel { model in
            for scheme: ColorScheme in [.light, .dark] {
                // No managed viewer owner: this chrome fixture must do no HTTP work.
                try await self.withSheet(DisplaySheet(route: DisplayRoute(sessionID: "session", display: display))
                    .environment(model).preferredColorScheme(scheme)) { controller in
                    let sheet = try XCTUnwrap(controller.sheetPresentationController)
                    XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
                    XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
                    XCTAssertFalse(sheet.prefersGrabberVisible)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronBlue, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "browser-medium-\(scheme)")
                    sheet.selectedDetentIdentifier = .large
                    controller.presentationController?.containerView?.layoutIfNeeded()
                    XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
                }
            }
        }
    }

    func testAutomationFilterRetainsItsMediumOnlyPresentation() async throws {
        try await withSheet(TronDashboardFilterSheet(
            title: "View Automations", accent: .tronAutomation, detents: [.medium], onDone: {}
        ) {
            TronDashboardFilterSectionTitle(title: "View")
        }) { controller in
            let sheet = try XCTUnwrap(controller.sheetPresentationController)
            XCTAssertEqual(sheet.detents.map(\.identifier), [.medium])
            XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
        }
    }

    func testManageWorkspaceRefreshWaitsForReconciledAuthorityAfterForeground() async throws {
        let gateway = ProcessSheetGatewayFixture()
        try await withModel(client: gateway.client) { model in
            try await gateway.connect(model: model)
            let snapshot = try SessionScenarioBuilder(seed: 7_841).openingTail(targetEncodedBytes: 4_096)
            model.installHostedSubscribedSnapshot(snapshot)
            model.beginHostedReconciliationAggregate()
            let probe = SessionWorkspaceRefreshProbe()
            let activity = WorkspaceRefreshActivity()
            try await self.withSheet(WorkspaceRefreshFixture(model: model, sessionID: snapshot.sessionId,
                                                            activity: activity, probe: probe)) { controller in
                let initialRequestCount = await gateway.socket.sentFrames().count
                XCTAssertEqual(initialRequestCount, 1,
                               "Presentation activation must not inspect an unreconciled session")
                model.completeHostedReconciliationAggregate(succeeded: true)
                try await gateway.respond(at: 1, method: "session.workspace.inspect", result: Self.workspaceInspection)
                await self.waitForWorkspace(probe, matching: .notRepository)

                activity.value = .covered
                model.beginHostedReconciliationAggregate()
                // Let SwiftUI retire the presentation task before reactivation.
                try await Task.sleep(for: .milliseconds(80))
                activity.value = .active
                await self.waitForWorkspace(probe, matching: .loading)
                let waitingRequestCount = await gateway.socket.sentFrames().count
                XCTAssertEqual(waitingRequestCount, 2)
                model.completeHostedReconciliationAggregate(succeeded: true)
                try await gateway.respond(at: 2, method: "session.workspace.inspect", result: Self.workspaceInspection)
                await self.waitForWorkspace(probe, matching: .notRepository)
                model.beginHostedReconciliationAggregate()
                await self.waitForWorkspace(probe, matching: .loading)
                model.completeHostedReconciliationAggregate(succeeded: true)
                try await gateway.waitForRequest(at: 3)
                var replacement = snapshot
                replacement.runtimeGeneration = "replacement-runtime"
                model.installHostedSubscribedSnapshot(replacement)
                try await gateway.waitForRequest(at: 4)
                try await gateway.respond(at: 3, method: "session.workspace.inspect", result: .object([:]))
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertEqual(probe.presentation, .loading, "A retired runtime's decode failure cannot publish into its successor")
                try await gateway.respond(at: 4, method: "session.workspace.inspect", result: Self.workspaceInspection)
                await self.waitForWorkspace(probe, matching: .notRepository)
                self.capture(controller, name: "manage-session-foreground-refreshed")
            }
            await gateway.client.close()
        }
    }

    private static var workspaceInspection: JSONValue {
        .object(["root": .string("/fixture"), "revision": .string("1"), "repository": .null])
    }

    private func waitForWorkspace(_ probe: SessionWorkspaceRefreshProbe,
                                  matching value: SessionWorkspaceRowPresentation) async {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { probe.presentation == value }
        }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(result, .completed, "The mounted production sheet must publish the current read without another activation")
    }

    func testFlatCompactionContainerRetainsRoundedSurface() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            try await self.withSheet(TronDocumentSheet(title: "Context compacted") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("24K tokens before compaction").font(TronTypography.bodySM)
                        Text("Goal\n\nContinue the current task while retaining the established constraints.")
                            .font(TronTypography.body).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14).modifier(DetailBodySurface(usesGlass: false, accent: .tronEmerald))
                    }.padding(18)
                }.tronScrollEdgeChrome()
            }.preferredColorScheme(scheme)) { controller in
                self.capture(controller, name: "flat-compaction-container-\(scheme)")
            }
        }
    }

    func testManageSessionShowsHeaderlessSessionAndExportCards() async throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_820).openingTail(targetEncodedBytes: 4_096)
        snapshot.contextUsage = ContextUsage(tokens: 157_000, contextWindow: 272_000, percent: 58)
        try await withModel { model in
            model.installHostedAuthoritativeSnapshot(snapshot)
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(SessionContextSheet(sessionID: snapshot.sessionId, onForkCreated: { _ in })
                    .environment(model).preferredColorScheme(scheme)) { controller in
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronEmerald, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "manage-session-top-\(scheme)")
                    scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                    controller.view.layoutIfNeeded()
                    self.capture(controller, name: "manage-session-containers-\(scheme)")
                }
            }
        }
    }

    func testModelPickerMatchesPurpleDestinationTheme() async throws {
        let selected = ModelSummary(
            provider: "test-provider", id: "test-model", name: "Example Model", reasoning: true,
            input: ["text"], contextWindow: 272_000, maxTokens: 8_192, available: true
        )
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(NavigationStack {
                ModelPicker(selection: .constant(selected.ref), models: [selected])
                    .tronNavigationTitle("Models", accent: .tronPurple)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button {} label: {
                                Image(systemName: "checkmark").foregroundStyle(Color.tronPurple)
                            }.accessibilityLabel("Done")
                        }
                    }
            }.tronSettingsVisualTheme(accent: .tronPurple).tronTopBlur(.sheet)
                .tronPresentation().preferredColorScheme(scheme)) { controller in
                let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                self.assertToolbarPaint(.tronPurple, bar: bar, leading: false, controller: controller)
                self.assertToolbarPaint(.tronPurple, bar: bar, leading: true, controller: controller)
                XCTAssertTrue(self.views(of: UITextField.self, in: controller.view).isEmpty,
                              "Models must not mount a search field before the toolbar action")
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                let region = scroll.convert(CGRect(x: 20, y: 30, width: 3, height: 15), to: controller.view)
                let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                    x: region.minX * image.scale, y: region.minY * image.scale,
                    width: region.width * image.scale, height: region.height * image.scale
                )))
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                XCTAssertGreaterThan(pixel[2], pixel[1], "Selected model row must inherit purple rather than green (RGBA: \(pixel))")
                self.capture(controller, name: "models-picker-purple-\(scheme)")
            }
        }
    }

    func testAllToolResultContainersUseLiteralMonospace() async throws {
        let output = "Run: workflow\n  Step: 1\n**literal output**, not Markdown\niiii WWWW 0000"
        var standardPixels: [UInt8]?
        for name in ["read", "subagent", "web_search", "fetch_content", "custom_extension"] {
            let tool = ChatToolPresentation(id: "result-font-\(name)", title: name, toolName: name, subtitle: "Completed",
                request: nil, response: nil, content: output, fallbackContent: nil, error: false,
                startedAt: nil, completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil)
            try await withSheet(TronDocumentSheet(title: "Tool result") {
                ToolDetailSheet(tool: tool, density: .glance)
            }) { controller in
                // SwiftUI Text need not create UILabels. Compare the actual
                // mounted result against the standard built-in code result,
                // including literal Markdown delimiters and indentation.
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let cg = try XCTUnwrap(image.cgImage)
                var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                if let standardPixels {
                    XCTAssertEqual(pixels.count, standardPixels.count)
                    let difference = zip(pixels, standardPixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
                    // Allow sub-byte native compositing variation, not a
                    // different output font or layout.
                    XCTAssertLessThan(difference / Double(pixels.count), 0.5,
                        "\(name) must render like the standard monospace result, not Markdown")
                } else {
                    standardPixels = pixels
                }
                if name == "subagent" { self.capture(controller, name: "subagent-monospace-result") }
            }
        }
    }

    func testToolTruncationNotesUseNeutralStyling() async throws {
        let tool = ChatToolPresentation(id: "truncated-message", title: "Subagent", toolName: "subagent", subtitle: "Completed",
            request: .object(["message": .string(String(repeating: "A long informational message. ", count: 50))]),
            response: nil, content: "Message delivered.", fallbackContent: nil, error: false,
            startedAt: nil, completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil)
        XCTAssertTrue(ToolDetailPresentation(tool: tool).primaryPreview?.isBounded == true)
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Subagent") {
                ToolDetailSheet(tool: tool, density: .glance)
            }.preferredColorScheme(scheme)) { controller in
                let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let cg = try XCTUnwrap(image.cgImage)
                var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                let amberPixels = stride(from: 0, to: pixels.count, by: 4).filter { i in
                    Double(pixels[i]) > 100 && Double(pixels[i]) > Double(pixels[i + 1]) * 1.3
                        && Double(pixels[i + 1]) > Double(pixels[i + 2]) * 1.1
                }.count
                XCTAssertEqual(amberPixels, 0, "Informational truncation must not render as an amber warning")
                self.capture(controller, name: "neutral-truncation-\(scheme)")
            }
        }
    }

    func testEditDetailsAndExpandedChangesShowDiffCountMetadata() async throws {
        let tool = ChatToolPresentation(
            id: "diff-count-fixture", title: "edit", subtitle: "Completed",
            request: .object(["path": .string("file.swift"), "edits": .array([
                .object(["oldText": .string("old"), "newText": .string("new\nextra")]),
            ])]),
            response: .object(["patch": .string("--- a/file.swift\n+++ b/file.swift\n@@ -1 +1,2 @@\n-old\n+new\n+extra")]),
            content: "Updated file.swift", fallbackContent: nil, error: false,
            startedAt: nil, completedAt: nil, durationMs: nil, lastProgressAt: nil, progressSequence: nil
        )
        let diff = try XCTUnwrap(ToolDetailPresentation(tool: tool).diff)
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(ToolChangesSheet(diff: diff, accent: .tronEmerald).preferredColorScheme(scheme)) { controller in
                self.capture(controller, name: "changes-sheet-counts-\(scheme)")
            }
            try await withSheet(TronDocumentSheet(title: "Edit file") {
                ToolDetailSheet(tool: tool, density: .glance)
            }.preferredColorScheme(scheme)) { controller in
                // Capture the mounted shared settings row in both appearances;
                // its subtitle typography is owned by TronSettingsRow.
                self.capture(controller, name: "edit-detail-counts-\(scheme)")
            }
        }
    }

    func testDocumentBackgroundMatchesNativeSheetMaterial() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            var native: [UInt8] = []
            try await withSheet(NavigationStack {
                Color.clear
            }.presentationDetents([.large]).preferredColorScheme(scheme)) { controller in
                native = self.centerPixel(in: controller)
            }
            try await withSheet(TronDocumentSheet(title: "Document") {
                Color.clear
            }.preferredColorScheme(scheme)) { controller in
                let document = self.centerPixel(in: controller)
                for channel in 0..<3 {
                    XCTAssertEqual(Double(document[channel]), Double(native[channel]), accuracy: 3,
                                   "Document content must reveal the native sheet material in \(scheme)")
                }
            }
            // Negative control: the removed opaque page must differ from the
            // material, otherwise this probe cannot detect the reported defect.
            if scheme == .dark {
                try await withSheet(NavigationStack {
                    Color.tronBackground
                }.presentationDetents([.large]).preferredColorScheme(scheme)) { controller in
                    let opaque = self.centerPixel(in: controller)
                    XCTAssertGreaterThan((0..<3).reduce(0) { $0 + abs(Int(opaque[$1]) - Int(native[$1])) }, 9)
                }
            }
        }
    }

    private func centerPixel(in controller: UIViewController) -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            context.cgContext.translateBy(x: -controller.view.bounds.midX, y: -controller.view.bounds.midY)
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }

    func testPlaceholderStatesUseInheritedAndSemanticAccents() throws {
        for scheme: ColorScheme in [.light, .dark] {
            for explicitAccent: Color? in [nil, .tronSessionTeal] {
                let renderer = ImageRenderer(content: TronPlaceholderState(
                    title: "Resources Unavailable",
                    detail: "Reload the session resources and try again.",
                    icon: "shippingbox.fill", accent: explicitAccent
                )
                .tronSettingsVisualTheme(accent: .tronPurple)
                .environment(\.colorScheme, scheme)
                .frame(width: 320)
                .background(Color.tronBackground))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage?.cgImage)
                var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try pixels.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(explicitAccent ?? .tronPurple).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
                var matches = 0
                for index in stride(from: 0, to: pixels.count, by: 4) {
                    let red = abs(CGFloat(pixels[index]) / 255 - r)
                    let green = abs(CGFloat(pixels[index + 1]) / 255 - g)
                    let blue = abs(CGFloat(pixels[index + 2]) / 255 - b)
                    if red < 0.08, green < 0.08, blue < 0.08 { matches += 1 }
                }
                XCTAssertGreaterThan(matches, 8, "Placeholder icon must inherit the sheet hue unless its category supplies one")
            }
        }
    }

    func testPlaceholderStatesWrapLongDetailsAndPresentThemedRecovery() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Sheet states") {
                ScrollView {
                    VStack(spacing: 8) {
                        TronPlaceholderState(title: "Terminal unavailable",
                            detail: "The connection could not be established. Check the Gateway connection and open the terminal again.",
                            icon: "terminal", accent: .tronEmerald)
                        TronPlaceholderState(title: "Resources Unavailable",
                            detail: "Reload the session resources and try again.",
                            icon: "shippingbox", accent: .tronSessionTeal)
                        TronPlaceholderState(title: "History unavailable", detail: "Reconnect to load recorded subagents.",
                            icon: "clock.arrow.circlepath", accent: .tronSubagent, actionTitle: "Reload", action: {})
                    }
                }
                .tronScrollEdgeChrome()
            }.presentationDetents([.large]).preferredColorScheme(scheme)) { controller in
                XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                self.capture(controller, name: "themed-sheet-states-\(scheme)")
            }
        }
        let short = ImageRenderer(content: TronPlaceholderState(title: "Unavailable", detail: "Short detail", icon: "terminal").frame(width: 220))
        let long = ImageRenderer(content: TronPlaceholderState(title: "Unavailable",
            detail: String(repeating: "Long failure descriptions must wrap without truncation. ", count: 8), icon: "terminal").frame(width: 220))
        XCTAssertGreaterThan(try XCTUnwrap(long.uiImage).size.height, try XCTUnwrap(short.uiImage).size.height + 100)
    }

    func testNoticeBurstPresentsOneInformationalCardAtATime() async throws {
        for (scheme, size) in [(ColorScheme.light, DynamicTypeSize.large), (.dark, .large), (.dark, .accessibility3)] {
            try await withModel { model in
                defer { model.noticeCenter.dismissAll() }
                model.postNotice("The Mac gateway is offline.", role: .error, lifetime: .automatic(.seconds(12)))
                model.noticeCenter.post(.init(id: UUID(), role: .warning,
                    title: "Gateway connection unavailable",
                    message: "Your conversation and draft are retained. Retry Connection and Logs are available in Settings.",
                    lifetime: .automatic(.seconds(12))))
                model.postNotice("Gateway update accepted.", role: .success, lifetime: .automatic(.seconds(12)))
                try await self.withSheet(
                    ZStack {
                        Color.tronBackground
                        InAppNoticeHost().environment(model)
                    }.preferredColorScheme(scheme).dynamicTypeSize(size)
                ) { controller in
                    XCTAssertEqual(model.visibleNotices.map(\.title), ["The Mac gateway is offline."])
                    XCTAssertTrue(self.views(of: UIControl.self, in: controller.view).isEmpty,
                                  "Information-only notices must not install buttons")
                    self.capture(controller, name: "notice-burst-compact-\(scheme)-\(size)")
                    model.noticeCenter.dismissVisible()
                    for _ in 0..<20 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    XCTAssertEqual(model.visibleNotices.map(\.title), ["Gateway connection unavailable"])
                    XCTAssertTrue(self.views(of: UIControl.self, in: controller.view).isEmpty)
                    self.capture(controller, name: "notice-burst-detail-\(scheme)-\(size)")
                    model.noticeCenter.dismissVisible()
                    XCTAssertEqual(model.visibleNotices.map(\.title), ["Gateway update accepted."])
                }
            }
        }
    }

    func testMarkdownTablesRenderInlineStylesInBothAppearances() async throws {
        let markdown = """
        | **Priority** | *Finding* |
        | --- | --- |
        | **1** | **Bold** and *italic* |
        | **2** | ~~Removed~~ and `code` |
        | **3** | ***Combined emphasis*** |
        | **4** | [A link](https://example.com) |
        | **5** | Plain text |
        | short |
        """
        for scheme: ColorScheme in [.light, .dark] {
            for streaming in [false, true] {
                try await withSheet(TronDocumentSheet(title: "Table formatting") {
                    ScrollView {
                        TronMarkdownView(text: markdown, streaming: streaming).padding(20)
                    }.tronScrollEdgeChrome()
                }.preferredColorScheme(scheme)) { controller in
                    let scrolls = self.views(of: UIScrollView.self, in: controller.view)
                    XCTAssertGreaterThanOrEqual(scrolls.count, 2, "Keep the table's horizontal scroll owner inside the document")
                    self.capture(controller, name: "markdown-table-styles-\(scheme)-\(streaming)")
                }
            }
        }
    }

    func testHTMLDocumentUsesOnlyCustomTopBlur() async throws {
        let html = "<meta name='viewport' content='width=device-width, initial-scale=1'><style>body{background:#102720;color:#e0f0ea;font:24px system-ui;padding:20px}p{margin:40px 0}</style><h1>HTML preview</h1>"
            + String(repeating: "<p>Scrollable document content beneath the custom blur.</p>", count: 30)
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "HTML preview") {
                StaticDisplayWebView(html: html).tronDocumentTopBlurSurface()
            }.preferredColorScheme(scheme)) { controller in
                let web = try XCTUnwrap(self.views(of: WKWebView.self, in: controller.view).first)
                for _ in 0..<180 {
                    if !web.isLoading && web.scrollView.contentSize.height > web.bounds.height { break }
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                XCTAssertFalse(web.isLoading)
                XCTAssertGreaterThan(web.scrollView.contentSize.height, web.bounds.height)
                XCTAssertTrue(web.scrollView.topEdgeEffect.isHidden,
                              "WebKit must not add a hard native edge beneath the custom blur")
                XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
                XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
                XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                web.scrollView.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
                for _ in 0..<8 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                self.capture(controller, name: "html-custom-top-blur-\(scheme)")
            }
        }
    }

    func testInstructionsOpenAsALargeDocumentWithCustomBlurAndNoBottomToolbar() async throws {
        try await withModel { model in
            try await self.withSheet(AgentInstructionsSheet(sessionID: "document-fixture").environment(model)) { controller in
                let sheet = try XCTUnwrap(controller.sheetPresentationController)
                XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.large])
                XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                XCTAssertTrue(self.views(of: UIToolbar.self, in: controller.view).allSatisfy(\.isHidden))
            }
        }
    }

    func testPlainDocumentReaderKeepsFullSelectableContent() async throws {
        let instructions = String(repeating: "Read the complete instructions.\n", count: 2_000) + "END OF INSTRUCTIONS"
        try await withModel { model in
            model.installHostedSecondaryProjection(
                context: .object(["systemPrompt": .string(instructions)]), tree: [], commands: [], resources: nil
            )
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(TronDocumentSheet(title: "Document") {
                    TronReadOnlyTextView(text: instructions).tronDocumentTopBlurSurface()
                }.environment(model).preferredColorScheme(scheme)) { controller in
                    let reader = try XCTUnwrap(self.views(of: UITextView.self, in: controller.view).first)
                    XCTAssertEqual(reader.text, instructions)
                    XCTAssertTrue(reader.isSelectable)
                    XCTAssertTrue(reader.isScrollEnabled)
                    XCTAssertFalse(reader.isEditable)
                    XCTAssertEqual(reader.backgroundColor, .clear)
                    let readerFrame = reader.convert(reader.bounds, to: controller.view)
                    // Both edges belong to the viewport, not empty safe-area
                    // strips. Internal scroll insets protect the first/last lines.
                    XCTAssertEqual(readerFrame.maxY, controller.view.bounds.maxY, accuracy: 1)
                    XCTAssertGreaterThanOrEqual(
                        reader.textContainerInset.bottom + reader.adjustedContentInset.bottom,
                        controller.view.safeAreaInsets.bottom
                    )
                    XCTAssertEqual(readerFrame.minY, controller.view.bounds.minY, accuracy: 1,
                                   "The reader must scroll behind the blur, not clip below the title")
                    let firstLine = reader.convert(reader.caretRect(for: reader.beginningOfDocument), to: controller.view)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    let barFrame = bar.convert(bar.bounds, to: controller.view)
                    XCTAssertLessThanOrEqual(firstLine.minY, barFrame.maxY + 30,
                                             "Decorative blur height must not add a second header gap")
                    XCTAssertEqual(reader.textContainerInset.left + reader.contentInset.left, 18)
                    for offset in [-18.0, -0.5, 0.5, 120] {
                        reader.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                        let nativeOffset = reader.contentOffset.y
                        reader.setNeedsLayout()
                        reader.layoutIfNeeded()
                        XCTAssertEqual(reader.contentOffset.y, nativeOffset, accuracy: 0.01)
                    }
                    reader.setContentOffset(.zero, animated: false)
                    XCTAssertGreaterThanOrEqual(firstLine.minY, controller.view.safeAreaInsets.top,
                                                "Opening the full-height reader must not hide its first line")
                    let blurs = self.views(of: VariableBackdropBlurView.self, in: controller.view)
                    XCTAssertEqual(blurs.count, 1)
                    let blur = try XCTUnwrap(blurs.first)
                    let blurFrame = blur.convert(blur.bounds, to: controller.view)
                    XCTAssertGreaterThan(blurFrame.maxY, controller.view.safeAreaInsets.top + 20,
                                         "The fade must continue below navigation, not end at a hard boundary")
                    let geometry = XCTAttachment(string: "reader: \(readerFrame), blur: \(blurFrame), adjusted: \(reader.adjustedContentInset)")
                    geometry.name = "instructions-geometry-\(scheme)"
                    geometry.lifetime = .keepAlways
                    self.add(geometry)
                    reader.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
                    controller.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                        controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                    }
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "instructions-scrolled-document-\(scheme)"
                    attachment.lifetime = .keepAlways
                    self.add(attachment)
                }
            }
        }
    }

    func testProjectResourcesRowsShowAuthoritativeScopeBadges() async throws {
        try await withModel { model in
            let resources: JSONValue = .object([
                "prompts": .array([.object([
                    "name": .string("review"), "description": .string("Review changes."),
                    "scope": .string("project"), "origin": .string("top-level")
                ])]),
                "skills": .array([.object([
                    "name": .string("audit"), "description": .string("Audit the code."),
                    "scope": .string("user"), "origin": .string("top-level")
                ])]),
                "tools": .array([.object([
                    "name": .string("read"), "description": .string("Read a file."),
                    "scope": .string("user"), "origin": .string("package")
                ])]),
                "extensions": .array([])
            ])
            model.installHostedSecondaryProjection(context: nil, tree: [], commands: [], resources: resources)
            try await withSheet(ProjectResourcesView(sessionID: "resource-fixture").environment(model)
                .preferredColorScheme(.light)) { controller in
                try await Task.sleep(for: .milliseconds(120))
                self.capture(controller, name: "project-resources-scope-badges-light")
            }
        }
    }

    func testProjectHooksShowSuccessfulExtensionAndEventInventoriesWithDetails() async throws {
        let runtimeValue: JSONValue = .object([
            "extensions": .array([.object([
                "name": .string("review-hook.ts"),
                "path": .string("/workspace/.tron/extensions/review-hook.ts"),
                "resolvedPath": .string("/workspace/.tron/extensions/review-hook.ts"),
                "scope": .string("project"),
                "source": .string("top-level"),
                "origin": .string("top-level"),
                "handlers": .array([
                    .object(["event": .string("session_start"), "count": .number(1)]),
                    .object(["event": .string("before_agent_start"), "count": .number(2)])
                ])
            ])]),
            "hookInventory": .object([
                "extensions": .object(["total": .number(1), "retained": .number(1), "omitted": .number(0)]),
                "handlerEvents": .object(["total": .number(2), "retained": .number(2), "omitted": .number(0)]),
                "loadErrors": .object(["total": .number(1), "retained": .number(1), "omitted": .number(0)]),
                "textFieldsOmitted": .number(0),
            ]),
            "extensionLoadErrors": .array([.object([
                "path": .string("/workspace/.tron/extensions/broken.ts"),
                "error": .string("SyntaxError: expected handler export")
            ])])
        ])
        let record = try XCTUnwrap(HookInventoryPresentation.extensions(from: runtimeValue).first)

        let gateway = ProcessSheetGatewayFixture()
        try await withModel(client: gateway.client) { model in
            try await gateway.connect(model: model)
            let snapshot = try SessionScenarioBuilder(seed: 9_403).openingTail(targetEncodedBytes: 4_096)
            model.installHostedSubscribedSnapshot(snapshot)
            // Seed the same-owner hosted projection so the sheet has a stable
            // success surface while the real resources request is admitted.
            model.installHostedSecondaryProjection(context: nil, tree: [], commands: [], resources: runtimeValue)

            func respondToNext(_ method: String, result: JSONValue, startingAt: Int = 1) async throws {
                var index = startingAt
                while true {
                    try await gateway.waitForRequest(at: index)
                    let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await gateway.socket.sentFrames()[index])
                    guard request.objectValue?["method"]?.stringValue != method else {
                        let id = try XCTUnwrap(request.objectValue?["id"]?.stringValue)
                        await gateway.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result
                        ])))
                        return
                    }
                    index += 1
                }
            }
            let projectResponse = Task {
                try await respondToNext("session.resources", result: runtimeValue)
            }
            defer { projectResponse.cancel() }
            try await self.withSheet(ProjectHooksView(sessionID: snapshot.sessionId).environment(model)
                .preferredColorScheme(.dark)) { controller in
                try await Task.sleep(for: .milliseconds(300))
                controller.view.layoutIfNeeded()
                let methods = (await gateway.socket.sentFrames()).compactMap { try? JSONDecoder.gateway.decode(JSONValue.self, from: $0).objectValue?["method"]?.stringValue }
                XCTAssertTrue(methods.contains("session.resources"))
                XCTAssertEqual(model.sessionResources(for: snapshot.sessionId), runtimeValue)
                XCTAssertEqual(HookInventoryPresentation.extensions(from: model.sessionResources(for: snapshot.sessionId)).first, record)
                XCTAssertEqual(HookInventoryPresentation.issues(from: model.sessionResources(for: snapshot.sessionId)).first?.message, "SyntaxError: expected handler export")
                XCTAssertEqual(model.sessionPresentationIdentity(for: snapshot.sessionId)?.sessionID, snapshot.sessionId)
                let initialScroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                XCTAssertEqual(initialScroll.contentOffset.y, -initialScroll.adjustedContentInset.top, accuracy: 1.0)
                self.capture(controller, name: "hooks-project-success-dark")
            }
            try await projectResponse.value
            try await self.withSheet(ProjectHooksView(sessionID: snapshot.sessionId, initialMode: .byEvent, showsUnregisteredEvents: true).environment(model)
                .preferredColorScheme(.light)) { controller in
                try await Task.sleep(for: .milliseconds(300))
                controller.view.layoutIfNeeded()
                let eventScroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                XCTAssertEqual(eventScroll.contentOffset.y, -eventScroll.adjustedContentInset.top, accuracy: 1.0)
                self.capture(controller, name: "hooks-project-by-event-light")
            }
            for _ in 0..<20 where model.isReconcilingForeground {
                try await Task.sleep(for: .milliseconds(50))
            }

        }

        try await withSheet(HookExtensionDetailView(record: record, accent: .tronSessionTeal)
            .environment(\.dynamicTypeSize, .accessibility2)
            .preferredColorScheme(.light)) { controller in
            XCTAssertEqual(record.provenance, .project)
            XCTAssertEqual(record.handlers.map(\.event), ["before_agent_start", "session_start"])
            XCTAssertEqual(record.handlerCount, 3)
            self.capture(controller, name: "hooks-project-detail-light")
            let navigationBar = self.views(of: UINavigationBar.self, in: controller.view).first
            let info = controller.navigationItem.leftBarButtonItem
                ?? controller.navigationController?.topViewController?.navigationItem.leftBarButtonItem
                ?? navigationBar?.topItem?.leftBarButtonItems?.first
            if let info, let action = info.action {
                UIApplication.shared.sendAction(action, to: info.target, from: info, for: nil)
                try await self.waitForRouting {
                    controller.presentedViewController != nil
                        || controller.navigationController?.presentedViewController != nil
                }
                let technical = controller.presentedViewController
                    ?? controller.navigationController?.presentedViewController
                if let technical {
                    self.capture(technical, name: "hooks-project-info-light")
                }
            }
        }

        try await withSheet(TechnicalJSONSheet(
            value: .object([
                "event": .string("session_start"),
                "title": .string("Session starts"),
                "supportedByPinnedSDK": .bool(true),
                "providers": .array([.object(["name": .string("review-hook"), "count": .number(2)])]),
            ]), title: "Event Details", accent: .tronSessionTeal,
            detent: .constant(.medium), onEdit: nil
        ).preferredColorScheme(.light)) { controller in
            self.capture(controller, name: "hooks-event-details-direct-light")
        }

        try await withSheet(TechnicalJSONSheet(
            value: .object([
                "path": .string("/workspace/.tron/extensions/review-hook.ts"),
                "scope": .string("project"),
                "handlers": .array([
                    .object(["event": .string("session_start"), "count": .number(1)]),
                    .object(["event": .string("before_agent_start"), "count": .number(2)])
                ])
            ]), title: "Hook Technical Details", accent: .tronSessionTeal,
            detent: .constant(.medium), onEdit: nil
        ).preferredColorScheme(.dark)) { controller in
            for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
            self.capture(controller, name: "hooks-project-info-dark")
        }
    }

    func testProjectResourceDetailsLoadPromptAndSkillBodies() async throws {
        for kind in [ProjectResourceKind.prompts, .skills] {
            let gateway = ProcessSheetGatewayFixture()
            try await withModel(client: gateway.client) { model in
                try await gateway.connect(model: model)
                let snapshot = try SessionScenarioBuilder(seed: 9_402).openingTail(targetEncodedBytes: 4_096)
                model.installHostedSubscribedSnapshot(snapshot)
                let selection = ProjectResourceSelection(kind: kind, title: "Review Resource", value: .object([
                    "name": .string("review"),
                    "description": .string("Review changes with focused checks."),
                    "scope": .string("project"),
                    "path": .string("/project/resources/review.md"),
                ]))
                let command = try XCTUnwrap(selection.commandInfo)
                let content = "# Review\n\nRead the owning documentation.\n\n- Check correctness\n- Run focused tests\n\n" + (0..<40).map { "## Check \($0)\n\nReport verified results.\n" }.joined(separator: "\n")
                let detail = CommandResourceDetail(
                    name: command.name, description: command.description, argumentHint: nil, source: command.source,
                    sourcePath: command.sourcePath, resourceSource: "project", resourceScope: .project, resourceOrigin: nil,
                    content: content, contentBytes: content.utf8.count, contentTruncated: false
                )
                let response = Task {
                    try await gateway.respond(at: 1, method: "session.commandDetail", result: JSONValue.encode(detail))
                }
                defer { response.cancel() }
                try await self.withSheet(ProjectResourceDetailSheet(sessionID: snapshot.sessionId, selection: selection, onDone: {})
                    .environment(model).preferredColorScheme(.light)) { controller in
                    try await response.value
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    try await self.waitForRouting {
                        controller.view.layoutIfNeeded()
                        return scroll.contentSize.height > 2_000
                    }
                    XCTAssertGreaterThan(scroll.contentSize.height, 2_000, "The fetched body must render beyond the description or loading placeholder")
                    self.capture(controller, name: "project-resource-loaded-\(kind.key)")
                }
                await gateway.client.close()
            }
        }
    }

    func testProjectResourceDetailsOverrideOverviewTheme() async throws {
        try await withModel { model in
            for kind in ProjectResourceKind.allCases {
                let selection = ProjectResourceSelection(kind: kind, title: "Review Resource", value: .object([
                    "description": .string("A resource for reviewing changes."),
                    "scope": .string("project"),
                    "tools": .array([.string("review")]),
                ]))
                try await self.withSheet(ProjectResourceDetailSheet(sessionID: "resource-fixture", selection: selection, onDone: {})
                    .environment(model).tronSettingsVisualTheme(accent: .tronSessionTeal)) { controller in
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(kind.accent, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "project-detail-\(kind.key)")
                }
            }
        }
    }

    func testWorktreeSelectionUsesOnlyOneEditableNewName() async throws {
        let inspection = GitInspection(isRepository: true, branch: "main", isDirty: false,
            branches: [.init(name: "main", checkedOut: true), .init(name: "feature/review", checkedOut: false)],
            commits: [.init(oid: String(repeating: "a", count: 40), subject: "Prepare review")])
        for mode: SessionSourceControlMode in [.newBranchWorktree, .existingBranchWorktree] {
            try await withSheet(NewSessionSourceControlSheet(
                selection: .constant(.init(mode: mode, branch: mode == .newBranchWorktree ? "feature/new" : "feature/review", base: nil)),
                inspection: inspection, inspectionFailed: false
            ).preferredColorScheme(.dark)) { controller in
                XCTAssertEqual(self.views(of: UITextField.self, in: controller.view).count,
                               mode == .newBranchWorktree ? 1 : 0,
                               "Only a newly authored branch name is free text; existing refs use choices")
                self.capture(controller, name: "worktree-choices-\(mode)")
            }
        }
    }

    func testInstructionsRenderMarkdownBlocks() async throws {
        let instructions = "# Project Rules\n\nUse **focused tests** and `git diff`.\n\n- Preserve user data\n- Read the owning docs\n\n```swift\nlet safe = true\n```\n\n> Review before delivery."
        try await withModel { model in
            model.installHostedSecondaryProjection(
                context: .object(["systemPrompt": .string(instructions)]), tree: [], commands: [], resources: nil
            )
            try await self.withSheet(AgentInstructionsSheet(sessionID: "document-fixture").environment(model)) { controller in
                let mounted = await self.waitForFirstView(of: UIScrollView.self, in: controller.view)
                XCTAssertNotNil(mounted, "Prepared instructions must mount their scroll document")
                let content = try XCTUnwrap(mounted)
                XCTAssertTrue(content.isScrollEnabled)
                XCTAssertFalse(self.views(of: TronDocumentTextView.self, in: controller.view).contains { $0.text == instructions },
                               "Instructions must use block markdown, not the plain document reader")
                self.capture(controller, name: "instructions-markdown")
            }
        }
    }

    func testInstructionsRetainThePreparedDocumentAcrossCoverAndUncover() async throws {
        let instructions = "# Project Rules\n\n" + String(repeating: "Preserve **user data** and read the owning docs.\n\n", count: 400)
        try await withModel { model in
            model.installHostedSecondaryProjection(
                context: .object(["systemPrompt": .string(instructions)]), tree: [], commands: [], resources: nil
            )
            let activity = DocumentSurfaceActivity()
            try await self.withSheet(AgentInstructionsSheet(sessionID: "document-fixture")
                .environment(model)
                .environment(\.tronPresentationActivity, activity.value)) { controller in
                let mounted = await self.waitForFirstView(of: UIScrollView.self, in: controller.view)
                XCTAssertNotNil(mounted)
                let prepared = try XCTUnwrap(mounted)
                XCTAssertTrue(self.views(of: TronDocumentTextView.self, in: controller.view).isEmpty)

                activity.value = .covered
                await self.settleSheetPresentation()
                activity.value = .active
                await self.settleSheetPresentation()

                // A cover/uncover cycle must reuse the completed document rather
                // than blanking it into a loading placeholder or re-parsing it.
                XCTAssertFalse(self.views(of: UIScrollView.self, in: controller.view).isEmpty,
                               "Uncovering must keep the prepared instruction document mounted")
                XCTAssertTrue(self.views(of: UIScrollView.self, in: controller.view).first === prepared,
                              "Uncovering must not rebuild the prepared instruction document")
                XCTAssertTrue(self.views(of: TronDocumentTextView.self, in: controller.view).isEmpty)
            }
        }
    }

    func testDisplayRouteKeepsDocumentChromeWhenMediaIsUnavailable() async throws {
        try await withModel { model in
            let display = DisplayProjection(
                displayId: "display-fixture", title: "Working Plan", altText: "A Markdown plan",
                kind: .markdown, presentation: .init(requestedSurface: .sheet, inlineTapAction: .sheet),
                eligibleSurfaces: [.sheet], fallbackText: "Document is unavailable.",
                artifact: .init(id: "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b", name: "plan.md", mimeType: "text/markdown", size: 50, kind: .markdown)
            )
            try await self.withSheet(DisplaySheet(route: DisplayRoute(sessionID: "missing-session", display: display)).environment(model)) { controller in
                XCTAssertEqual(controller.sheetPresentationController?.detents.map(\.identifier), [.large])
                XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                XCTAssertTrue(self.views(of: UIToolbar.self, in: controller.view).allSatisfy(\.isHidden))
            }
        }
    }

    func testDisplayDocumentReaderUsesCustomBlurAndPreservesAuthoredTitle() async throws {
        let text = (0..<40).map { "## Section \($0)\n\nRead the whole document, including the final section.\n" }.joined(separator: "\n")
        try await withModel { model in
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(AttachmentFilePreviewSheet(
                    name: "report.md", mimeType: "text/markdown",
                    source: .local(id: "display-document", data: Data(text.utf8)), title: "Working Plan"
                ).environment(model).preferredColorScheme(scheme)) { controller in
                    XCTAssertEqual(controller.sheetPresentationController?.detents.map(\.identifier), [.large])
                    XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                    scroll.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
                    controller.view.layoutIfNeeded()
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronBlue, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "display-markdown-scrolled-\(scheme)")
                }
            }
        }
    }

    func testCommandPromptContentContainerShowsCompleteScrollableBody() async throws {
        let content = (0..<40).map { "## Instruction \($0)\n\nComplete this step before continuing.\n" }.joined(separator: "\n") + "\nFINAL PROMPT INSTRUCTION"
        let preview = ComposerResourceContentPresentation.preview(content, source: .prompt, sourceTruncated: true)
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Prompt") {
                ScrollView {
                    ComposerResourceContentBody(preview: preview, source: .prompt)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronScrollSurface(accent: .tronPurple, cornerRadius: 16, tintOpacity: 0.06)
                        .padding(18)
                }.tronScrollEdgeChrome()
            }.preferredColorScheme(scheme)) { controller in
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                XCTAssertGreaterThan(scroll.contentSize.height, 2_000, "Prompt containers must include instructions beyond the extension excerpt limit")
                // Capture the mounted shared content body; SwiftUI text is not
                // guaranteed to materialize as UILabel, so the regression is
                // the rendered component rather than an implementation detail.
                self.capture(controller, name: "prompt-truncation-\(scheme)")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                controller.view.layoutIfNeeded()
                self.capture(controller, name: "command-prompt-final-instructions-\(scheme)")
            }
        }
    }

    func testTruncationNoticeUsesSharedSecondaryDescriptionSurface() async throws {
        let preview = ComposerResourceContentPresentation.Preview(text: "A bounded preview.", isTruncated: true)
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Prompt") {
                ComposerResourceContentBody(preview: preview, source: .prompt)
                    .padding(18)
            }.preferredColorScheme(scheme)) { controller in
                self.capture(controller, name: "prompt-truncation-notice-\(scheme)")
            }
        }
    }

    func testPackageSourceFieldUsesSettingsBlueRatherThanGreen() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(TronDocumentSheet(title: "Install Package") {
                PackageSourceField(source: .constant(""))
                    .padding(20)
                    .frame(maxHeight: .infinity, alignment: .top)
            }.tronSettingsVisualTheme(accent: .tronBlue).preferredColorScheme(scheme)) { controller in
                let field = try XCTUnwrap(self.views(of: UITextField.self, in: controller.view).first)
                let fieldFrame = field.convert(field.bounds, to: controller.view)
                // Sample the painted container beside the text field. Glass
                // and border both used to hard-code emerald despite a blue title.
                let region = CGRect(x: 22, y: fieldFrame.midY - 10, width: 8, height: 20)
                let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
                    x: region.minX * image.scale, y: region.minY * image.scale,
                    width: region.width * image.scale, height: region.height * image.scale
                )))
                var pixel = [UInt8](repeating: 0, count: 4)
                pixel.withUnsafeMutableBytes { buffer in
                    let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                        bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                }
                XCTAssertGreaterThan(pixel[2], pixel[1], "Source container must be blue, not green (RGBA: \(pixel))")
                self.capture(controller, name: "package-source-\(scheme)")
            }
        }
    }

    func testAppSettingsEmeraldGlassInBothAppearances() async throws {
        let suite = "app-settings-glass.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppLocalBehaviorSettings(defaults: defaults)
        for scheme in [ColorScheme.light, .dark] {
            try await withSheet(NavigationStack {
                AppLocalBehaviorSettingsView(settings: settings)
            }.tronSettingsVisualTheme(accent: .tronEmerald).preferredColorScheme(scheme)) { controller in
                let field = try XCTUnwrap(self.views(of: UITextField.self, in: controller.view).first)
                XCTAssertEqual(field.text, "10")
                self.capture(controller, name: "app-settings-emerald-glass-\(scheme)")
            }
        }
    }

    func testAppSettingsCommitsChatsPerProject() async throws {
        let suite = "app-settings-sheet.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppLocalBehaviorSettings(defaults: defaults)
        try await withSheet(NavigationStack {
            AppLocalBehaviorSettingsView(settings: settings)
        }.tronSettingsVisualTheme(accent: .tronEmerald)) { controller in
            let field = try XCTUnwrap(self.views(of: UITextField.self, in: controller.view).first)
            XCTAssertEqual(field.keyboardType, .numberPad)
            XCTAssertEqual(field.text, "10")
            field.becomeFirstResponder()
            for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
            field.text = "7"
            field.sendActions(for: .editingChanged)
            field.resignFirstResponder()
            for _ in 0..<6 { try await DisplayFrameScheduler.displayLink.nextFrame() }
            XCTAssertEqual(settings.dashboardChatsPerProject, 7)
            XCTAssertEqual(AppLocalBehaviorSettings(defaults: defaults).dashboardChatsPerProject, 7)
            self.capture(controller, name: "app-settings-chats-per-project")
        }
    }

    func testInlinePhotoLoadsAfterReadinessAndResumeWithoutAnotherSheet() async throws {
        for mode in 0..<4 {
            let arrived = expectation(description: "Thumbnail HTTP request \(mode)")
            let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { release.continuation.finish() }
            let fixture = try SessionScenarioBuilder(seed: 6_321).generatedImageFixture(
                format: .jpeg, pixelWidth: 100, pixelHeight: 100, orientation: .up)
            let gateway = ProcessSheetGatewayFixture(transport: .init { request, _ in
                arrived.fulfill()
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next()
                if mode == 3 { throw CancellationError() }
                return (fixture.encodedData, HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: ["Content-Type": "image/jpeg"])!)
            })
            try await withModel(client: gateway.client) { model in
                try await gateway.connect(model: model)
                let display = DisplayProjection(displayId: "photo", title: "Photo", altText: "Preview", kind: .image,
                    presentation: .init(requestedSurface: .inline, inlineTapAction: .sheet),
                    eligibleSurfaces: [.inline, .sheet], fallbackText: "Unavailable",
                    artifact: .init(id: "11111111-2222-4333-8444-555555555555", name: "image.jpg", mimeType: "image/jpeg",
                                    size: fixture.encodedData.count, kind: .image))
                let state = InlinePhotoResumeFixture.State(ready: mode == 1, active: mode == 0)
                let identity = try XCTUnwrap(model.chatMediaIdentity(blobID: "11111111-2222-4333-8444-555555555555", sessionID: "photo-fixture"))
                try await self.withSheet(InlinePhotoResumeFixture(tool: self.routingTool(id: "photo", display: display).descriptor,
                                                                 state: state).environment(model)) { controller in
                    XCTAssertFalse(self.views(of: UIActivityIndicatorView.self, in: controller.view).isEmpty)
                    state.ready = true
                    state.active = true
                    let request = await XCTWaiter.fulfillment(of: [arrived], timeout: 3)
                    XCTAssertEqual(request, .completed)
                    // Finish the appearance/readiness callbacks before allowing the
                    // real loader's response to publish. No sheet or tap wakes it.
                    for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    release.continuation.yield(())
                    try await self.waitForRouting {
                        (mode == 3 || model.chatMedia.cachedThumbnail(for: identity) != nil)
                            && self.views(of: UIActivityIndicatorView.self, in: controller.view).isEmpty
                    }
                }
                await model.teardown()
            }
        }
    }

    func testInlinePhotoLoadingSpinnerIsEmerald() async throws {
        let display = DisplayProjection(displayId: "photo", title: "Photo", altText: "Preview", kind: .image,
            presentation: .init(requestedSurface: .inline, inlineTapAction: .sheet),
            eligibleSurfaces: [.inline, .sheet], fallbackText: "Unavailable")
        let tool = routingTool(id: "photo", display: display)
        try await withModel { model in
            for scheme: ColorScheme in [.light, .dark] {
                try await self.withSheet(DisplayToolView(tool: tool.descriptor, onOpenTechnicalDetails: {})
                    .environment(model).environment(\.displayTranscriptReady, false)
                    .environment(\.canonicalResourceSessionID, "photo-fixture")
                    .preferredColorScheme(scheme)) { controller in
                    let spinner = try XCTUnwrap(self.views(of: UIActivityIndicatorView.self, in: controller.view).first)
                    let actual = try XCTUnwrap(spinner.color).resolvedColor(with: spinner.traitCollection)
                    let expected = UIColor(Color.tronEmerald).resolvedColor(with: spinner.traitCollection)
                    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
                    var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
                    actual.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
                    expected.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
                    XCTAssertEqual(ar, er, accuracy: 0.01)
                    XCTAssertEqual(ag, eg, accuracy: 0.01)
                    XCTAssertEqual(ab, eb, accuracy: 0.01)
                    self.capture(controller, name: "inline-photo-loading-\(scheme)")
                }
            }
        }
    }

    func testSubagentListsStartAtMediumOnEachPresentation() async throws {
        try await withModel { model in
            for _ in 0..<2 {
                try await self.withSheet(ProcessHistorySheet(sessionID: "history-fixture").environment(model)) { controller in
                    let sheet = try XCTUnwrap(controller.sheetPresentationController)
                    XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
                    XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronSessionTeal, bar: bar, leading: false, controller: controller)
                    // Users can still expand this presentation; a fresh presentation starts medium.
                    sheet.selectedDetentIdentifier = .large
                }
                try await self.withSheet(SessionActivitySheet(
                    sessionID: "process-fixture",
                    extensionContent: ExtensionRetainedContent(entries: []),
                    omittedExtensionContentCount: 0,
                    processActivities: []
                ).environment(model)) { controller in
                    XCTAssertEqual(controller.sheetPresentationController?.selectedDetentIdentifier, .medium)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronEmerald, bar: bar, leading: false, controller: controller)
                }
            }
        }
    }

    func testCompletedSubagentTranscriptOpensWithVisibleContentWithoutScrolling() async throws {
        let paragraph = "The worker inspected the selected files and verified the focused checks. "
        let longTranscript = (0..<16).map { index in
            "## Inspection \(index + 1)\n\n" + String(repeating: paragraph, count: index % 4 + 1)
        } + ["## Completed\n\n" + String(repeating: paragraph + "\n\n", count: 20) + "Final result is ready."]
        for texts in [[], ["The worker completed the requested review."], longTranscript] {
            let gateway = ProcessSheetGatewayFixture()
            try await withModel(client: gateway.client) { model in
                try await gateway.connect(model: model)
                let snapshot = try SessionScenarioBuilder(seed: 8_920).openingTail(targetEncodedBytes: 4_096)
                model.installHostedAuthoritativeSnapshot(snapshot)
                let response = Task {
                    try await gateway.respond(at: 1, method: "session.processTranscript.open",
                        result: ProcessSheetGatewayFixture.transcript(texts: texts))
                }
                defer { response.cancel() }
                try await self.withSheet(ReadOnlySubagentSessionSheet(
                    parentSessionID: snapshot.sessionId, process: ProcessSheetGatewayFixture.process()
                ).environment(model)) { controller in
                    try await response.value
                    try await self.waitForRouting { !self.views(of: UIScrollView.self, in: controller.view).isEmpty }
                    // Let asynchronous Markdown preparation and native lazy measurement settle,
                    // without sending a scroll command or dragging the sheet.
                    for _ in 0..<12 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    self.capture(controller, name: "worker-initial-\(texts.count)-messages")
                    self.assertSubagentOpeningOffset(scroll, isLong: texts.count > 1)
                    controller.sheetPresentationController?.selectedDetentIdentifier = .large
                    controller.presentationController?.containerView?.layoutIfNeeded()
                    for _ in 0..<6 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                    self.assertSubagentOpeningOffset(scroll, isLong: texts.count > 1)
                    self.capture(controller, name: "worker-expanded-\(texts.count)-messages")
                    if texts.count > 1 {
                        scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
                        for _ in 0..<6 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                        let readingOffset = scroll.contentOffset.y
                        controller.sheetPresentationController?.selectedDetentIdentifier = .medium
                        controller.presentationController?.containerView?.layoutIfNeeded()
                        for _ in 0..<6 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                        XCTAssertEqual(scroll.contentOffset.y, readingOffset, accuracy: 2,
                            "Resizing must not pull a reader away from earlier messages back to the tail")
                    }
                }
            }
            await gateway.client.close()
        }
    }

    private func subagentProcessFixture(
        state: SessionProcessLifecycleState,
        processID: String? = nil,
        title: String? = nil,
        output: String = "Reviewing the selected files."
    ) -> SessionProcessActivity {
        let now = Date.now
        return SessionProcessActivity(
            processId: processID ?? state.rawValue, kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
            lifecycle: SessionProcessLifecycle(state: state, sequence: 1, observedAt: GatewayTimestamp.string(from: now),
                terminalAt: state == .running ? nil : GatewayTimestamp.string(from: now),
                recentUntil: state == .running ? nil : GatewayTimestamp.string(from: now.addingTimeInterval(300))),
            visibility: state == .running ? .active : .recent,
            startedAt: GatewayTimestamp.string(from: .now.addingTimeInterval(-42)),
            title: title ?? state.displayName, currentTool: state == .running ? "read" : nil,
            model: "openai-codex/gpt-5.6-luna", thinking: "high",
            outputTail: output, durationMs: 42_000,
            toolCount: 12, turnCount: 4, childCount: 1
        )
    }

    private func assertSubagentOpeningOffset(_ scroll: UIScrollView, isLong: Bool) {
        let top = -scroll.adjustedContentInset.top
        let tail = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        XCTAssertEqual(scroll.contentOffset.y, isLong ? tail : top, accuracy: 2,
            "Initial and resized sheets must show the tail (or top-aligned short content), never an empty lazy-layout gap")
    }

    func testMixedActivitySheetUsesNativeRowsAndEmeraldTheme() async throws {
        let content = ExtensionRetainedContentPolicy.content(
            widgets: [
                ExtensionWidget(key: "goal", revision: 1, lines: ["Checking the selected files"],
                    placement: .belowEditor,
                    owner: ExtensionOwner(id: "goal", title: "Goal", source: "npm:@mocito/pi-goal")),
                ExtensionWidget(key: "subagents", revision: 1, lines: ["PI_SUBAGENT_ASYNC_JSON:hidden"],
                    placement: .belowEditor,
                    owner: ExtensionOwner(id: "subagent", title: "Pi Subagents", source: "npm:pi-subagents@0.59.0"))
            ], surfaces: [], statuses: ["goal": "Goal active"],
            statusOwners: ["goal": ExtensionOwner(id: "goal", title: "Goal", source: "npm:@mocito/pi-goal")]
        )
        XCTAssertEqual(content.entries.count, 2)
        for size: DynamicTypeSize in [.large, .accessibility3] {
            try await withSheet(SessionActivitySheet(
                sessionID: "fixture", extensionContent: content, omittedExtensionContentCount: 0,
                processActivities: [subagentProcessFixture(state: .running), subagentProcessFixture(state: .completed)]
            ).environment(\.dynamicTypeSize, size)) { controller in
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        guard controller.view.window != nil else { return false }
                        let layer = controller.view.layer
                        let painted = layer.presentation() ?? layer
                        return controller.view.bounds.height > 0
                            && abs(painted.bounds.height - layer.bounds.height) < 0.5
                            && abs(painted.position.y - layer.position.y) < 0.5
                    }
                }, object: nil)
                let settledResult = await XCTWaiter.fulfillment(of: [settled], timeout: 3)
                XCTAssertEqual(settledResult, .completed)
                let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                self.assertToolbarPaint(.tronEmerald, bar: bar, leading: false, controller: controller)
                let rows = self.accessibilityElements(in: controller.view).filter {
                    $0.accessibilityHint?.contains("read-only subagent session") == true
                }
                XCTAssertFalse(rows.isEmpty)
                let sheetFrame = controller.view.convert(controller.view.bounds, to: nil)
                for row in rows where row.accessibilityFrame.width > 0 {
                    XCTAssertGreaterThanOrEqual(row.accessibilityFrame.minX, sheetFrame.minX - 1)
                    XCTAssertLessThanOrEqual(row.accessibilityFrame.maxX, sheetFrame.maxX + 1)
                    XCTAssertTrue(row.accessibilityValue?.contains("Asynchronous") == true)
                }
                self.capture(controller, name: "unified-activity-typography-\(size)")
            }
        }
    }

    func testSubagentResultsUpdateInOpenActivitySheet() async throws {
        try await withModel { model in
            var snapshot = try SessionScenarioBuilder(seed: 8_931).openingTail(targetEncodedBytes: 4_096)
            snapshot.processActivities = [self.subagentProcessFixture(
                state: .running, processID: "live-worker", title: "worker", output: "Inspecting the source files."
            )]
            model.installHostedAuthoritativeSnapshot(snapshot)
            try await self.withSheet(LiveSubagentActivityFixture(sessionID: snapshot.sessionId).environment(model)) { controller in
                @MainActor func row() -> NSObject? {
                    self.accessibilityElements(in: controller.view).first(where: {
                        $0.accessibilityHint?.contains("read-only subagent session") == true
                    })
                }
                try await self.waitForRouting { row()?.accessibilityValue?.contains("Inspecting the source files.") == true }
                let initialRow = try XCTUnwrap(row(), "Expected the native accessible subagent row: \(self.accessibilityElements(in: controller.view).compactMap { $0.accessibilityLabel })")
                XCTAssertTrue(initialRow.accessibilityValue?.contains("LIVE OUTPUT") == true)
                let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                let offset = scroll.contentOffset
                self.capture(controller, name: "subagent-live-initial")

                snapshot.processActivities = [self.subagentProcessFixture(
                    state: .running, processID: "live-worker", title: "worker",
                    output: "Old output\nFirst check passed.\nSecond check passed.\nLatest check passed."
                )]
                model.installHostedAuthoritativeSnapshot(snapshot)
                try await self.waitForRouting { row()?.accessibilityValue?.contains("Latest check passed.") == true }
                XCTAssertFalse(row()?.accessibilityValue?.contains("Inspecting the source files.") == true)
                XCTAssertFalse(row()?.accessibilityValue?.contains("Old output") == true)
                XCTAssertTrue(row()?.accessibilityValue?.contains("First check passed.") == true)
                self.capture(controller, name: "subagent-live-updated")

                snapshot.processActivities = [self.subagentProcessFixture(
                    state: .completed, processID: "live-worker", title: "worker", output: "All focused checks passed."
                )]
                model.installHostedAuthoritativeSnapshot(snapshot)
                try await self.waitForRouting { row()?.accessibilityValue?.contains("RESULT: All focused checks passed.") == true }
                XCTAssertFalse(row()?.accessibilityValue?.contains("LIVE OUTPUT") == true)
                XCTAssertTrue(row()?.accessibilityValue?.contains("Completed") == true)
                XCTAssertTrue(self.views(of: UIScrollView.self, in: controller.view).contains { $0 === scroll })
                XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1,
                    "Publishing output must not replace the open sheet or move its scroll position")
                XCTAssertEqual(controller.sheetPresentationController?.selectedDetentIdentifier, .medium)
                self.capture(controller, name: "subagent-live-completed")
            }
        }
    }

    func testSubagentThemeRowsAndChildSheet() async throws {
        let processes = [
            subagentProcessFixture(state: .running),
            subagentProcessFixture(state: .completed),
            subagentProcessFixture(state: .failed),
        ]
        for scheme: ColorScheme in [.light, .dark] {
            try await withSheet(NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Active sheet · lifecycle colors").font(TronTypography.sheetSectionHeader)
                        ForEach(processes) { process in
                            SessionProcessRow(process: process, style: .activity) {}
                        }
                        Text("History · subagent theme").font(TronTypography.sheetSectionHeader)
                        ForEach(processes) { process in
                            SessionProcessRow(process: process, style: .history) {}
                        }
                    }
                    .padding(18)
                }
                .tronNavigationTitle("Subagent colors")
            }
            // Simulate the inherited Manage Session theme: it must not repaint rows.
            .tronSettingsVisualTheme(accent: .tronSessionTeal)
            .presentationDetents([.large], selection: .constant(.large))
            .preferredColorScheme(scheme)) { controller in
                self.capture(controller, name: "subagent-theme-\(scheme)")
            }
        }
        try await withModel { model in
            try await self.withSheet(ReadOnlySubagentSessionSheet(
                parentSessionID: "theme-fixture", process: processes[1]
            ).environment(model)) { controller in
                let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                self.assertToolbarPaint(.tronSubagent, bar: bar, leading: false, controller: controller)
            }
        }
    }

    func testNativeCopyMenuIsExplicitAndKeepsItsOpeningText() async throws {
        let text = "  Copy exactly\n👋 café  "
        let previousClipboard = UIPasteboard.general.items
        defer { UIPasteboard.general.items = previousClipboard }
        try await withSheet(UserPromptText(text: text).padding(16)
            .modifier(UserPromptGlassModifier()).modifier(ChatMessageCopyMenu(text: text))) { controller in
                let owner = try XCTUnwrap(self.views(of: UIView.self, in: controller.view).flatMap(\.interactions)
                    .compactMap { ($0 as? UIContextMenuInteraction)?.delegate as? ChatMessageContextMenuOwner }.first)
                let menu = try XCTUnwrap(owner.makeMenu())
                XCTAssertEqual(menu.children.map(\.title), ["Copy"])
                let copy = try XCTUnwrap(menu.children.first as? UIAction)
                owner.text = "Updated input must not replace an open menu"
                self.performMenuAction(copy)
                XCTAssertEqual(UIPasteboard.general.string, text)
                XCTAssertEqual(menu.children.count, 1)
                owner.text = ""
                XCTAssertNil(owner.makeMenu(), "An attachment-only bubble must not offer an empty menu")
            }
    }

    func testNativeMenuPreservesShortAndWrappedBubbleMeasurement() async throws {
        for text in ["Short prompt", String(repeating: "A wrapped prompt preserves native layout and spacing. ", count: 20)] {
            var sizes: [CGSize] = []
            for native in [false, true] {
                let bubble = UserPromptText(text: text)
                    .padding(.horizontal, ChatPromptContainerStyle.horizontalPadding)
                    .padding(.top, ChatPromptContainerStyle.topPadding)
                    .padding(.bottom, ChatPromptContainerStyle.userPromptBottomPadding)
                    .modifier(UserPromptGlassModifier())
                try await withSheet(ScrollView {
                    Group {
                        if native { bubble.modifier(ChatMessageCopyMenu(text: text)) }
                        else { bubble }
                    }.frame(width: 300)
                }) { controller in
                    let label = try XCTUnwrap(self.views(of: UILabel.self, in: controller.view).first { $0.text == text })
                    sizes.append(label.bounds.size)
                }
            }
            XCTAssertEqual(sizes[0].width, sizes[1].width, accuracy: 1)
            XCTAssertEqual(sizes[0].height, sizes[1].height, accuracy: 1)
        }
    }

    func testNativeQueueMenuRevalidatesActionsAndSourceIdentity() async throws {
        try await withSheet(Text("Queue menu lifecycle")) { controller in
            let owner = ChatMessageContextMenuOwner()
            let source = UIView()
            controller.view.addSubview(source)
            owner.attach(to: source)
            owner.mutationIdentity = "queue-a"
            var selected: [String] = []
            owner.actions = [.init(id: .moveEarlier, title: "Move earlier", icon: "arrow.up", perform: { selected.append("original") })]
            let menu = try XCTUnwrap(owner.makeMenu())
            let move = try XCTUnwrap(menu.children.first as? UIAction)
            owner.actions = []
            self.performMenuAction(move)
            XCTAssertTrue(selected.isEmpty, "Busy/read-only queues revoke actions already shown")
            owner.actions = [.init(id: .moveEarlier, title: "Move earlier", icon: "arrow.up", perform: { selected.append("current") })]
            self.performMenuAction(move)
            XCTAssertEqual(selected, ["current"], "Use the current admitted command, not a retained old callback")
            owner.mutationIdentity = "queue-b"
            self.performMenuAction(move)
            XCTAssertEqual(selected, ["current"])
            owner.mutationIdentity = "queue-a"
            source.removeFromSuperview()
            owner.retire()
            self.performMenuAction(move)
            XCTAssertEqual(selected, ["current"], "Retired sources cannot mutate a queue")
        }
    }

    private func performMenuAction(_ action: UIAction) {
        let control = UIControl()
        control.addAction(action, for: .touchUpInside)
        control.sendActions(for: .touchUpInside)
    }

    func testOutgoingAndQueuedCopyMenusRetainOneNativeOwner() async throws {
        let arguments = "  Copy this exact input\nnot the template. 👋  "
        let resource = ComposerResourceInvocation(source: .prompt, name: "review", arguments: arguments)
        for behavior: String? in [nil, "steer", "followUp"] {
            let submission = ComposerSubmissionSnapshot(target: .init(sessionID: "copy", generation: 1),
                textRevision: 1, outgoingText: "Expanded template", resourceInvocation: resource,
                attachmentIDs: [], behavior: behavior, localNonce: 1)
            try await withSheet(ChatOutgoingSubmissionRow(
                presentation: .init(snapshot: submission, transportActive: true), attachments: [])) { controller in
                let interactions = self.views(of: UIView.self, in: controller.view).flatMap(\.interactions)
                    .compactMap { $0 as? UIContextMenuInteraction }
                XCTAssertEqual(interactions.count, 1)
                XCTAssertTrue(self.views(of: UILabel.self, in: controller.view).contains { $0.text == arguments })
                try self.assertMessageMenuOpens(in: controller, text: arguments)
            }
        }
        let message = SessionSnapshot.QueuedMessage(id: "copy-queue", behavior: .steer,
            text: "Expanded template", attachmentCount: 0, resourceInvocation: resource)
        for availability: QueuedMessageManagementAvailability in [.available, .requiresGatewayUpdate, .invalidProjection] {
            for mutating in [false, true] {
                try await withSheet(QueuedMessageRow(message: message, position: 2, total: 3,
                    managementAvailability: availability, isMutating: mutating,
                    onEdit: { XCTFail("Long-press registration must not edit") },
                    onClear: { XCTFail("Long-press registration must not clear") },
                    canMoveEarlier: true, canMoveLater: true,
                    onMove: { _ in XCTFail("Long-press registration must not reorder") })) { controller in
                    let interactions = self.views(of: UIView.self, in: controller.view).flatMap(\.interactions)
                        .compactMap { $0 as? UIContextMenuInteraction }
                    XCTAssertEqual(interactions.count, 1, "Copy must join the queue menu, never shadow its management actions")
                    XCTAssertTrue(self.views(of: UILabel.self, in: controller.view).contains { $0.text == arguments })
                    try self.assertMessageMenuOpens(in: controller, text: arguments)
                }
            }
        }
    }

    func testPendingPromptCopyMenuUsesNativeInteractionAcrossCardStates() async throws {
        let arguments = "  Preserve whitespace\n\tand Unicode: café 👋  "
        for behavior: SessionSnapshot.QueuedMessage.Behavior? in [nil, .steer, .followUp] {
            let pending = SessionSnapshot.PendingPrompt(
                id: "copy-pending", createdAt: nil, behavior: behavior,
                text: "Expanded template must not be copied", attachmentCount: 0,
                resourceInvocation: .init(source: .prompt, name: "review", arguments: arguments)
            )
            try await withSheet(ChatPendingPromptRow(presentation: .init(snapshot: pending, isCompacting: false))) { controller in
                let interactions = self.views(of: UIView.self, in: controller.view).flatMap(\.interactions)
                    .compactMap { $0 as? UIContextMenuInteraction }
                XCTAssertEqual(interactions.count, 1, "One native menu belongs to the bounded message surface")
                let texts = self.views(of: UILabel.self, in: controller.view).compactMap(\.text)
                XCTAssertTrue(texts.contains(arguments))
                XCTAssertFalse(texts.contains(pending.text))
                try self.assertMessageMenuOpens(in: controller, text: arguments)
            }
        }
        let empty = SessionSnapshot.PendingPrompt(id: "copy-empty", createdAt: nil, behavior: nil,
            text: "Expanded template must not be copied", attachmentCount: 0,
            resourceInvocation: .init(source: .prompt, name: "review", arguments: ""))
        try await withSheet(ChatPendingPromptRow(presentation: .init(snapshot: empty, isCompacting: false))) { controller in
            let interactions = self.views(of: UIView.self, in: controller.view).flatMap(\.interactions)
                .compactMap { $0 as? UIContextMenuInteraction }
            XCTAssertTrue(interactions.isEmpty, "A chip-only prompt must retain the resource action, not an empty Copy menu")
        }
    }

    func testPromptTemplateRowCollapsesExpandedContentWithoutChangingInput() async throws {
        let expanded = String(repeating: "Review the implementation for correctness and preserve every important behavior.\n", count: 80)
        let content = ContentPart(id: "prompt-text", ordinal: 0, thinkingRunOrdinal: nil,
                                  type: .text, text: expanded, attachment: nil, redacted: nil,
                                  mimeType: nil, blobId: nil, toolCallId: nil, name: nil, arguments: nil)
        let resource = ComposerResourceInvocation(source: .prompt, name: "code_review", arguments: "Focus on cancellation and cleanup.")
        try await withModel { model in
            for bound in [true, false] {
                let item = TranscriptItem.message(MessageTranscriptItem(
                    id: "prompt-row", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                    kind: .message, role: .user, presentationId: "prompt-row", content: [content],
                    semantic: bound ? ChatSemanticMetadata(
                        direction: .inboundContext, contextEffect: .modelInput,
                        delivery: .stored, visibility: .visible, kind: .resourcePrompt,
                        origin: .init(kind: .user, confidence: .boundary), sequence: 1, resourceInvocation: resource
                    ) : nil
                ))
                try await self.withSheet(ScrollView {
                    TranscriptRow(item: item).padding(16)
                }.environment(model)) { controller in
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    if bound {
                        XCTAssertLessThan(scroll.contentSize.height, 300)
                        self.capture(controller, name: "prompt-template-chip-and-input")
                    } else {
                        // Identical text without resource provenance must stay
                        // readable; a blanket text truncation would fail here.
                        XCTAssertGreaterThan(scroll.contentSize.height, 500)
                    }
                    XCTAssertEqual(item.content, [content])
                    let interactions = self.views(of: UIView.self, in: controller.view).flatMap(\.interactions)
                        .compactMap { $0 as? UIContextMenuInteraction }
                    XCTAssertEqual(interactions.count, 1, "Canonical user text must expose one native Copy menu")
                    try self.assertMessageMenuOpens(in: controller, text: bound ? resource.arguments : expanded)
                }
            }
        }
    }

    func testComposerResourceDetailsKeepMetadataSecondaryAndMatchToolbarPaint() async throws {
        try await withModel { model in
            for (source, accent): (CommandInfo.Source, Color) in [(.skill, .tronCyan), (.prompt, .tronPurple), (.extension, .tronIndigo)] {
                let entry = try XCTUnwrap(ComposerResourceEntry(command: CommandInfo(
                    name: source == .skill ? "skill:review" : "review",
                    description: "Review the selected changes.", argumentHint: "Optional focus",
                    source: source, sourcePath: "/resources/review.md",
                    resourceSource: "project resources", resourceScope: .project, resourceOrigin: .topLevel
                )))
                try await self.withSheet(ComposerResourceDetailSheet(
                    sessionID: nil, entry: entry, accent: accent, prefix: source == .skill ? "@" : "/"
                ).environment(model)) { controller in
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(accent, bar: bar, leading: true, controller: controller)
                    self.assertToolbarPaint(accent, bar: bar, leading: false, controller: controller)
                    let scroll = try XCTUnwrap(self.views(of: UIScrollView.self, in: controller.view).first)
                    // With a short description and no fetched body, a main-sheet
                    // resource table would exceed this independently measured bound.
                    XCTAssertLessThan(scroll.contentSize.height, 250)
                    self.capture(controller, name: "resource-detail-\(source)")
                }
                let metadata = [
                    TronTechnicalMetadataItem(title: "Type", value: source.rawValue, icon: "sparkles"),
                    .init(title: "Invocation", value: source == .skill ? "@review" : "/review", icon: "terminal"),
                    .init(title: "Source file", value: "/resources/review.md", icon: "doc.text"),
                ]
                try await self.withSheet(ComposerResourceInfoSheet(items: metadata, accent: accent)) { controller in
                    XCTAssertEqual(controller.sheetPresentationController?.selectedDetentIdentifier, .medium)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(accent, bar: bar, leading: false, controller: controller)
                    self.capture(controller, name: "resource-info-\(source)")
                }
            }
        }
    }

    func testCompactToolResultAndQueueSheets() async throws {
        let tool = ChatToolPresentation(
            id: "preview-tool", title: "Web Search", subtitle: "Completed", request: nil,
            response: .object(["status": .number(200), "queries": .array([.string("one"), .string("two")]),
                               "includeContent": .bool(false), "resultCount": .number(18)]),
            content: "Found 18 results across two queries.", fallbackContent: nil, error: false,
            startedAt: nil, completedAt: nil, durationMs: 3300, lastProgressAt: nil, progressSequence: nil
        )
        try await withSheet(NavigationStack {
            ToolDetailSheet(tool: tool, density: .glance)
                .tronNavigationTitle("Web Search")
        }.presentationDetents([.medium, .large], selection: .constant(.medium))) { controller in
            XCTAssertEqual(controller.sheetPresentationController?.selectedDetentIdentifier, .medium)
            self.capture(controller, name: "compact-tool-result")
        }
        try await withSheet(QueuedMessageEditorSheet(
            message: .init(id: "queued", behavior: .steer, text: "Please check the current result.", attachmentCount: 0),
            isSaving: false, onSave: { _, _ in }, onDelete: {}
        )) { controller in
            let sheet = try XCTUnwrap(controller.sheetPresentationController)
            XCTAssertEqual(Set(sheet.detents.map(\.identifier)), [.medium, .large])
            self.capture(controller, name: "standard-queued-message")
        }
    }

    func testNestedTechnicalJSONKeepsChromeAboveItsReader() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            let state = NestedDocumentPresentation()
            try await withSheet(NestedDocumentFixture(presentation: state).preferredColorScheme(scheme)) { parent in
                state.isPresented = true
                let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated { parent.presentedViewController != nil }
                }, object: nil)
                let result = await XCTWaiter.fulfillment(of: [appeared], timeout: 2)
                XCTAssertEqual(result, .completed)
                let child = try XCTUnwrap(parent.presentedViewController)
                if let transition = child.transitionCoordinator {
                    await withCheckedContinuation { continuation in
                        if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                            continuation.resume()
                        }
                    }
                }
                child.view.layoutIfNeeded()
                let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: child.view).first)
                self.assertToolbarPaint(.tronPurple, bar: bar, leading: false, controller: child)
                let reader = try XCTUnwrap(self.views(of: TronDocumentTextView.self, in: child.view).first)
                let firstLine = reader.convert(reader.caretRect(for: reader.beginningOfDocument), to: child.view)
                let barFrame = bar.convert(bar.bounds, to: child.view)
                XCTAssertGreaterThanOrEqual(firstLine.minY, barFrame.maxY)
                XCTAssertLessThanOrEqual(firstLine.minY, barFrame.maxY + 30)
                self.capture(child, name: "nested-technical-json-\(scheme)")
            }
        }
    }

    func testTechnicalJSONChromeAndReaderAtBothDetents() async throws {
        for scheme: ColorScheme in [.light, .dark] {
            for editable in [false, true] {
                try await self.withSheet(TechnicalJSONSheet(
                    value: .object(["items": .array((0..<80).map { .string("Item \($0)") })]),
                    title: "Technical Details", accent: .tronSlate,
                    detent: .constant(.medium), onEdit: editable ? {} : nil
                ).tronSettingsVisualTheme(accent: .tronPurple).preferredColorScheme(scheme)) { controller in
                    let reader = try XCTUnwrap(self.views(of: TronDocumentTextView.self, in: controller.view).first)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        MainActor.assumeIsolated { reader.text?.contains("Item 79") == true }
                    }, object: nil)
                    let loaded = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
                    XCTAssertEqual(loaded, .completed)
                    for detent in [UISheetPresentationController.Detent.Identifier.medium, .large] {
                        controller.sheetPresentationController?.selectedDetentIdentifier = detent
                        controller.presentationController?.containerView?.layoutIfNeeded()
                        controller.view.layoutIfNeeded()
                        self.assertToolbarPaint(.tronPurple, bar: bar, leading: false, controller: controller)
                        if editable { self.assertToolbarPaint(.tronPurple, bar: bar, leading: true, controller: controller) }
                        let barFrame = bar.convert(bar.bounds, to: controller.view)
                        let firstLine = reader.convert(reader.caretRect(for: reader.beginningOfDocument), to: controller.view)
                        XCTAssertGreaterThanOrEqual(firstLine.minY, barFrame.maxY)
                        XCTAssertLessThanOrEqual(firstLine.minY, barFrame.maxY + 30)
                        XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                        for offset in [-18.0, -0.5, 0.5, 120] {
                            reader.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                            let nativeOffset = reader.contentOffset.y
                            reader.setNeedsLayout(); reader.layoutIfNeeded()
                            XCTAssertEqual(reader.contentOffset.y, nativeOffset, accuracy: 0.01)
                        }
                        reader.setContentOffset(.zero, animated: false)
                        self.capture(controller, name: "technical-json-\(scheme)-\(detent.rawValue)-edit-\(editable)")
                    }
                }
            }
            try await withModel { model in
                try await self.withSheet(CustomModelAdvancedEditorSheet(
                    document: .constant(String(repeating: "{ \"name\": \"value\" }\n", count: 60)),
                    target: .global, onDone: {}
                ).environment(model).tronSettingsVisualTheme(accent: .tronPurple).preferredColorScheme(scheme)) { controller in
                    let reader = try XCTUnwrap(self.views(of: UITextView.self, in: controller.view).first)
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    XCTAssertTrue(reader.isEditable)
                    for detent in [UISheetPresentationController.Detent.Identifier.medium, .large] {
                        controller.sheetPresentationController?.selectedDetentIdentifier = detent
                        controller.presentationController?.containerView?.layoutIfNeeded()
                        controller.view.layoutIfNeeded()
                        self.assertToolbarPaint(.tronPurple, bar: bar, leading: false, controller: controller)
                        let frame = reader.convert(reader.bounds, to: controller.view)
                        let barFrame = bar.convert(bar.bounds, to: controller.view)
                        XCTAssertGreaterThanOrEqual(frame.minY, barFrame.maxY)
                        XCTAssertLessThanOrEqual(frame.minY, barFrame.maxY + 36)
                        reader.setContentOffset(CGPoint(x: 0, y: 100), animated: false)
                        let nativeOffset = reader.contentOffset.y
                        reader.setNeedsLayout(); reader.layoutIfNeeded()
                        XCTAssertEqual(reader.contentOffset.y, nativeOffset, accuracy: 0.01)
                        reader.setContentOffset(.zero, animated: false)
                        self.capture(controller, name: "advanced-json-editor-\(scheme)-\(detent.rawValue)")
                    }
                }
            }
        }
    }

    func testNestedJSONFieldSheetsKeepFieldTitlesAboveSingleBlur() async throws {
        let root: JSONValue = .object(["mission": .object([
            "status": .string("active"), "details": .object(["count": .number(2)])
        ])])
        for selection in [
            JSONFieldSelection(title: "Mission", components: [.key("mission")]),
            JSONFieldSelection(title: "Details", components: [.key("mission"), .key("details")])
        ] {
            for scheme in [ColorScheme.light, .dark] {
                try await withSheet(JSONFieldSheet(selection: selection, rootValue: root, accent: .tronEmerald)
                    .preferredColorScheme(scheme)) { controller in
                    let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
                    self.assertToolbarPaint(.tronEmerald, bar: bar, leading: false, controller: controller)
                    XCTAssertEqual(self.views(of: VariableBackdropBlurView.self, in: controller.view).count, 1)
                    self.capture(controller, name: "json-field-\(selection.title)-\(scheme)")
                }
            }
        }
    }

    func testTechnicalJSONRetainsReadingPositionAcrossActivityChanges() async throws {
        let state = JSONReaderContinuityState()
        try await withSheet(JSONReaderContinuityFixture(state: state)) { controller in
            let reader = try XCTUnwrap(self.views(of: TronDocumentTextView.self, in: controller.view).first)
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { reader.text.contains("last-original-item") }
            }, object: nil)
            let result = await XCTWaiter.fulfillment(of: [loaded], timeout: 2)
            XCTAssertEqual(result, .completed)
            reader.selectedRange = NSRange(location: 40, length: 8)
            reader.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
            let offset = reader.contentOffset
            let selection = reader.selectedRange
            state.activity = .covered
            try await Task.sleep(for: .milliseconds(80))
            state.activity = .active
            try await Task.sleep(for: .milliseconds(120))
            XCTAssertTrue(self.views(of: TronDocumentTextView.self, in: controller.view).first === reader)
            XCTAssertEqual(reader.selectedRange, selection)
            XCTAssertEqual(reader.contentOffset.y, offset.y, accuracy: 0.01)
            XCTAssertTrue(reader.text.contains("last-original-item"))
            state.value = .object(["replacement": .string("new-source-content")])
            let replaced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated { reader.text.contains("new-source-content") }
            }, object: nil)
            let replacement = await XCTWaiter.fulfillment(of: [replaced], timeout: 2)
            XCTAssertEqual(replacement, .completed)
            XCTAssertFalse(reader.text.contains("last-original-item"))
        }
    }

    func testAdvancedJSONActionsMatchInheritedPurpleTheme() async throws {
        try await withSheet(TechnicalJSONSheet(
            value: .object(["providers": .object([:])]), title: "Advanced JSON", accent: .tronSlate,
            detent: .constant(.medium), onEdit: {}
        ).tronSettingsVisualTheme(accent: .tronPurple)) { controller in
            let bar = try XCTUnwrap(self.views(of: UINavigationBar.self, in: controller.view).first)
            self.assertToolbarPaint(.tronPurple, bar: bar, leading: true, controller: controller)
            self.assertToolbarPaint(.tronPurple, bar: bar, leading: false, controller: controller)
            self.capture(controller, name: "advanced-json-themed-actions")
        }
    }

    private func capture(_ controller: UIViewController, name: String) {
        guard let window = controller.view.window else { return XCTFail("Capture requires a mounted sheet") }
        let origin = controller.view.convert(controller.view.bounds, to: window).origin
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in
            context.cgContext.translateBy(x: -origin.x, y: -origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// SwiftUI paints these symbols without public UIButton/customView nodes.
    /// In this short-title fixture each outer quarter contains only its action;
    /// sample actual paint there rather than the bar's inherited UIKit tint.
    private func assertToolbarPaint(_ accent: Color, bar: UINavigationBar, leading: Bool, controller: UIViewController) {
        let regionWidth = bar.bounds.width / 4
        let region = CGRect(x: leading ? 0 : bar.bounds.width - regionWidth, y: 0, width: regionWidth, height: bar.bounds.height)
        let frame = bar.convert(region, to: controller.view)
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        guard let crop = image.cgImage?.cropping(to: CGRect(
            x: frame.minX * image.scale, y: frame.minY * image.scale,
            width: frame.width * image.scale, height: frame.height * image.scale
        )) else { return XCTFail("Toolbar control must have a rendered frame") }
        let width: Int = crop.width, height: Int = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).resolvedColor(with: controller.traitCollection).getRed(&r, green: &g, blue: &b, alpha: &a)
        var matches = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = abs(CGFloat(pixels[index]) / 255 - r)
            let green = abs(CGFloat(pixels[index + 1]) / 255 - g)
            let blue = abs(CGFloat(pixels[index + 2]) / 255 - b)
            if red < 0.05, green < 0.05, blue < 0.05, pixels[index + 3] > 230 { matches += 1 }
        }
        XCTAssertGreaterThan(matches, 3, "Toolbar symbol must match its resource title color")
    }

    private func withModel(client: GatewayClient = GatewayClient(), _ body: (AppModel) async throws -> Void) async throws {
        let suiteName = "session-sheet-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: cacheURL))
        try await body(model)
    }

    private func withSheet<Sheet: View>(_ sheet: Sheet, inspect: (UIViewController) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Sheet appeared")
        let host = UIHostingController(rootView: SheetFixture(content: sheet.onAppear { appeared.fulfill() }))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let appearance = await XCTWaiter.fulfillment(of: [appeared], timeout: 3)
        XCTAssertEqual(appearance, .completed)
        let presented = try XCTUnwrap(host.presentedViewController)
        if let transition = presented.transitionCoordinator {
            let completed = expectation(description: "Sheet transition completed")
            if transition.animate(alongsideTransition: nil, completion: { _ in completed.fulfill() }) {
                let result = await XCTWaiter.fulfillment(of: [completed], timeout: 3)
                XCTAssertEqual(result, .completed)
            }
        }
        presented.view.layoutIfNeeded()
        // Always finish UIKit dismissal, even if the inspection throws.
        var failure: Error?
        do { try await inspect(presented) } catch { failure = error }
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        if let failure { throw failure }
    }

    private func assertMessageMenuOpens(in controller: UIViewController, text: String) throws {
        let interaction = try XCTUnwrap(views(of: UIView.self, in: controller.view).flatMap(\.interactions)
            .compactMap { $0 as? UIContextMenuInteraction }.first)
        let owner = try XCTUnwrap(interaction.view)
        let label = try XCTUnwrap(views(of: UILabel.self, in: controller.view).first { $0.text == text })
        // UIKit asks the delegate in the interaction owner's coordinate space,
        // which can be a shared hosting view rather than the bubble itself.
        let point = label.convert(CGPoint(x: label.bounds.midX, y: min(label.bounds.midY, 10)), to: owner)
        XCTAssertTrue(owner.isUserInteractionEnabled)
        let hit = controller.view.hitTest(owner.convert(point, to: controller.view), with: nil)
        XCTAssertTrue(hit === owner || hit?.isDescendant(of: owner) == true,
                      "Menu owner: \(owner); actual hit: \(String(describing: hit))")
        XCTAssertNotNil(interaction.delegate?.contextMenuInteraction(interaction, configurationForMenuAtLocation: point),
                        "Registration alone is insufficient: pressing the visible text must produce a native menu")
    }

    private func accessibilityElements(in view: UIView) -> [NSObject] {
        var pending: [NSObject] = [view]
        var seen = Set<ObjectIdentifier>()
        var result: [NSObject] = []
        while let element = pending.popLast() {
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            pending += element.accessibilityElements?.compactMap { $0 as? NSObject } ?? []
            let count = element.accessibilityElementCount()
            if count > 0, count < 1_000 {
                pending += (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
            }
            if let view = element as? UIView { pending += view.subviews }
        }
        return result
    }

    private func views<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }

    /// Some sheets mount their content only after a bounded asynchronous
    /// preparation. Waiting for the native view is stronger than assuming one
    /// runloop turn is enough.
    private func waitForFirstView<T: UIView>(
        of type: T.Type,
        in root: UIView,
        timeout: TimeInterval = 5
    ) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            if let match = views(of: type, in: root).first { return match }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Lets SwiftUI run its update pass after an observable/environment change.
    private func settleSheetPresentation() async {
        for _ in 0..<4 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
        }
    }
}

@MainActor @Observable
private final class DocumentSurfaceActivity {
    var value: PresentationSurfaceActivity = .active
}

private struct InlinePhotoResumeFixture: View {
    @MainActor @Observable final class State {
        var ready: Bool
        var active: Bool
        init(ready: Bool, active: Bool) { self.ready = ready; self.active = active }
    }
    let tool: ChatToolDescriptor
    let state: State
    var body: some View {
        DisplayToolView(tool: tool, onOpenTechnicalDetails: {})
            .environment(\.displayTranscriptReady, state.ready)
            .environment(\.tronPresentationActivity, state.active ? .active : .covered)
            .environment(\.canonicalResourceSessionID, "photo-fixture")
    }
}

private struct LiveSubagentActivityFixture: View {
    let sessionID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        SessionActivitySheet(
            sessionID: sessionID,
            extensionContent: ExtensionRetainedContent(entries: []),
            omittedExtensionContentCount: 0,
            processActivities: model.sessionProcessPresentation(for: sessionID)?.activities ?? []
        )
    }
}

private struct SheetFixture<Content: View>: View {
    let content: Content
    @State private var presented = true

    var body: some View {
        Color.tronBackground.sheet(isPresented: $presented) { content }
    }
}

@MainActor @Observable
private final class JSONReaderContinuityState {
    var activity: PresentationSurfaceActivity = .active
    var value: JSONValue = .object(["items": .array(
        (0..<200).map { .string("Original item \($0)") } + [.string("last-original-item")]
    )])
}

private struct JSONReaderContinuityFixture: View {
    let state: JSONReaderContinuityState
    var body: some View {
        TechnicalJSONSheet(value: state.value, title: "Technical Details", accent: .tronSlate,
                           detent: .constant(.medium), onEdit: nil)
            .environment(\.tronPresentationActivity, state.activity)
    }
}

@MainActor @Observable
private final class WorkspaceRefreshActivity {
    var value: PresentationSurfaceActivity = .active
}

private struct HistoryPagingFixture: View {
    let model: AppModel
    let sessionID: String
    let probe: SessionHistoryPagingProbe
    let activity: WorkspaceRefreshActivity
    var body: some View {
        SessionTreeSheet(sessionID: sessionID, onForkCreated: { _ in }, onNavigated: {})
            .environment(model)
            .environment(\.sessionHistoryPagingProbe, probe)
            .environment(\.tronPresentationActivity, activity.value)
    }
}

private struct WorkspaceRefreshFixture: View {
    let model: AppModel
    let sessionID: String
    let activity: WorkspaceRefreshActivity
    let probe: SessionWorkspaceRefreshProbe
    var body: some View {
        SessionContextSheet(sessionID: sessionID, onForkCreated: { _ in })
            .environment(model)
            .environment(\.tronPresentationActivity, activity.value)
            .environment(\.sessionWorkspaceRefreshProbe, probe)
    }
}

@MainActor @Observable
private final class NestedDocumentPresentation {
    var isPresented = false
}

private struct NestedDocumentFixture: View {
    @Bindable var presentation: NestedDocumentPresentation
    var body: some View {
        NavigationStack {
            Text("Resource details").navigationTitle("Resources")
                .sheet(isPresented: $presentation.isPresented) {
                    TechnicalJSONSheet(value: .object(["status": .string("ready")]),
                                       title: "Technical Details", accent: .tronSlate,
                                       detent: .constant(.medium), onEdit: nil)
                        .tronSettingsVisualTheme(accent: .tronPurple)
                }
        }
    }
}
