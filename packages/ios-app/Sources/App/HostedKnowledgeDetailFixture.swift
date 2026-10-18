#if HOSTED_TEST
import CryptoKit
import SwiftUI
import TronMobileCore

/// Hosted journey for Entry Detail's background work and autosave. It mounts the
/// real `KnowledgeDetailSheet` against a scripted in-app Gateway whose summary,
/// take and tag work stays pending until the journey completes or fails it
/// through the fixture bar, so every transient state is the production state
/// machine rather than injected view state. Events use the Gateway's exact job
/// shape, and a dropped connection exercises the real reconnect owner.
struct HostedKnowledgeDetailFixtureView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentedOrigin: KnowledgePresentationIdentity?
    @State private var presentedRow: KnowledgeSourceRow?
    private let completesSummaryInBackground: Bool
    private let scenario: String
    private let profile = GatewayProfile(id: "knowledge-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-knowledge")
    private let replacement = GatewayProfile(id: "knowledge-replacement", label: "Replacement fixture", host: "replacement.example.test", port: 9847, machineId: "fixture-knowledge-replacement")
    @State private var model: AppModel
    @State private var gateway: HostedKnowledgeGateway
    @State private var ready = false
    @State private var error: String?
    @State private var detailMounted = true
    @State private var detailGeneration = 0
    @State private var counters = "summarize:0 take:0 tag:0"
    @State private var typedChunks = 0
    @State private var presentationActivity = PresentationActivityCoordinator()

    init() {
        let scenario = ProcessInfo.processInfo.arguments.drop(while: { $0 != "-knowledge-detail-scenario" }).dropFirst().first ?? "default"
        self.scenario = scenario
        completesSummaryInBackground = scenario == "summary-background"
        let gateway = HostedKnowledgeGateway(scenario: scenario)
        let replacementGateway = HostedKnowledgeGateway(scenario: "default")
        let client = GatewayClient(socketFactory: GatewaySocketFactory { request in
            let replacesAuthority = request.url?.host == "replacement.example.test"
            return HostedKnowledgeSocket(gateway: replacesAuthority ? replacementGateway : gateway,
                                         replacement: replacesAuthority)
        })
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        if scenario == "take-failure-held" {
            try! profiles.save(replacement, token: "fixture-replacement-token", selecting: false)
        }
        _gateway = State(initialValue: gateway)
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-knowledge-detail-fixture"))))
    }

    var body: some View {
        TronPresentationSurface(id: "hosted-knowledge-detail-fixture") {
            if ProcessInfo.processInfo.arguments.contains("forget-confirmation") {
                VStack {
                    Text("Entry Detail closed")
                    if !detailMounted { fixtureBar }
                }
                .tronManagedSheet(isPresented: $detailMounted, identity: "fixture.knowledge-detail") {
                    fixturePanel
                }
            } else {
                fixturePanel
            }
        }
        .environment(model)
        .environment(\.tronPresentationActivityCoordinator, presentationActivity)
        .tronPresentation()
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.enteredBackground()
                if completesSummaryInBackground { Task { await gateway.completeSummary() } }
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                presentedOrigin = model.knowledgePresentationIdentity
                ready = true
            } catch { self.error = error.localizedDescription }
        }
        .task {
            for await value in gateway.counterUpdates() { counters = value }
        }
    }

    private var fixturePanel: some View {
        VStack(spacing: 0) {
            if ready {
                if scenario.hasPrefix("dashboard-") {
                    if detailMounted {
                        KnowledgeDashboardView(onSelectDashboard: { _ in }, onOpenAutomations: {}, onOpenSettings: {},
                                               onOpenDraft: { _ in }, onOpenSession: { _, _ in })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Knowledge dashboard closed").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if detailMounted {
                    KnowledgeDetailSheet(subject: .row(presentedRow ?? gateway.initialRow), origin: presentedOrigin ?? model.knowledgePresentationIdentity,
                                         onChanged: {}, onOpenDraft: { _ in }, onOpenSession: { _, _ in })
                        .id(detailGeneration)
                } else {
                    Text("Entry Detail closed").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error {
                Text(error)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            fixtureBar
        }
}

    /// Inserts text through UIKit's text-input path (the same delegate
    /// callbacks typing produces) without the simulator keyboard, whose inline
    /// predictions otherwise commit extra words behind a journey's back.
    @MainActor private static func insertIntoTake(_ text: String) {
        func textViews(_ view: UIView) -> [UITextView] { ((view as? UITextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews) }
        guard let field = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).flatMap(textViews).first(where: { $0.accessibilityLabel == "Your take" || $0.isEditable }) else { return }
        field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
        field.insertText(text)
    }

    private var fixtureBar: some View {
        VStack(spacing: 4) {
            Text(counters.components(separatedBy: " | trace ").first ?? counters).font(.caption2.monospaced())
                .lineLimit(2).frame(height: 28)
                .accessibilityValue(counters).accessibilityIdentifier("fixture.counters")
            Text("\(model.connectionState) · socket:\(model.knowledgePresentationIdentity.connectionID.map(String.init) ?? "none") · generation:\(model.knowledgeDestinationIdentity.lifecycleGeneration) · profile:\(model.profiles.selected?.id ?? "none")")
                .font(.caption2).lineLimit(2).frame(height: 32)
                .accessibilityValue("phase:\(scenePhase) invalidation:\(model.knowledgeInvalidationRevision) jobs:\(model.knowledgeCurationJobRevision)")
                .accessibilityIdentifier("fixture.connection")
            HStack(spacing: 4) {
                control("Close", id: "fixture.close-detail") { detailMounted = false }
                control("Open", id: "fixture.open-detail") {
                    if scenario.hasPrefix("dashboard-") { detailMounted = true; return }
                    Task { @MainActor in
                        let identity = model.knowledgePresentationIdentity
                        // Reopening from the actual catalog uses its current
                        // revision, not the fixture's initial selected row.
                        let page = try await model.knowledge.sourceRows(ids: [gateway.initialRow.id])
                        guard model.knowledgePresentationIdentity == identity,
                              let row = page.rows.first else { return }
                        presentedRow = row
                        presentedOrigin = identity
                        detailGeneration += 1
                        detailMounted = true
                    }
                }
                control("Drop", id: "fixture.drop-connection") { Task { await gateway.dropConnection() } }
                control("Hold rows", id: "fixture.hold-rows") { Task { await gateway.holdRowsAndInvalidate() } }
                if scenario.hasPrefix("dashboard-") {
                    if ["dashboard-full-refresh", "dashboard-held-pagination", "dashboard-cover-reveal", "dashboard-cache-race", "dashboard-overlap-intent", "dashboard-search-refresh", "dashboard-records-refresh", "dashboard-initial-records"].contains(scenario) {
                        control("Commit dashboard change", id: "fixture.commit-dashboard-full-refresh") { Task { await gateway.commitDashboardChange() } }
                    }
                    if scenario == "dashboard-held-pagination" {
                        control("Hold initial continuation", id: "fixture.hold-dashboard-continuation") { Task { await gateway.holdDashboardCursor("dashboard-initial-p2") } }
                    }
                    if scenario == "dashboard-cover-reveal" {
                        control("Hold next dashboard head", id: "fixture.hold-dashboard-head") { Task { await gateway.holdNextDashboardHead() } }
                    }
                    if scenario == "dashboard-cache-race" {
                        control("Hold next dashboard head", id: "fixture.hold-dashboard-head") { Task { await gateway.holdNextDashboardHead() } }
                    }
                    if scenario == "dashboard-overlap-intent" {
                        control("Hold retained row read", id: "fixture.hold-dashboard-tail") { Task { await gateway.holdDashboardTail() } }
                    }
                    control("Release dashboard read", id: "fixture.release-dashboard-read") { Task { await gateway.releaseDashboardRead() } }
                    if ["dashboard-cache-race", "dashboard-overlap-intent"].contains(scenario) {
                        control("Inspect reads", id: "fixture.inspect-dashboard-reads") { Task { await gateway.inspectDashboardReads() } }
                    }
                }
                control("New tags", id: "fixture.newer-tags") { Task { await gateway.publishNewerTags() } }
                control("Release", id: "fixture.release-rows") { Task { await gateway.releaseRows() } }
            }
            HStack(spacing: 4) {
                control("Sum ✓", id: "fixture.complete-summary") { Task { await gateway.completeSummary() } }
                control("Sum ✗", id: "fixture.fail-summary") { Task { await gateway.failSummary() } }
                control("Tags ✓", id: "fixture.complete-tags") { Task { await gateway.completeTags() } }
                control("Tags ✗", id: "fixture.fail-tags") { Task { await gateway.failTags() } }
                control("Ack", id: "fixture.release-summary-start") { Task { await gateway.releaseSummaryStart() } }
                control("Replace Mac", id: "fixture.replace-profile") { Task { await model.switchGateway(replacement) } }
            }
            HStack(spacing: 4) {
                control("Take conflict", id: "fixture.next-take-conflict") { Task { await gateway.setNextTake(.conflict) } }
                control("Take fail", id: "fixture.next-take-failure") { Task { await gateway.setNextTake(.failure) } }
                control("Curate conflict", id: "fixture.next-curation-conflict") { Task { await gateway.setNextCurationConflict() } }
                control("Type", id: "fixture.type-take") { typedChunks += 1; Self.insertIntoTake("chunk\(typedChunks) ") }
                control("Take reply", id: "fixture.release-take") { Task { await gateway.releaseTakeReply() } }
                control("Latest take ✓", id: "fixture.complete-latest-take") { Task { await gateway.completeLatestTake() } }
            }
        }
        .padding(6)
        .background(Color.black)
    }

    private func control(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption2)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }
}

/// Shared scripted Gateway state; each reconnect gets a new socket over it.
actor HostedKnowledgeGateway {
    enum TakeMode { case success, conflict, failure }
    private static let sourceID = "entry-loss-functions"
    private static let replacementID = "entry-harness-revised"
    private static let dashboardAID = "fixture-dashboard-a"
    private static let dashboardBID = "fixture-dashboard-b"
    private static let dashboardCID = "fixture-dashboard-c"
    private static let dashboardDID = "fixture-dashboard-d"
    private var dashboardATitle = "1284 Fixture A"
    private var dashboardBTitle = "1284 Fixture B"
    private var dashboardDTitle = "1284 Fixture D"
    private var dashboardTitles: [String: String] = [:]
    private var dashboardScopes: [String: String] = [:]
    private static let title = "Loss functions for agent loops"
    private static let text = "How to turn a product goal into an explicit loss function an agent can optimize against."

    nonisolated let initialRow: KnowledgeSourceRow
    private let scenario: String
    private var revision = 1
    private var stateRevision = 10
    private var summary: String?
    private var take: String?
    private var tagIDs: [String] = ["workflows"]
    private var verdict: String?
    private var supersededBy: String?
    private var scope = "research"
    private var admission = "retained"
    private var jobs: [JSONValue] = []
    private var pendingSummary: String?
    private var pendingTags: String?
    private var nextTake = TakeMode.success
    private var heldTakeReplies: [(number: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var successfulTakeReplies = Set<Int>()
    private var takeSucceededCount = 0
    private var takeCommands = Set<String>()
    private var takeHeldCount = 0
    private var takeReleasedCount = 0
    private var latestTakeWasSubmitted = false
    func releaseTakeReply() {
        guard !heldTakeReplies.isEmpty else { return }
        heldTakeReplies.removeFirst().continuation.resume()
    }
    func completeLatestTake() {
        guard let reply = heldTakeReplies.popLast() else { return }
        successfulTakeReplies.insert(reply.number)
        reply.continuation.resume()
    }
    private var nextCurationConflict = false
    private var timeline: [String] = []
    func trace(_ value: String) {
        timeline.append(value)
        if timeline.count > 32 { timeline.removeFirst() }
        publishCounters()
    }
    private var holdNextRows = false
    private var heldRows: CheckedContinuation<Void, Never>?
    private var rowsHeld = 0
    private var rowsReleased = 0
    func holdRowsAndInvalidate() async { holdNextRows = true; await publishChange() }
    func publishNewerTags() async { tagIDs = ["evaluation"]; revision += 1; await publishChange() }
    func releaseRows() { heldRows?.resume(); heldRows = nil }
    private var correctionCount = 0
    private var jobsReadCount = 0
    private var summaryStartReceipts: [String: JSONValue] = [:]
    private var summaryStartReplies: [CheckedContinuation<Void, Never>] = []
    private var summaryStartReleased = false
    private var summaryStartAckCount = 0
    func releaseSummaryStart() {
        summaryStartReleased = true
        let replies = summaryStartReplies; summaryStartReplies.removeAll()
        replies.forEach { $0.resume() }
    }
    private func waitForSummaryStartRelease() async {
        guard !summaryStartReleased else { return }
        await withCheckedContinuation { summaryStartReplies.append($0) }
    }
    private var forgetCount = 0
    private var dashboardRows: [String] = []
    private var dashboardCommitCount = 0
    private var dashboardReadCount = 0
    private var dashboardEventCount = 0
    private var dashboardEventIDShape = "none"
    private var dashboardResponseIDs = ""
    private var dashboardResponseRevision = 0
    private var dashboardHeadResponseIDs = ""
    private var dashboardHeadResponseRevision = 0
    private var dashboardExactReadIDs = ""
    private var dashboardExactReadCount = 0
    private var dashboardHeadsWhileHeld = 0
    private var dashboardReadInspection = 0
    private var dashboardChronicleReply: CheckedContinuation<Void, Never>?
    private var dashboardSearchCount = 0
    private var dashboardSearchResponseIDs = ""
    private var dashboardSearchResponseRevision = 0
    private var dashboardRecordReadCount = 0
    private var dashboardRecordReadIDs = ""
    private var dashboardRecordReadRevision = 0
    private var dashboardHeldSnapshotIDs = ""
    private var dashboardHeldSnapshotRevision = 0
    private var dashboardHoldNextHead = false
    private var dashboardHoldCursor: String?
    private var dashboardHoldIDs: Set<String>?
    private struct HeldDashboardReply {
        let descriptor: String
        let continuation: CheckedContinuation<Void, Never>
    }
    private var heldDashboardReplies: [HeldDashboardReply] = []
    private var dashboardRowsHeld = 0
    private var dashboardRowsReleased = 0
    private var dashboardHeadReadCount = 0
    private var dashboardRequestDescriptors: [String] = []
    private var summaryDoneCount = 0
    private var summarizeCount = 0
    private var takeCount = 0
    private var tagCount = 0
    private var sockets: [HostedKnowledgeSocket] = []
    private var counterContinuations: [AsyncStream<String>.Continuation] = []

    init(scenario: String) {
        self.scenario = scenario
        if scenario == "superseded" {
            summary = "A worked playbook for distilling an app with explicit loss functions."
            verdict = "superseded"; supersededBy = Self.replacementID
            take = "Replaced by the revised harness post."
        }
        if scenario == "personal" { scope = "personal"; take = "Just fun." }
        if ["dashboard-full-refresh", "dashboard-cover-reveal", "dashboard-cache-race", "dashboard-overlap-intent", "dashboard-search-refresh", "dashboard-records-refresh", "dashboard-initial-records"].contains(scenario) {
            dashboardRows = [Self.dashboardAID, Self.dashboardBID]
        }
        if ["dashboard-cache-race", "dashboard-overlap-intent"].contains(scenario) { dashboardRows.append(Self.dashboardCID) }
        if scenario == "dashboard-held-pagination" { dashboardRows = [Self.dashboardAID, Self.dashboardBID, Self.dashboardCID, Self.dashboardDID] }
        if scenario == "dashboard-pagination-control" { dashboardRows = [Self.dashboardAID, Self.dashboardBID, Self.dashboardCID, Self.dashboardDID] }
        initialRow = try! JSONDecoder.gateway.decode(KnowledgeSourceRow.self, from: JSONEncoder.gateway.encode(Self.row(
            id: Self.sourceID, revision: 1, title: Self.title, scope: scope, verdict: verdict, supersededBy: supersededBy,
            hasTake: take != nil, tags: ["workflows"], summary: summary)))
    }

    nonisolated func counterUpdates() -> AsyncStream<String> {
        AsyncStream { continuation in Task { await self.addCounterContinuation(continuation) } }
    }
    private func addCounterContinuation(_ continuation: AsyncStream<String>.Continuation) {
        counterContinuations.append(continuation); publishCounters()
    }
    private func publishCounters() {
        let value = "forget:\(forgetCount) dashboardCommit:\(dashboardCommitCount) dashboardStateRevision:\(stateRevision) dashboardReads:\(dashboardReadCount) dashboardEvents:\(dashboardEventCount) dashboardEventIDShape:\(dashboardEventIDShape) dashboardResponseIDs:\(dashboardResponseIDs) dashboardResponseRevision:\(dashboardResponseRevision) dashboardHeadResponseIDs:\(dashboardHeadResponseIDs) dashboardHeadResponseRevision:\(dashboardHeadResponseRevision) dashboardExactReadIDs:\(dashboardExactReadIDs) dashboardExactReads:\(dashboardExactReadCount) dashboardHeadsWhileHeld:\(dashboardHeadsWhileHeld) dashboardInspection:\(dashboardReadInspection) dashboardSearches:\(dashboardSearchCount) dashboardSearchResponseIDs:\(dashboardSearchResponseIDs) dashboardSearchRevision:\(dashboardSearchResponseRevision) dashboardRecordReads:\(dashboardRecordReadCount) dashboardRecordReadIDs:\(dashboardRecordReadIDs) dashboardRecordReadRevision:\(dashboardRecordReadRevision) dashboardHeld:\(dashboardRowsHeld) dashboardReleased:\(dashboardRowsReleased) dashboardHeldSnapshotIDs:\(dashboardHeldSnapshotIDs) dashboardHeldSnapshotRevision:\(dashboardHeldSnapshotRevision) dashboardHeadReads:\(dashboardHeadReadCount) dashboardRequests:\(dashboardRequestDescriptors.suffix(20).joined(separator: ";")) summarize:\(summarizeCount) take:\(takeCount) tag:\(tagCount) jobs:\(jobsReadCount) correction:\(correctionCount) held:\(rowsHeld) released:\(rowsReleased) summaryDone:\(summaryDoneCount) startAck:\(summaryStartAckCount) takeHeld:\(takeHeldCount) takeReleased:\(takeReleasedCount) takeSucceeded:\(takeSucceededCount) takeCommands:\(takeCommands.count) latestTake:\(latestTakeWasSubmitted)"
        counterContinuations.forEach { $0.yield(value + " | trace " + timeline.joined(separator: ";")) }
    }

    func attach(_ socket: HostedKnowledgeSocket) { sockets.append(socket) }
    func dropConnection() async {
        let current = sockets; sockets.removeAll()
        for socket in current { await socket.drop() }
    }
    func setNextTake(_ mode: TakeMode) { nextTake = mode }
    func setNextCurationConflict() { nextCurationConflict = true }
    func holdNextDashboardHead() { dashboardHoldNextHead = true; publishCounters() }
    func holdDashboardCursor(_ cursor: String) { dashboardHoldCursor = cursor; publishCounters() }
    func holdDashboardTail() { dashboardHoldIDs = [Self.dashboardCID]; publishCounters() }
    func inspectDashboardReads() { dashboardReadInspection += 1; publishCounters() }
    func releaseDashboardRead() {
        guard !heldDashboardReplies.isEmpty else { return }
        let held = heldDashboardReplies.removeFirst()
        held.continuation.resume()
    }
    func commitDashboardChange() async {
        guard scenario.hasPrefix("dashboard-") else { return }
        if ["dashboard-full-refresh", "dashboard-held-pagination", "dashboard-cover-reveal", "dashboard-cache-race", "dashboard-search-refresh", "dashboard-records-refresh", "dashboard-initial-records"].contains(scenario) {
            dashboardRows.removeAll { $0 == Self.dashboardAID }
        }
        dashboardBTitle = dashboardCommitCount == 0 ? "1284 Fixture B refreshed" : "1284 Fixture B newest \(dashboardCommitCount + 1)"
        dashboardCommitCount += 1
        stateRevision += 1
        let recordIDs: [String]? = ["dashboard-cache-race", "dashboard-overlap-intent"].contains(scenario) && dashboardCommitCount > 1 ? [Self.dashboardBID] : nil
        dashboardEventIDShape = recordIDs.map { "count:\($0.count)" } ?? "missing"
        publishCounters()
        var payload: [String: JSONValue] = ["stateRevision": .number(Double(stateRevision))]
        if let recordIDs { payload["recordIds"] = .array(recordIDs.map(JSONValue.string)) }
        await broadcast(topic: "knowledge.changed", payload: .object(payload))
        dashboardEventCount += 1
        publishCounters()
    }

    func completeSummary() async {
        trace("control:completeSummary pending:\(pendingSummary != nil)")
        guard let command = pendingSummary else { return }
        summaryDoneCount += 1
        pendingSummary = nil
        summary = "A repository describing how to turn a product goal into an explicit loss function an agent can optimize against."
        revision += 1
        await finish(command, status: "done")
    }
    func failSummary() async {
        guard let command = pendingSummary else { return }
        pendingSummary = nil
        await finish(command, status: "failed", code: "unavailable", reason: "The Knowledge model timed out. Your existing summary is unchanged.")
    }
    func completeTags() async {
        guard let command = pendingTags else { return }
        pendingTags = nil
        tagIDs = ["agent-harness", "evaluation"]
        revision += 1
        await finish(command, status: "done")
    }
    func failTags() async {
        guard let command = pendingTags else { return }
        pendingTags = nil
        await finish(command, status: "failed", code: "budget-exhausted", reason: "This month's tagging budget is spent. Your current tags are unchanged.")
    }

    private func startJob(_ command: String, operation: String) -> JSONValue {
        let job = JSONValue.object(["commandId": .string(command), "operation": .string(operation), "sourceId": .string(Self.sourceID),
                                    "status": .string("running"), "startedAt": .string(Self.timestamp())])
        jobs.insert(job, at: 0)
        return job
    }

    private func finish(_ command: String, status: String, code: String? = nil, reason: String? = nil) async {
        guard let index = jobs.firstIndex(where: { $0.objectValue?["commandId"]?.stringValue == command }), var fields = jobs[index].objectValue else { return }
        fields["status"] = .string(status)
        fields["finishedAt"] = .string(Self.timestamp())
        if status == "done" { fields["revisionId"] = .string(revisionID) }
        if let code { fields["code"] = .string(code) }
        if let reason { fields["reason"] = .string(reason) }
        jobs[index] = .object(fields)
        // The Gateway publishes the whole job, then the committed invalidation.
        await broadcast(topic: "knowledge.curation.job", payload: .object(fields))
        if status == "done" { await publishChange() }
    }

    private func publishChange() async {
        stateRevision += 1
        await broadcast(topic: "knowledge.changed", payload: .object(["stateRevision": .number(Double(stateRevision)), "recordIds": .array([.string(Self.sourceID)])]))
    }

    private func broadcast(topic: String, payload: JSONValue) async {
        let idShape: String
        if topic == "knowledge.changed" {
            if payload.objectValue?["recordIds"] == nil { idShape = "missing" }
            else if let ids = payload.objectValue?["recordIds"]?.arrayValue { idShape = ids.isEmpty ? "empty" : "count:\(min(64, ids.count))" }
            else { idShape = "malformed" }
        } else { idShape = "not-applicable" }
        trace("event:\(topic) r\(stateRevision) recordIds:\(idShape) sockets:\(sockets.count)")
        guard let frame = try? JSONEncoder.gateway.encode(JSONValue.object(["type": .string("event"), "topic": .string(topic), "payload": payload])) else { return }
        for socket in sockets { await socket.deliver(frame) }
    }

    /// Returns a result, or an error object `{code, message, retryable, details?}`.
    func handle(method: String, params: [String: JSONValue]) async -> (result: JSONValue?, error: JSONValue?) {
        trace("read:\(method) r\(revision) job:\(jobs.last?.objectValue?["status"]?.stringValue ?? "none") requested:\(params["revisionId"]?.stringValue ?? "latest")")
        switch method {
        case "command.status":
            guard params["method"]?.stringValue == "knowledge.source.summarize",
                  let command = params["commandId"]?.stringValue,
                  let result = summaryStartReceipts[command] else { return (.object(["status": .string("missing")]), nil) }
            if scenario == "summary-start-held" { await waitForSummaryStartRelease() }
            return (.object(["status": .string("completed"), "result": result]), nil)
        case "knowledge.status":
            return (status(), nil)
        case "knowledge.list":
            if scenario.hasPrefix("dashboard-") {
                dashboardReadCount += 1
                if params["kind"]?.stringValue != "source" {
                    let records = (scenario == "dashboard-records-refresh" && params["kind"]?.stringValue == "note") ||
                        (scenario == "dashboard-initial-records" && params["kind"]?.stringValue == "observation")
                        ? dashboardRows.map { record(id: $0) } : []
                    let result: JSONValue = .object(["records": .array(records), "stateRevision": .number(Double(stateRevision))])
                    if scenario == "dashboard-initial-records", dashboardCommitCount == 0 {
                        dashboardRowsHeld += 1
                        publishCounters()
                        await withCheckedContinuation { heldDashboardReplies.append(HeldDashboardReply(descriptor: "initial-records", continuation: $0)) }
                        dashboardRowsReleased += 1
                    }
                    if scenario == "dashboard-cache-race", dashboardCommitCount > 0,
                       params["kind"]?.stringValue == "observation", dashboardHeadReadCount == 1 {
                        // Keep the new dashboard's initial Chronicle read pending
                        // until the user selects Library. This exercises cache
                        // hydration rather than a pre-existing empty Records page.
                        await withCheckedContinuation { dashboardChronicleReply = $0 }
                    }
                    publishCounters()
                    return (result, nil)
                }
                let cursor = params["cursor"]?.stringValue
                let exactIDs = params["ids"]?.arrayValue?.compactMap(\.stringValue)
                let pageIDs: [String]
                let nextCursor: String?
                if let exactIDs {
                    pageIDs = exactIDs
                    nextCursor = nil
                } else if scenario == "dashboard-pagination-control" {
                    switch cursor {
                    case "dashboard-page-2": pageIDs = [Self.dashboardCID]; nextCursor = "dashboard-page-3"
                    case "dashboard-page-3": pageIDs = [Self.dashboardDID]; nextCursor = nil
                    default: pageIDs = [Self.dashboardAID, Self.dashboardBID]; nextCursor = "dashboard-page-2"
                    }
                } else if scenario == "dashboard-held-pagination" {
                    switch cursor {
                    case "dashboard-initial-p2": pageIDs = [Self.dashboardCID]; nextCursor = nil
                    case "dashboard-fresh-p2": pageIDs = [Self.dashboardDID]; nextCursor = nil
                    default: pageIDs = [Self.dashboardAID, Self.dashboardBID]; nextCursor = dashboardCommitCount == 0 ? "dashboard-initial-p2" : "dashboard-fresh-p2"
                    }
                } else if scenario == "dashboard-overlap-intent" {
                    pageIDs = cursor == nil ? [Self.dashboardAID, Self.dashboardBID] : [Self.dashboardCID]
                    nextCursor = cursor == nil ? "dashboard-overlap-p2" : nil
                } else if let cursor {
                    pageIDs = []
                    nextCursor = nil
                    trace("unexpected-dashboard-cursor:\(cursor)")
                } else {
                    pageIDs = dashboardRows
                    nextCursor = nil
                }
                let rows = scenario == "dashboard-records-refresh" ? [] : pageIDs.filter { dashboardRows.contains($0) }.map { dashboardRow(id: $0) }.filter {
                    params["scope"]?.stringValue == nil || $0.objectValue?["scope"]?.stringValue == params["scope"]?.stringValue
                }
                let responseRevision = stateRevision
                dashboardResponseIDs = rows.compactMap { $0.objectValue?["id"]?.stringValue }.joined(separator: ",")
                dashboardResponseRevision = responseRevision
                let isHead = exactIDs == nil && cursor == nil
                if let exactIDs {
                    dashboardExactReadCount += 1
                    dashboardExactReadIDs = exactIDs.joined(separator: ",")
                } else if isHead {
                    dashboardChronicleReply?.resume()
                    dashboardChronicleReply = nil
                    if !heldDashboardReplies.isEmpty { dashboardHeadsWhileHeld += 1 }
                    dashboardHeadReadCount += 1
                    dashboardHeadResponseIDs = dashboardResponseIDs
                    dashboardHeadResponseRevision = responseRevision
                }
                let descriptor: String
                if let exactIDs {
                    descriptor = "ids[\(exactIDs.joined(separator: ","))]@r\(responseRevision)=\(dashboardResponseIDs)"
                } else if let cursor {
                    descriptor = "cursor[\(cursor)]@r\(responseRevision)=\(dashboardResponseIDs) next=\(nextCursor ?? "nil")"
                } else {
                    descriptor = "head@r\(responseRevision)=\(dashboardResponseIDs) next=\(nextCursor ?? "nil") scope=\(params["scope"]?.stringValue ?? "all")"
                }
                dashboardRequestDescriptors.append(descriptor)
                if dashboardRequestDescriptors.count > 20 { dashboardRequestDescriptors.removeFirst() }
                let shouldHold = (dashboardHoldNextHead && isHead) || (dashboardHoldCursor == cursor && cursor != nil) || (exactIDs.map(Set.init) == dashboardHoldIDs && dashboardHoldIDs != nil)
                if shouldHold {
                    dashboardHoldNextHead = false
                    dashboardHoldCursor = nil
                    dashboardHoldIDs = nil
                    dashboardRowsHeld += 1
                    dashboardHeldSnapshotIDs = dashboardResponseIDs
                    dashboardHeldSnapshotRevision = responseRevision
                    publishCounters()
                    await withCheckedContinuation { heldDashboardReplies.append(HeldDashboardReply(descriptor: descriptor, continuation: $0)) }
                    dashboardRowsReleased += 1
                }
                publishCounters()
                var result: [String: JSONValue] = ["rows": .array(rows), "stateRevision": .number(Double(responseRevision))]
                if let nextCursor { result["nextCursor"] = .string(nextCursor) }
                return (.object(result), nil)
            }
            let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? [Self.sourceID]
            let rows: [JSONValue] = ids.compactMap { id in
                if id == Self.sourceID { return currentRow() }
                if id == Self.replacementID { return Self.row(id: id, revision: 1, title: "Harness design, revised", scope: "research", verdict: "evergreen", supersededBy: nil, hasTake: false, tags: ["agent-harness"], summary: nil) }
                return nil
            }
            let result: JSONValue = .object(["rows": .array(rows), "stateRevision": .number(Double(stateRevision))])
            if holdNextRows {
                holdNextRows = false; rowsHeld += 1; publishCounters()
                await withCheckedContinuation { heldRows = $0 }
                rowsReleased += 1; publishCounters()
            }
            return (result, nil)
        case "knowledge.search":
            if scenario.hasPrefix("dashboard-"), params["kind"]?.stringValue == "source" {
                let query = params["query"]?.stringValue?.lowercased() ?? ""
                let rows = dashboardRows.map { dashboardRow(id: $0) }.filter {
                    $0.objectValue?["title"]?.stringValue?.lowercased().contains(query) == true
                }
                dashboardSearchCount += 1
                dashboardSearchResponseIDs = rows.compactMap { $0.objectValue?["id"]?.stringValue }.joined(separator: ",")
                dashboardSearchResponseRevision = stateRevision
                publishCounters()
                return (.object(["rows": .array(rows), "stateRevision": .number(Double(stateRevision))]), nil)
            }
            return (.object(["rows": .array([]), "stateRevision": .number(Double(stateRevision))]), nil)
        case "knowledge.forget":
            guard params["recordId"]?.stringValue == Self.sourceID, params["expectedRevision"]?.stringValue == revisionID else {
                return (nil, .object(["code": .string("conflict"), "message": .string("Wrong record revision"), "retryable": .bool(false)]))
            }
            forgetCount += 1; stateRevision += 1; publishCounters()
            return (.object(["forgotten": .bool(true), "recordId": .string(Self.sourceID), "stateRevision": .number(Double(stateRevision))]), nil)
        case "knowledge.read":
            if scenario.hasPrefix("dashboard-") {
                dashboardRecordReadCount += 1
                let requestedID = params["id"]?.stringValue ?? ""
                let found = dashboardRows.contains(requestedID)
                dashboardRecordReadIDs = found ? requestedID : ""
                dashboardRecordReadRevision = stateRevision
                publishCounters()
                if !found { return (.null, nil) }
                return (record(id: requestedID), nil)
            }
            return (record(), nil)
        case "knowledge.curation.jobs":
            jobsReadCount += 1; publishCounters()
            let running = jobs.filter { $0.objectValue?["status"]?.stringValue == "running" }.count
            let failed = jobs.filter { $0.objectValue?["status"]?.stringValue == "failed" }.count
            return (.object(["jobs": .array(Array(jobs.prefix(25))), "running": .number(Double(running)), "failed": .number(Double(failed))]), nil)
        case "knowledge.correction":
            correctionCount += 1; publishCounters()
            revision += 1
            summary = "Corrected summary from the accepted correction."
            return (.object(["record": record(), "stateRevision": .number(Double(stateRevision))]), nil)
        case "knowledge.source.summarize":
            let command = params["commandId"]?.stringValue ?? "summary"
            if let existing = jobs.first(where: { $0.objectValue?["commandId"]?.stringValue == command }) {
                return (.object(["job": existing, "record": record()]), nil)
            }
            summarizeCount += 1; publishCounters()
            pendingSummary = command
            let result: JSONValue = .object(["job": startJob(command, operation: "summary"), "record": record()])
            summaryStartReceipts[command] = result
            if scenario == "summary-start-held" { await waitForSummaryStartRelease() }
            summaryStartAckCount += 1; publishCounters()
            return (result, nil)
        case "knowledge.source.tag":
            let command = params["commandId"]?.stringValue ?? "tag"
            if let existing = jobs.first(where: { $0.objectValue?["commandId"]?.stringValue == command }) { return (.object(["job": existing]), nil) }
            tagCount += 1; publishCounters()
            pendingTags = command
            return (.object(["job": startJob(command, operation: "tags")]), nil)
        case "knowledge.source.take":
            takeCount += 1
            takeCommands.insert(params["commandId"]?.stringValue ?? "missing")
            latestTakeWasSubmitted = params["text"]?.stringValue == "chunk1 chunk2 "
            let takeNumber = takeCount
            var mode = scenario == "take-failure-held" ? TakeMode.failure : nextTake
            nextTake = .success
            publishCounters()
            if scenario == "take-failure-held" {
                // Hold the dismissal flush too: its canonical write must not
                // hide a lost process-local draft in the reopen oracle.
                await withCheckedContinuation { continuation in
                    heldTakeReplies.append((number: takeNumber, continuation: continuation))
                    takeHeldCount += 1
                    publishCounters()
                }
                takeReleasedCount += 1
                if successfulTakeReplies.remove(takeNumber) != nil { mode = .success }
                publishCounters()
            }
            switch mode {
            case .conflict:
                // Another device saved first: the server moves on and reports it.
                take = "Remote edit from another device"
                revision += 1
                return (nil, .object(["code": .string("conflict"), "message": .string("Source revision changed"), "retryable": .bool(false),
                                      "details": .object(["currentRevision": .string(revisionID), "currentTake": .string(take!)])]))
            case .failure:
                return (nil, .object(["code": .string("unavailable"), "message": .string("The Gateway could not save your take."), "retryable": .bool(true)]))
            case .success:
                if let expected = params["expectedRevision"]?.stringValue, expected != revisionID {
                    return (nil, .object(["code": .string("conflict"), "message": .string("Source revision changed"), "retryable": .bool(false),
                                          "details": .object(["currentRevision": .string(revisionID), "currentTake": .string(take ?? "")])]))
                }
                take = params["text"]?.stringValue
                takeSucceededCount += 1
                publishCounters()
                revision += 1
                // A saved take re-tags in the background, as the tagging owner does.
                let tagCommand = "take-retag-\(revision)"
                pendingTags = tagCommand
                _ = startJob(tagCommand, operation: "tags")
                let result = JSONValue.object(["record": record(), "stateRevision": .number(Double(stateRevision + 1))])
                await publishChange()
                return (result, nil)
            }
        case "knowledge.source.curate":
            let item = params["items"]?.arrayValue?.first?.objectValue ?? [:]
            if nextCurationConflict {
                nextCurationConflict = false
                revision += 1
                await publishChange()
                return (.object(["commandId": params["commandId"] ?? .string("curate"),
                                 "operation": params["operation"] ?? .string("verdict"), "applied": .number(0), "unchanged": .number(0),
                                 "outcomes": .array([.object(["recordId": .string(Self.sourceID), "status": .string("conflict"),
                                                               "code": .string("stale-revision"), "reason": .string("Another edit changed this source."),
                                                               "currentRevision": .string(revisionID)])]),
                                 "stateRevision": .number(Double(stateRevision))]), nil)
            }
            if item["expectedRevision"]?.stringValue != revisionID {
                return (.object(["commandId": params["commandId"] ?? .string("curate"),
                                 "operation": params["operation"] ?? .string("verdict"), "applied": .number(0), "unchanged": .number(0),
                                 "outcomes": .array([.object(["recordId": .string(Self.sourceID), "status": .string("conflict"),
                                                               "code": .string("stale-revision"), "reason": .string("Source revision is stale."),
                                                               "currentRevision": .string(revisionID)])]),
                                 "stateRevision": .number(Double(stateRevision))]), nil)
            }
            if let value = item["verdict"]?.objectValue {
                verdict = value["verdict"]?.stringValue
                supersededBy = value["supersededBy"]?.stringValue
            }
            if let placement = item["placement"]?.objectValue {
                if let next = placement["scope"]?.stringValue { scope = next }
                if let next = placement["admission"]?.stringValue { admission = next }
            }
            revision += 1
            let result = JSONValue.object(["commandId": params["commandId"] ?? .string("curate"), "operation": params["operation"] ?? .string("verdict"), "applied": .number(1),
                                           "outcomes": .array([.object(["recordId": .string(Self.sourceID), "status": .string("applied"), "revisionId": .string(revisionID)])]),
                                           "stateRevision": .number(Double(stateRevision + 1))])
            await publishChange()
            return (result, nil)
        default:
            return (nil, .object(["code": .string("unsupported"), "message": .string("Knowledge detail fixture"), "retryable": .bool(false)]))
        }
    }

    private var revisionID: String { "revision-\(revision)" }

    private func status() -> JSONValue {
        let tags: [JSONValue] = [("workflows", "Workflows"), ("agent-harness", "Agent harness"), ("evaluation", "Evaluation")].map { id, label in
            .object(["id": .string(id), "label": .string(label), "definition": .string(label), "category": .string("ai"), "decayClass": .string("ages"), "state": .string("active")])
        }
        let zero = JSONValue.number(0)
        return .object([
            "available": .bool(true), "state": .string("ready"), "stateRevision": .number(Double(stateRevision)), "recordCount": .number(1), "coverageCount": zero,
            "coverage": .object(["observedCount": zero, "emptyCount": zero, "excludedCount": zero, "pendingCount": zero, "failedCount": zero, "unavailableCount": zero, "remainingCount": zero]),
            "suppressedCount": zero, "pendingCleanupCount": zero, "observationConfigured": .bool(false),
            "config": .object([
                "schemaVersion": .number(1), "revision": .number(1),
                "eligibility": .object(["sessionIds": .array([]), "projectIds": .array([]), "excludedSessionIds": .array([]), "excludedProjectIds": .array([])]),
                "observation": .object(["enabled": .bool(false), "maxInputChars": .number(6_000), "maxOutputChars": .number(2_000), "timeoutMs": .number(12_000), "maxAttempts": .number(1)]),
                "maximumSearchResults": .number(10), "currentInterests": .array([]),
                "tagVocabulary": .object(["revision": .number(1), "tags": .array(tags), "guidelines": .string("")]),
            ]),
        ])
    }

    private func dashboardRow(id: String) -> JSONValue {
        let title: String
        if id == Self.dashboardAID { title = dashboardATitle }
        else if id == Self.dashboardBID { title = dashboardBTitle }
        else if id == Self.dashboardCID { title = scenario == "dashboard-overlap-intent" && dashboardCommitCount > 0 ? "1284 Fixture C refreshed" : "1284 Fixture C" }
        else if id == Self.dashboardDID { title = dashboardDTitle }
        else { title = "1284 Fixture \(id)" }
        let revision = id == Self.dashboardBID ? dashboardCommitCount + 1 : (id == Self.dashboardCID && scenario == "dashboard-overlap-intent" && dashboardCommitCount > 0 ? 2 : 1)
        let rowScope = scenario == "dashboard-cache-race" && id == Self.dashboardBID ? "personal" : "research"
        return Self.row(id: id, revision: revision, title: title, scope: rowScope,
                   verdict: nil, supersededBy: nil, hasTake: false, tags: [], summary: nil)
    }

    private func currentRow() -> JSONValue {
        Self.row(id: Self.sourceID, revision: revision, title: Self.title, scope: scope, verdict: verdict, supersededBy: supersededBy,
                 hasTake: take != nil, tags: tagIDs, summary: summary, tagsStale: pendingTags != nil, admission: admission)
    }

    private static func row(id: String, revision: Int, title: String, scope: String, verdict: String?, supersededBy: String?, hasTake: Bool, tags: [String], summary: String?, tagsStale: Bool = false, admission: String = "retained") -> JSONValue {
        let labels = ["workflows": "Workflows", "agent-harness": "Agent harness", "evaluation": "Evaluation"]
        var fields: [String: JSONValue] = [
            "schemaVersion": .number(1), "id": .string(id), "revisionId": .string("revision-\(revision)"), "scope": .string(scope),
            "createdAt": .string("2026-06-01T00:00:00Z"), "updatedAt": .string("2026-09-29T00:00:00Z"), "title": .string(title),
            "uri": .string("https://example.test/\(id)"), "mediaType": .string("text/html"), "captureDisposition": .string("complete"),
            "admission": .string(admission), "sourceSavedAt": .string("2026-06-01T00:00:00Z"), "ageBasis": .string("sourceSavedAt"),
            "ageDays": .number(120), "freshness": .string("aging"), "hasTake": .bool(hasTake), "tagsStale": .bool(tagsStale),
            "tags": .array(tags.map { .object(["id": .string($0), "label": .string(labels[$0] ?? $0)]) }),
        ]
        if let verdict { fields["verdict"] = .string(verdict) }
        if let supersededBy { fields["supersededBy"] = .string(supersededBy) }
        if let summary { fields["summary"] = .string(summary) }
        return .object(fields)
    }

    private func record() -> JSONValue { record(id: Self.sourceID) }

    private func record(id: String) -> JSONValue {
        let recordTitle: String
        if id == Self.sourceID { recordTitle = Self.title }
        else { recordTitle = dashboardRow(id: id).objectValue?["title"]?.stringValue ?? "1284 Fixture" }
        let recordRevision = id == Self.sourceID ? revisionID : dashboardRow(id: id).objectValue?["revisionId"]?.stringValue ?? "revision-1"
        var content: [String: JSONValue] = [
            "title": .string(recordTitle), "uri": .string("https://example.test/\(id)"), "text": .string(Self.text),
            "mediaType": .string("text/html"), "captureDisposition": .string("complete"), "capturedAt": .string("2026-06-01T00:00:00Z"),
            "sourceSavedAt": .string("2026-06-01T00:00:00Z"), "origin": .string("connector"),
            "admission": .object(["status": .string(admission), "decidedAt": .string("2026-06-01T00:00:00Z")]),
            "tags": .object(["tagIds": .array(tagIDs.map(JSONValue.string)), "vocabularyRevision": .number(1),
                             "inputsDigest": .string(String(repeating: "a", count: 64)), "assignedAt": .string("2026-09-29T00:00:00Z")]),
        ]
        if scenario == "dashboard-records-refresh" {
            content = ["title": .string(recordTitle), "body": .string(Self.text), "role": .string("synthesis"), "confirmed": .bool(true)]
        }
        if scenario == "dashboard-initial-records" {
            content = [
                "range": .object(["sessionId": .string("fixture-session"), "fromEntryId": .string(id), "toEntryId": .string(id),
                                   "entryIds": .array([.string(id)]), "entryDigest": .string(String(repeating: "a", count: 64))]),
                "items": .array([.object(["text": .string(recordTitle), "attribution": .string("user"),
                                          "observedAt": .string("2026-06-01T00:00:00Z"), "certainty": .string("certain")])]),
            ]
        }
        if let summary {
            content["summary"] = .object(["text": .string(summary), "generatedAt": .string("2026-09-29T00:00:00Z"), "sourceRevisionId": .string(revisionID),
                                          "evidenceDigest": .string(Self.evidenceDigest), "coverage": .string("full")])
        }
        if let take { content["take"] = .object(["text": .string(take), "confirmed": .bool(true), "updatedAt": .string("2026-09-29T00:00:00Z")]) }
        if let verdict {
            var value: [String: JSONValue] = ["verdict": .string(verdict), "decidedAt": .string("2026-09-29T00:00:00Z")]
            if let supersededBy { value["supersededBy"] = .string(supersededBy) }
            content["verdict"] = .object(value)
        }
        return .object([
            "schemaVersion": .number(1), "id": .string(id), "revisionId": .string(recordRevision), "kind": .string(scenario == "dashboard-records-refresh" ? "note" : (scenario == "dashboard-initial-records" ? "observation" : "source")), "scope": .string(scope),
            "createdAt": .string("2026-06-01T00:00:00Z"), "updatedAt": .string("2026-09-29T00:00:00Z"),
            "provenance": .object(["actor": .string("connector"), "evidence": .array([])]), "relations": .array([]), "content": .object(content),
        ])
    }

    /// SHA-256 of Gateway `JSON.stringify({title, text})` for these ASCII fixtures.
    private static let evidenceDigest: String = {
        let canonical = "{\"title\":\"\(title)\",\"text\":\"\(text)\"}"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    private static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}

actor HostedKnowledgeSocket: GatewaySocketConnection {
    private let gateway: HostedKnowledgeGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    init(gateway: HostedKnowledgeGateway, replacement: Bool = false) {
        self.gateway = gateway
        let machineID = replacement ? "fixture-knowledge-replacement" : "fixture-knowledge"
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"\(machineID)\",\"machineName\":\"Studio server\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"knowledge.v1\",\"knowledge-library-rows.v1\",\"knowledge-curation.v1\"]}".utf8)]
        Task { await gateway.attach(self) }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return }
        Task {
            let reply = await gateway.handle(method: method, params: frame["params"]?.objectValue ?? [:])
            await gateway.trace("reply:\(method) record:\(reply.result?.objectValue?["revisionId"]?.stringValue ?? "none")")
            await sendReply(id: id, reply: reply)
        }
    }
    private func sendReply(id: String, reply: (result: JSONValue?, error: JSONValue?)) {
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(reply.error == nil)]
        if let result = reply.result { response["result"] = result }
        if let error = reply.error { response["error"] = error }
        guard let data = try? JSONEncoder.gateway.encode(JSONValue.object(response)) else { return }
        deliver(data)
    }

    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }
    func close() async {
        closed = true
        let pending = receivers
        receivers.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
    /// A lost network link, not a client close: the reconnect owner must retry.
    func drop() {
        closed = true
        let pending = receivers
        receivers.removeAll()
        pending.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }
    func deliver(_ data: Data) {
        guard !closed else { return }
        if receivers.isEmpty { inbound.append(data) }
        else { receivers.removeFirst().resume(returning: data) }
    }
}
#endif
