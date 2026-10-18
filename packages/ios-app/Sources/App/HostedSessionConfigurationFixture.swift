#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Actual Stop RPC and Manage Session consumer, with explicit synthetic receipt
/// settlement. No timer infers completion and no canonical runtime is opened.
@MainActor
struct HostedSessionConfigurationFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var presented = false
    @State private var deliveredSupersededReceipt = false
    @State private var decisionState = "none"
    @State private var error: String?
    @State private var modelRequests = 0
    @State private var presentationActivity = PresentationActivityCoordinator()
    private let socket: HostedSessionConfigurationSocket
    private let profile: GatewayProfile
    private let snapshot: SessionSnapshot

    init() {
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        profile = GatewayProfile(id: "configuration-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        try! profiles.save(profile, token: "fixture-token")
        snapshot = SessionSnapshot(
            sessionId: "configuration-fixture", runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
            phase: .running, configurationBlocker: .running, name: "Configuration fixture", cwd: "/workspace",
            parentSessionId: nil, model: ModelRef(provider: "fixture", id: "model"),
            thinkingLevel: "off", availableThinkingLevels: ["off", "high"], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: 0,
            transcriptTotal: 0, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "fixture-host", revision: 1,
                capabilities: [], diagnostics: [], semanticState: .init(statuses: [:], working: .init(message: nil, visible: false),
                    hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: []), diagnostics: [])
        socket = HostedSessionConfigurationSocket(snapshot: snapshot,
            settingsApprovals: ProcessInfo.processInfo.arguments.contains("-session-settings-approvals"))
        _model = State(initialValue: AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { [socket] _ in socket }),
            profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "session-configuration-fixture"))))
    }

    var body: some View {
        NavigationStack {
            if ready {
                // A running chat whose Gateway keeps rebaselining (full session
                // snapshots, as tool boundaries publish) while Manage Session is open.
                Button("Manage running session") {
                    presented = true
                    Task { await socket.streamRunningRebaselines() }
                }
                Button("Stop session") {
                    Task {
                        await model.abort(sessionID: snapshot.sessionId)
                        presented = true
                    }
                }
            } else if let error { Text(error) }
        }
        .tronManagedSheet(isPresented: $presented, identity: "session-configuration") {
            SessionContextSheet(sessionID: snapshot.sessionId, onForkCreated: { _ in })
                .safeAreaInset(edge: .bottom) {
                    VStack {
                        Button("Release terminal settlement") { Task { try? await socket.releaseSettlement() } }
                        Button("Complete superseded thinking") {
                            Task { deliveredSupersededReceipt = (try? await socket.completeSupersededThinking()) == true }
                        }
                        if deliveredSupersededReceipt { Text("Superseded receipt delivered") }
                        Text("decisions:\(decisionState)").accessibilityIdentifier("fixture.session-settings-decisions")
                        Text("Model requests: \(modelRequests)").accessibilityIdentifier("fixture.model-requests")
                    }
                    // Fixture controls stay at the default size so an accessibility
                    // type size measures the sheet's own content, not these probes.
                    .dynamicTypeSize(.large)
                    .task {
                        for await count in socket.modelRequestCounts {
                            modelRequests = count
                        }
                    }.padding()
                }
        }
        .environment(model)
        .environment(\.tronPresentationActivityCoordinator, presentationActivity)
        .background {
            InAppNoticeWindowInstaller(model: model, colorScheme: .light, presentationActivity: presentationActivity)
                .frame(width: 0, height: 0).allowsHitTesting(false)
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("dark") ? .dark : .light)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.invalidateHostedPendingPresentation()
                model.installHostedSubscribedSnapshot(snapshot)
                let catalog = try JSONDecoder.gateway.decode([ModelSummary].self, from: Data(#"[{"provider":"fixture","id":"model","name":"Fixture Model","reasoning":true,"input":["text"],"contextWindow":200000,"maxTokens":32000,"available":true,"releaseDate":"2026-01-01"},{"provider":"fixture","id":"alternative","name":"Alternative Model","reasoning":true,"input":["text"],"contextWindow":200000,"maxTokens":32000,"available":true,"releaseDate":"2026-01-02"}]"#.utf8))
                model.installHostedProviderCatalog(ProviderCatalog(providers: [], models: catalog), for: .session(id: snapshot.sessionId))
                if let action = Self.settingsApprovalPushActionIdentifier(ProcessInfo.processInfo.arguments) {
                    model.stageSettingsDecision(from: Self.settingsApprovalPush(actionIdentifier: action))
                }
                ready = true
            } catch { self.error = String(describing: error) }
        }
        .task {
            while !Task.isCancelled {
                decisionState = await socket.decisionSummary()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The launch flag names the Approve or Decline action the push would carry.
    private static func settingsApprovalPushActionIdentifier(_ arguments: [String]) -> String? {
        if arguments.contains("-session-settings-approval-push-approve") {
            return SettingsApprovalNotification.approveActionIdentifier
        }
        if arguments.contains("-session-settings-approval-push-decline") {
            return SettingsApprovalNotification.declineActionIdentifier
        }
        return nil
    }

    /// The push the relay delivers for a settings change, admitted by the production path.
    private static func settingsApprovalPush(actionIdentifier: String) -> PushNotificationTap {
        PushNotificationTap.admit([
            "aps": ["category": SettingsApprovalNotification.categoryIdentifier,
                    "alert": ["title": "Approval needed", "body": "A chat's agent asks to change Active tools"]],
            "tron": ["kind": "agent_notification", "requestId": "fixture-relay-request-0001"],
            "sessionId": "configuration-fixture",
            "machineId": "fixture-machine",
        ], categoryIdentifier: SettingsApprovalNotification.categoryIdentifier, actionIdentifier: actionIdentifier)
    }
}

private actor HostedSessionConfigurationSocket: GatewaySocketConnection {
    private var bookmarkLabel: String?
    private var snapshot: SessionSnapshot
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    private var pendingThinking: (id: String, revision: Int)?
    private var modelRequests = 0
    private var modelDelivery: Task<Void, Error>?
    nonisolated let modelRequestCounts: AsyncStream<Int>
    private let modelRequestContinuation: AsyncStream<Int>.Continuation
    private var approvals: [JSONValue] = []
    private var decisions: [String] = []
    init(snapshot: SessionSnapshot, settingsApprovals: Bool) {
        self.snapshot = snapshot
        (modelRequestCounts, modelRequestContinuation) = AsyncStream.makeStream(of: Int.self)
        // This chat's agent's request shows in its Manage Session; another chat's does not.
        approvals = settingsApprovals ? ["configuration-fixture", "other-session"].map { sessionID in
            .object([
                "requestId": .string(sessionID == "other-session" ? "settings-other-request" : "settings-session-request"),
                "digest": .string(String(repeating: sessionID == "other-session" ? "e" : "c", count: 64)),
                "createdAt": .string("2026-01-01T00:00:00.000Z"), "expiresAt": .string(Date.now.addingTimeInterval(23 * 60 * 60).formatted(.iso8601)),
                "target": .object(["kind": .string("session"), "sessionId": .string(sessionID)]),
                "actor": .object(["kind": .string("agent"), "id": .string(sessionID), "sessionId": .string(sessionID)]),
                "requester": .string("A chat's agent"), "reason": .string("The page said to"),
                "changes": .array([.object([
                    "changeId": .string("change-\(sessionID)"), "key": .string("tools.active"),
                    "label": .string("Active tools"), "layer": .string("chat"), "op": .string("set"), "tier": .string("approve"),
                    "tierBasis": .object([:]), "before": .array([.string("read"), .string("bash")]),
                    "after": .array([.string("read"), .string("bash"), .string("fetch_page")]),
                    "display": .object(["before": .string("read, bash"), "after": .string("read, bash, fetch_page")]),
                ])]),
            ])
        } : []
    }
    func decisionSummary() -> String { decisions.isEmpty ? "none" : decisions.joined(separator: ",") }
    func resume() async { }
    func ping() async throws { }
    func send(_ data: Data) async throws {
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let id = frame.objectValue?["id"]?.stringValue, let method = frame.objectValue?["method"]?.stringValue else { return }
        let params = frame.objectValue?["params"]?.objectValue ?? [:]
        let result: JSONValue
        switch method {
        case "session.rename":
            snapshot.name = params["name"]?.stringValue
            snapshot.revision += 1; snapshot.eventSequence += 1
            try enqueue(.object(["type": .string("event"), "topic": .string("session.snapshot"),
                "sessionId": .string(snapshot.sessionId), "payload": try JSONValue.encode(snapshot)]))
            result = .object(["updated": .bool(true)])
        case "session.label":
            bookmarkLabel = params["label"]?.stringValue
            result = .object(["updated": .bool(true)])
        case "session.abort":
            snapshot.phase = .idle
            snapshot.configurationBlocker = .settling
            snapshot.eventSequence += 1
            snapshot.revision += 1
            try enqueue(.object(["type": .string("event"), "topic": .string("session.snapshot"),
                "sessionId": .string(snapshot.sessionId), "payload": try JSONValue.encode(snapshot)]))
            result = .object(["aborted": .bool(true)])
        case "settings.resolve":
            result = .object(["keys": .array([.object([
                "key": .string("model.thinking[role=chat]"), "group": .string("model"),
                "value": .string(snapshot.thinkingLevel), "display": .string(snapshot.thinkingLevel.capitalized),
                "layer": .string("chat"), "applied": .bool(true), "origin": .string("launch"),
                "layers": .array([.object(["layer": .string("chat"), "value": .string(snapshot.thinkingLevel), "display": .string(snapshot.thinkingLevel.capitalized), "applied": .bool(true)])]),
                "badges": .array([.object(["kind": .string("source"),
                    "label": .string("From Mac default at start"),
                    "detail": .string("From Mac default at start: \(snapshot.thinkingLevel.capitalized)"),
                    "action": .object(["kind": .string("useCurrentDefault"), "label": .string("Use the current default")])])]),
                "presentation": .object(["label": .string("Chat thinking"), "help": .string("Thinking for this chat."),
                    "order": .number(10), "importance": .string("essential"), "control": .string("choice"),
                    "options": .array([.object(["value": .string("off"), "label": .string("Off")]),
                                       .object(["value": .string("high"), "label": .string("High")])])]),
            ]), .object([
                "key": .string("context.compaction.enabled"), "group": .string("context"),
                "value": .bool(true), "display": .string("On"), "layer": .string("mac"),
                "applied": .bool(false), "badges": .array([]),
                // As the Gateway serves it: a chat can set its own compaction.
                "layers": .array([.object(["layer": .string("chat")]), .object(["layer": .string("mac")]), .object(["layer": .string("builtin")])]),
                "presentation": .object(["label": .string("Automatic compaction"), "help": .string("Automatic compaction policy."),
                    "order": .number(10), "importance": .string("essential"), "control": .string("toggle")]),
            ]), HostedSettingsReviewSchema.key("model.ref[role=chat]", "model", "Model",
                .object(["provider": .string("fixture"), "id": .string("model")]), "Fixture Model", "catalog", order: 5, essential: true, layer: "chat"),
                HostedSettingsReviewSchema.key("model.contextWindow", "model", "Context window", .number(200_000), "200K tokens", order: 30, essential: true),
                HostedSettingsReviewSchema.key("model.queue[role=background]", "workers", "Background models",
                    .array([.string("fixture/memory-a"), .string("fixture/memory-b")]), "2 models", "list", order: 44, essential: true)
            ] + HostedSettingsReviewSchema.additionalKeys.filter {
                !["model.thinking[role=chat]", "context.compaction.enabled", "permissions.budget.task"].contains($0.objectValue?["key"]?.stringValue ?? "")
            }), "sections": .array(HostedSettingsReviewSchema.sections)])
        case "session.context":
            result = .object(["activeTools": .array(HostedSettingsReviewSchema.tools.map(JSONValue.string))])
        case "session.resources":
            result = .object(["tools": .array(HostedSettingsReviewSchema.tools.map {
                .object(["name": .string($0), "description": .string("Session tool details for \($0)."),
                         "parameters": .object(["type": .string("object"), "properties": .object([:])])])
            })])
        case "settings.options":
            result = .object(["key": .string("tools.active"), "source": .string("catalog.tools"),
                "dependsOn": .array([]), "options": .array(HostedSettingsReviewSchema.tools.map {
                    .object(["value": .string($0), "label": .string($0), "resource": .object([:])])
                })])
        case "settings.change":
            let params = frame.objectValue?["params"]?.objectValue ?? [:]
            let change = params["changes"]?.arrayValue?.first?.objectValue
            if change?["key"]?.stringValue == "model.ref[role=chat]" {
                modelRequests += 1
                modelRequestContinuation.yield(modelRequests)
                guard let provider = change?["value"]?.objectValue?["provider"]?.stringValue, let modelID = change?["value"]?.objectValue?["id"]?.stringValue,
                      change?["layer"]?.stringValue == "chat", change?["op"]?.stringValue == "set",
                      params["target"]?.objectValue?["sessionId"]?.stringValue == snapshot.sessionId,
                      params["commandId"]?.stringValue != nil,
                      params["fence"]?.objectValue?["runtimeGeneration"]?.stringValue == snapshot.runtimeGeneration,
                      params["fence"]?.objectValue?["model"] == (try JSONValue.encode(snapshot.model)) else {
                    throw GatewayFailure(code: "invalid_request", message: "Model change lacked its session fence", retryable: false, details: nil)
                }
                let scenario = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("-model-ack-") } ?? "-model-ack-snapshot-first"
                // The remote delivery outlives request-send cancellation on receipt.
                // close() still owns and cancels it with this isolated socket.
                modelDelivery = Task {
                    // Delay only at the scripted socket boundary: the native picker must
                    // remain pending until both its receipt and projection have arrived.
                    try await Task.sleep(for: .seconds(3))
                    if scenario == "-model-ack-failure", modelRequests == 1 {
                        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(false),
                            "error": .object(["code": .string("conflict"), "message": .string("Model choice refused; try again."), "retryable": .bool(false)])]))
                        return
                    }
                    snapshot.model = ModelRef(provider: provider, id: modelID)
                    snapshot.revision += 1
                    let receiptRevision = snapshot.revision
                    snapshot.eventSequence += 1
                    snapshot.thinkingLevel = "off"
                    snapshot.availableThinkingLevels = snapshot.model?.id == "alternative" ? ["off"] : ["off", "high"]
                    if scenario == "-model-ack-superseded" {
                        snapshot.model = ModelRef(provider: "fixture", id: "model")
                        snapshot.revision += 1
                    }
                    let response: JSONValue = .object(["type": .string("response"), "id": .string(id), "ok": .bool(true),
                        "result": fixtureSettingsChangeResult(key: "model.ref[role=chat]", revision: receiptRevision)])
                    let projection: JSONValue = .object(["type": .string("event"), "topic": .string("session.snapshot"),
                        "sessionId": .string(snapshot.sessionId), "payload": try JSONValue.encode(snapshot)])
                    try enqueue(scenario == "-model-ack-receipt-first" ? response : projection)
                    try await Task.sleep(for: .seconds(1))
                    try enqueue(scenario == "-model-ack-receipt-first" ? projection : response)
                }
                return
            }
            if change?["op"]?.stringValue == "unset" {
                guard params["target"]?.objectValue?["sessionId"]?.stringValue == snapshot.sessionId,
                      change?["key"]?.stringValue == "model.thinking[role=chat]", change?["layer"]?.stringValue == "chat",
                      params["fence"]?.objectValue?["runtimeGeneration"]?.stringValue == snapshot.runtimeGeneration,
                      params["fence"]?.objectValue?["model"] == (try JSONValue.encode(snapshot.model)) else {
                    throw GatewayFailure(code: "invalid_request", message: "Expected a fenced Chat reset", retryable: false, details: nil)
                }
                if params["dryRun"]?.boolValue == true {
                    result = .object(["tier": .string("quiet"), "changes": .array([.object([:])])])
                } else {
                    snapshot.thinkingLevel = "high"
                    snapshot.revision += 1
                    snapshot.eventSequence += 1
                    decisions.append("reset:chat:\(snapshot.sessionId)")
                    try enqueue(.object(["type": .string("event"), "topic": .string("session.snapshot"),
                        "sessionId": .string(snapshot.sessionId), "payload": try JSONValue.encode(snapshot)]))
                    result = fixtureSettingsChangeResult(key: "model.thinking[role=chat]", revision: snapshot.revision)
                }
                break
            }
            guard change?["key"]?.stringValue == "model.thinking[role=chat]", change?["value"]?.stringValue == "high" else {
                throw GatewayFailure(code: "invalid_request", message: "Expected a real changed Thinking selection", retryable: false, details: nil)
            }
            snapshot.revision += 1
            pendingThinking = (id, snapshot.revision)
            return // Hold the original success while a second client supersedes it.
        case "settings.approvals":
            result = .object(["requests": .array(approvals)])
        case "settings.decide":
            let params = frame.objectValue?["params"]?.objectValue ?? [:]
            guard let requestID = params["requestId"]?.stringValue, let digest = params["digest"]?.stringValue,
                  let approved = params["approved"]?.boolValue,
                  let index = approvals.firstIndex(where: { $0.objectValue?["requestId"]?.stringValue == requestID && $0.objectValue?["digest"]?.stringValue == digest })
            else { throw GatewayFailure(code: "conflict", message: "Approval refused", retryable: false, details: nil) }
            approvals.remove(at: index)
            decisions.append("\(approved ? "approved" : "declined"):\(requestID)")
            result = .object(["requestId": .string(requestID), "approved": .bool(approved)])
        case "session.history.list":
            result = try JSONValue.encode(SessionHistoryPage(runtimeGeneration: snapshot.runtimeGeneration,
                nodes: [SessionTreeNode(id: "fixture-prompt", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                    kind: "message", label: bookmarkLabel, preview: "Nested history prompt", role: .user,
                    depth: 0, childCount: 0, isCurrentPath: true)], older: nil, newer: nil, totalEntries: 1))
        case "model.list": result = .object(["models": .array([])])
        case "provider.list": result = .object(["providers": .array([])])
        case "session.workspace.inspect": result = .object(["cwd": .string("/workspace"), "exists": .bool(true), "isGitRepository": .bool(false)])
        default: result = .object([:])
        }
        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }
    func releaseSettlement() throws {
        snapshot.configurationBlocker = .ready
        snapshot.eventSequence += 1
        try enqueue(.object(["type": .string("event"), "topic": .string("session.configuration"),
            "sessionId": .string(snapshot.sessionId), "payload": .object([
                "runtimeGeneration": .string(snapshot.runtimeGeneration), "revision": .number(Double(snapshot.revision)),
                "eventSequence": .number(Double(snapshot.eventSequence)), "data": .object(["configurationBlocker": .null])])]))
    }
    func completeSupersededThinking() throws -> Bool {
        guard let pendingThinking else { return false }
        self.pendingThinking = nil
        snapshot.revision += 1
        snapshot.eventSequence += 1
        snapshot.thinkingLevel = "off"
        try enqueue(.object(["type": .string("event"), "topic": .string("session.snapshot"),
            "sessionId": .string(snapshot.sessionId), "payload": try JSONValue.encode(snapshot)]))
        try enqueue(.object(["type": .string("response"), "id": .string(pendingThinking.id), "ok": .bool(true),
            "result": fixtureSettingsChangeResult(key: "model.thinking[role=chat]", revision: pendingThinking.revision)]))
        return true
    }
    /// Running, still locked, with only usage moving: each frame is a full
    /// `session.snapshot`, as the Gateway sends at tool boundaries.
    func streamRunningRebaselines() async {
        for step in 1...40 {
            guard !closed else { return }
            snapshot.eventSequence += 1
            snapshot.revision += 1
            snapshot.stats = SessionStats(userMessages: 1, assistantMessages: step, toolCalls: step, toolResults: step,
                totalMessages: 1 + 2 * step, tokens: .init(input: step * 1_000, output: step * 100, cacheRead: 0, cacheWrite: 0,
                total: step * 1_100), latestCacheHitRate: nil, cost: 0)
            try? enqueue(.object(["type": .string("event"), "topic": .string("session.snapshot"),
                "sessionId": .string(snapshot.sessionId), "payload": (try? JSONValue.encode(snapshot)) ?? .null]))
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func enqueue(_ frame: JSONValue) throws {
        let data = try JSONEncoder.gateway.encode(frame)
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { pending.append(data) }
    }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1","session-history-pages.v1"]}"#.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async {
        closed = true
        modelDelivery?.cancel()
        _ = await modelDelivery?.result
        modelDelivery = nil
        modelRequestContinuation.finish()
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}
#endif
