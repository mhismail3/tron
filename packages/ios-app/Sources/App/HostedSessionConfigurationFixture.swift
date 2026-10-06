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
    @State private var error: String?
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
        socket = HostedSessionConfigurationSocket(snapshot: snapshot)
        _model = State(initialValue: AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { [socket] _ in socket }),
            profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "session-configuration-fixture"))))
    }

    var body: some View {
        NavigationStack {
            if ready {
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
                    }.padding()
                }
        }
        .environment(model)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("dark") ? .dark : .light)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.invalidateHostedPendingPresentation()
                model.installHostedSubscribedSnapshot(snapshot)
                let catalog = try JSONDecoder.gateway.decode([ModelSummary].self, from: Data(#"[{"provider":"fixture","id":"model","name":"Fixture Model","reasoning":true,"input":["text"],"contextWindow":200000,"maxTokens":32000,"available":true,"releaseDate":"2026-01-01"},{"provider":"fixture","id":"alternative","name":"Alternative Model","reasoning":true,"input":["text"],"contextWindow":200000,"maxTokens":32000,"available":true,"releaseDate":"2026-01-02"}]"#.utf8))
                model.installHostedProviderCatalog(ProviderCatalog(providers: [], models: catalog), for: .session(id: snapshot.sessionId))
                ready = true
            } catch { self.error = String(describing: error) }
        }
    }
}

private actor HostedSessionConfigurationSocket: GatewaySocketConnection {
    private var snapshot: SessionSnapshot
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    private var pendingThinking: (id: String, revision: Int)?
    init(snapshot: SessionSnapshot) { self.snapshot = snapshot }
    func resume() async { }
    func ping() async throws { }
    func send(_ data: Data) async throws {
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let id = frame.objectValue?["id"]?.stringValue, let method = frame.objectValue?["method"]?.stringValue else { return }
        let result: JSONValue
        switch method {
        case "session.abort":
            snapshot.phase = .idle
            snapshot.configurationBlocker = .settling
            snapshot.eventSequence += 1
            snapshot.revision += 1
            try enqueue(.object(["type": .string("event"), "topic": .string("session.snapshot"),
                "sessionId": .string(snapshot.sessionId), "payload": try JSONValue.encode(snapshot)]))
            result = .object(["aborted": .bool(true)])
        case "session.setThinking":
            guard frame.objectValue?["params"]?.objectValue?["level"]?.stringValue == "high" else {
                throw GatewayFailure(code: "invalid_request", message: "Expected a real changed Thinking selection", retryable: false, details: nil)
            }
            snapshot.revision += 1
            pendingThinking = (id, snapshot.revision)
            return // Hold the original success while a second client supersedes it.
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
            "result": .object(["updated": .bool(true), "revision": .number(Double(pendingThinking.revision))])]))
        return true
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
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":7,"minProtocolVersion":7,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async {
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}
#endif
