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
    private let profile = GatewayProfile(id: "knowledge-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-knowledge")
    @State private var model: AppModel
    @State private var gateway: HostedKnowledgeGateway
    @State private var ready = false
    @State private var error: String?
    @State private var detailMounted = true
    @State private var detailGeneration = 0
    @State private var counters = "summarize:0 take:0 tag:0"
    @State private var typedChunks = 0

    init() {
        let scenario = ProcessInfo.processInfo.arguments.drop(while: { $0 != "-knowledge-detail-scenario" }).dropFirst().first ?? "default"
        let gateway = HostedKnowledgeGateway(scenario: scenario)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in HostedKnowledgeSocket(gateway: gateway) })
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        _gateway = State(initialValue: gateway)
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-knowledge-detail-fixture"))))
    }

    var body: some View {
        TronPresentationSurface(id: "hosted-knowledge-detail-fixture") {
            VStack(spacing: 0) {
                if ready {
                    if detailMounted {
                        KnowledgeDetailSheet(subject: .row(gateway.initialRow), origin: model.knowledgePresentationIdentity,
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
        .environment(model)
        .tronPresentation()
        .preferredColorScheme(.dark)
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                ready = true
            } catch { self.error = error.localizedDescription }
        }
        .task {
            for await value in gateway.counterUpdates() { counters = value }
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
            Text(counters).font(.caption2.monospaced()).accessibilityIdentifier("fixture.counters")
            HStack(spacing: 4) {
                control("Close", id: "fixture.close-detail") { detailMounted = false }
                control("Open", id: "fixture.open-detail") { detailGeneration += 1; detailMounted = true }
                control("Drop", id: "fixture.drop-connection") { Task { await gateway.dropConnection() } }
            }
            HStack(spacing: 4) {
                control("Sum ✓", id: "fixture.complete-summary") { Task { await gateway.completeSummary() } }
                control("Sum ✗", id: "fixture.fail-summary") { Task { await gateway.failSummary() } }
                control("Tags ✓", id: "fixture.complete-tags") { Task { await gateway.completeTags() } }
                control("Tags ✗", id: "fixture.fail-tags") { Task { await gateway.failTags() } }
            }
            HStack(spacing: 4) {
                control("Take conflict", id: "fixture.next-take-conflict") { Task { await gateway.setNextTake(.conflict) } }
                control("Take fail", id: "fixture.next-take-failure") { Task { await gateway.setNextTake(.failure) } }
                control("Type", id: "fixture.type-take") { typedChunks += 1; Self.insertIntoTake("chunk\(typedChunks) ") }
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
    private var jobs: [JSONValue] = []
    private var pendingSummary: String?
    private var pendingTags: String?
    private var nextTake = TakeMode.success
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
        let value = "summarize:\(summarizeCount) take:\(takeCount) tag:\(tagCount)"
        counterContinuations.forEach { $0.yield(value) }
    }

    func attach(_ socket: HostedKnowledgeSocket) { sockets.append(socket) }
    func dropConnection() async {
        let current = sockets; sockets.removeAll()
        for socket in current { await socket.drop() }
    }
    func setNextTake(_ mode: TakeMode) { nextTake = mode }

    func completeSummary() async {
        guard let command = pendingSummary else { return }
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
        guard let frame = try? JSONEncoder.gateway.encode(JSONValue.object(["type": .string("event"), "topic": .string(topic), "payload": payload])) else { return }
        for socket in sockets { await socket.deliver(frame) }
    }

    /// Returns a result, or an error object `{code, message, retryable, details?}`.
    func handle(method: String, params: [String: JSONValue]) async -> (result: JSONValue?, error: JSONValue?) {
        switch method {
        case "knowledge.status":
            return (status(), nil)
        case "knowledge.list":
            let ids = params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? [Self.sourceID]
            let rows: [JSONValue] = ids.compactMap { id in
                if id == Self.sourceID { return currentRow() }
                if id == Self.replacementID { return Self.row(id: id, revision: 1, title: "Harness design, revised", scope: "research", verdict: "evergreen", supersededBy: nil, hasTake: false, tags: ["agent-harness"], summary: nil) }
                return nil
            }
            return (.object(["rows": .array(rows), "stateRevision": .number(Double(stateRevision))]), nil)
        case "knowledge.search":
            return (.object(["rows": .array([]), "stateRevision": .number(Double(stateRevision))]), nil)
        case "knowledge.read":
            return (record(), nil)
        case "knowledge.curation.jobs":
            let running = jobs.filter { $0.objectValue?["status"]?.stringValue == "running" }.count
            let failed = jobs.filter { $0.objectValue?["status"]?.stringValue == "failed" }.count
            return (.object(["jobs": .array(Array(jobs.prefix(25))), "running": .number(Double(running)), "failed": .number(Double(failed))]), nil)
        case "knowledge.source.summarize":
            let command = params["commandId"]?.stringValue ?? "summary"
            if let existing = jobs.first(where: { $0.objectValue?["commandId"]?.stringValue == command }) {
                return (.object(["job": existing, "record": record()]), nil)
            }
            summarizeCount += 1; publishCounters()
            pendingSummary = command
            return (.object(["job": startJob(command, operation: "summary"), "record": record()]), nil)
        case "knowledge.source.tag":
            let command = params["commandId"]?.stringValue ?? "tag"
            if let existing = jobs.first(where: { $0.objectValue?["commandId"]?.stringValue == command }) { return (.object(["job": existing]), nil) }
            tagCount += 1; publishCounters()
            pendingTags = command
            return (.object(["job": startJob(command, operation: "tags")]), nil)
        case "knowledge.source.take":
            takeCount += 1; publishCounters()
            let mode = nextTake
            nextTake = .success
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
            if let value = item["verdict"]?.objectValue {
                verdict = value["verdict"]?.stringValue
                supersededBy = value["supersededBy"]?.stringValue
            }
            if let placement = item["placement"]?.objectValue, let next = placement["scope"]?.stringValue { scope = next }
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

    private func currentRow() -> JSONValue {
        Self.row(id: Self.sourceID, revision: revision, title: Self.title, scope: scope, verdict: verdict, supersededBy: supersededBy,
                 hasTake: take != nil, tags: tagIDs, summary: summary, tagsStale: pendingTags != nil)
    }

    private static func row(id: String, revision: Int, title: String, scope: String, verdict: String?, supersededBy: String?, hasTake: Bool, tags: [String], summary: String?, tagsStale: Bool = false) -> JSONValue {
        let labels = ["workflows": "Workflows", "agent-harness": "Agent harness", "evaluation": "Evaluation"]
        var fields: [String: JSONValue] = [
            "schemaVersion": .number(1), "id": .string(id), "revisionId": .string("revision-\(revision)"), "scope": .string(scope),
            "createdAt": .string("2026-06-01T00:00:00Z"), "updatedAt": .string("2026-09-29T00:00:00Z"), "title": .string(title),
            "uri": .string("https://example.test/\(id)"), "mediaType": .string("text/html"), "captureDisposition": .string("complete"),
            "admission": .string("retained"), "sourceSavedAt": .string("2026-06-01T00:00:00Z"), "ageBasis": .string("sourceSavedAt"),
            "ageDays": .number(120), "freshness": .string("aging"), "hasTake": .bool(hasTake), "tagsStale": .bool(tagsStale),
            "tags": .array(tags.map { .object(["id": .string($0), "label": .string(labels[$0] ?? $0)]) }),
        ]
        if let verdict { fields["verdict"] = .string(verdict) }
        if let supersededBy { fields["supersededBy"] = .string(supersededBy) }
        if let summary { fields["summary"] = .string(summary) }
        return .object(fields)
    }

    private func record() -> JSONValue {
        var content: [String: JSONValue] = [
            "title": .string(Self.title), "uri": .string("https://example.test/\(Self.sourceID)"), "text": .string(Self.text),
            "mediaType": .string("text/html"), "captureDisposition": .string("complete"), "capturedAt": .string("2026-06-01T00:00:00Z"),
            "sourceSavedAt": .string("2026-06-01T00:00:00Z"), "origin": .string("connector"),
            "admission": .object(["status": .string("retained"), "decidedAt": .string("2026-06-01T00:00:00Z")]),
            "tags": .object(["tagIds": .array(tagIDs.map(JSONValue.string)), "vocabularyRevision": .number(1),
                             "inputsDigest": .string(String(repeating: "a", count: 64)), "assignedAt": .string("2026-09-29T00:00:00Z")]),
        ]
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
            "schemaVersion": .number(1), "id": .string(Self.sourceID), "revisionId": .string(revisionID), "kind": .string("source"), "scope": .string(scope),
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
    private var inbound = [Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":6,"minProtocolVersion":6,"machineId":"fixture-knowledge","machineName":"Studio server","gatewayChannel":"stable","capabilities":["knowledge.v1","knowledge-library-rows.v1","knowledge-curation.v1"]}"#.utf8)]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    init(gateway: HostedKnowledgeGateway) {
        self.gateway = gateway
        Task { await gateway.attach(self) }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return }
        let reply = await gateway.handle(method: method, params: frame["params"]?.objectValue ?? [:])
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(reply.error == nil)]
        if let result = reply.result { response["result"] = result }
        if let error = reply.error { response["error"] = error }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
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
