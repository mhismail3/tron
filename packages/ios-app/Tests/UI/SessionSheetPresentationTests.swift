import SwiftUI
import Observation
import UIKit
import XCTest
import WebKit
@testable import TronMobile

@MainActor
final class SessionSheetPresentationTests: XCTestCase {

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

    func testCompletedSubagentTranscriptOpensWithVisibleContentWithoutScrolling() async throws {
        let paragraph = "The worker inspected the selected files and verified the focused checks. "
        let longTranscript = (0..<16).map { index in
            "## Inspection \(index + 1)\n\n" + String(repeating: paragraph, count: index % 4 + 1)
        } + ["## Completed\n\n" + String(repeating: paragraph + "\n\n", count: 20) + "Final result is ready."]
        for texts in [[], ["The worker completed the requested review."], longTranscript] {
            let gateway = ProcessSheetGatewayFixture()
            try await withModel(client: gateway.client) { model in
                try await gateway.connect(model: model, capabilities: [SessionProcessAdmissionPolicy.transcriptCapability])
                let snapshot = try SessionScenarioBuilder(seed: 8_920).openingTail(targetEncodedBytes: 4_096)
                model.installHostedSubscribedSnapshot(snapshot)
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

    private func assertSubagentOpeningOffset(_ scroll: UIScrollView, isLong: Bool) {
        let top = -scroll.adjustedContentInset.top
        let tail = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
        XCTAssertEqual(scroll.contentOffset.y, isLong ? tail : top, accuracy: 2,
            "Initial and resized sheets must show the tail (or top-aligned short content), never an empty lazy-layout gap")
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
