#if HOSTED_TEST
import SwiftUI
import TronMobileCore
import UniformTypeIdentifiers

/// The real chat route, composer and attachment strip over a scripted Gateway,
/// so journeys read which haptic each live event played (`TronHapticsProbe`).
/// Prompts script the run: `fail` is rejected, one containing `slow` runs until
/// Stop, `away` settles three seconds later, anything else replies at once. Fixture buttons
/// deliver a worker result or an `ask_user` question as live snapshots;
/// `-chat-haptics-history` opens a chat whose history already holds each event.
struct HostedChatHapticsFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var ready = false
    @State private var chatOpening = 0
    @State private var status = "starting"
    private let gateway: ChatHapticsGateway
    private let profile = GatewayProfile(id: "chat-haptics", label: "Haptics fixture", host: "haptics.example.test", port: 9847, machineId: "haptics-machine")

    init() {
        let args = ProcessInfo.processInfo.arguments
        let gateway = ChatHapticsGateway(history: args.contains("-chat-haptics-history"))
        self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-only-token")
        let root = FileManager.default.temporaryDirectory.appending(path: "chat-haptics-fixture-\(UUID().uuidString)")
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in ChatHapticsSocket(gateway: gateway) }),
            profiles: profiles,
            cache: SnapshotCache(root: root.appending(path: "cache")),
            composerUpload: { _, _, _ in UUID().uuidString.lowercased() },
            composerDraftStore: ComposerDraftStore(root: root.appending(path: "drafts"))
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ready { ChatView(sessionID: ChatHapticsGateway.sessionID).id(chatOpening) }
                HStack {
                    Button("Reopen chat") { chatOpening += 1 }.accessibilityIdentifier("fixture.reopen-chat")
                    if HostedChatErrorScenarioFixture.enabled {
                        Button("Live error") { Task { await gateway.liveError() } }
                        Button("Settle error") { Task { await gateway.settleError() } }
                        Button("Mixed error") { Task { await gateway.providerError(mixed: true) } }
                        Button("Delayed error") { Task { await gateway.delayedError() } }
                        Button("Continue boundary") { Task { await gateway.errorBoundary() } }
                    } else {
                        Button("Deliver worker") { Task { await gateway.deliverWorkerResult() } }
                            .accessibilityIdentifier("fixture.deliver-worker")
                        Button("Ask question") { Task { await gateway.ask() } }.accessibilityIdentifier("fixture.ask-question")
                    }
                }
                Text("haptics:\(TronHapticsProbe.shared.summary)").accessibilityIdentifier("fixture.haptics")
                Text(status).accessibilityIdentifier("fixture.gateway")
            }
            .font(.caption2)
        }
        .environment(model)
        .tronPresentation()
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-error-style-preview")
            ? (ProcessInfo.processInfo.arguments.contains("-error-preview-dark") ? .dark : .light) : nil)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.enteredBackground()
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
        .task { for await value in gateway.updates() { status = value } }
        .task {
            let count = ProcessInfo.processInfo.arguments.drop(while: { $0 != "-chat-haptics-photos" }).dropFirst().first.flatMap(Int.init) ?? 4
            UIPasteboard.general.setItems((0..<count).map { _ in [UTType.png.identifier: ChatHapticsGateway.photo] })
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-only-token")
                ready = true
            } catch { status = "fixture-error:\(error.localizedDescription)" }
        }
    }
}

private actor ChatHapticsGateway {
    static let sessionID = "haptics-session"
    @MainActor static let photo: Data = {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }.pngData()!
    }()
    private static let owner = ExtensionOwner(id: "tron-ask-user", title: "Ask User", source: AskUserToolPresentation.tronSource)
    private static let question = ExtensionInteraction(
        id: "haptics-question", hostEpoch: "haptics-host", presentationRevision: 1, method: .form, title: "Deploy target",
        form: ExtensionFormDescriptor(version: 1, title: "Deploy target", questions: [ExtensionFormQuestion(
            id: "environment", question: "Which environment?",
            options: [ExtensionFormOption(id: "staging", label: "Staging", description: nil),
                      ExtensionFormOption(id: "production", label: "Production", description: nil)],
            multiSelect: false, allowOther: false)], allowCancel: true),
        owner: owner, invocationId: "haptics-question-invocation", operationId: "haptics-question-operation")

    private var phase: SessionPhase = .idle
    private var transcript: [JSONValue] = []
    private var errorStream: JSONValue?
    private var pending: [ExtensionInteraction] = []
    private var sequence = 1
    private var entries = 0
    private var opens = 0
    private var prompts = 0
    private var rejected = 0
    private var aborts = 0
    private var lastPrompt = ""
    private var socket: ChatHapticsSocket?
    private var continuations: [AsyncStream<String>.Continuation] = []

    init(history: Bool) {
        if HostedChatErrorScenarioFixture.enabled {
            transcript = [HostedChatErrorScenarioFixture.error("error-first")]
            return
        }
        guard history else { return }
        // Each event already happened before this chat opened.
        transcript = [Self.message("history-1", "user", "Earlier prompt"),
                      Self.message("history-2", "assistant", "Earlier reply", stopReason: "stop"),
                      Self.workerResult("history-3"), Self.message("history-4", "user", "Later prompt")]
            + Self.answeredQuestion("history-5")
        pending = [Self.question]
    }

    nonisolated func updates() -> AsyncStream<String> {
        AsyncStream { continuation in Task { await self.add(continuation) } }
    }
    private func add(_ continuation: AsyncStream<String>.Continuation) { continuations.append(continuation); publish() }
    private func publish() {
        let value = "opens:\(opens) prompts:\(prompts) rejected:\(rejected) aborts:\(aborts) phase:\(phase.rawValue) last:\(lastPrompt)"
        continuations.forEach { $0.yield(value) }
    }

    func connect(_ socket: ChatHapticsSocket) { self.socket = socket }

    func handle(_ method: String, params: [String: JSONValue]) -> Result<JSONValue, GatewayFailure>? {
        switch method {
        case "session.open":
            opens += 1
            publish()
            return .success(.object(["session": try! JSONValue.encode(snapshot()), "syncToken": .string("haptics-sync-\(opens)"),
                                     "subscriptionToken": .string("haptics-subscription-\(opens)"), "completionRevision": .number(0)]))
        case "session.sync": return .success(.object(["synchronized": .bool(true)]))
        case "session.close": return .success(.object(["closed": .bool(true)]))
        case "session.commands": return .success(.object(["commands": .array([])]))
        case "session.attention.read": return .success(.object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)]))
        case "session.list": return .success(.object(["sessions": .array([])]))
        case "session.prompt":
            // The keyboard may capitalize the scripted word.
            let text = params["text"]?.stringValue?.lowercased() ?? ""
            lastPrompt = text
            guard text != "fail" else {
                rejected += 1
                publish()
                return .failure(GatewayFailure(code: "rejected", message: "The fixture rejects this prompt", retryable: false, details: nil))
            }
            prompts += 1
            publish()
            let operationID = "haptics-operation-\(prompts)"
            Task { await run(text, operationID: operationID) }
            return .success(.object(["operationId": .string(operationID)]))
        case "session.abort":
            aborts += 1
            if phase == .running { Task { await settle(stopReason: "aborted") } }
            return .success(.object(["aborted": .bool(true)]))
        case "extension.respond":
            Task { await answer() }
            return .success(.object(["answered": .bool(true)]))
        default: return nil
        }
    }

    func liveError() async {
        errorStream = HostedChatErrorScenarioFixture.error("error-live")
        await deliver()
    }
    func settleError() async {
        if let errorStream { transcript.append(errorStream) }
        errorStream = nil
        await deliver()
    }
    func providerError(mixed: Bool) async {
        transcript.append(HostedChatErrorScenarioFixture.error(nextID("error"), mixed: mixed))
        await deliver()
    }
    func delayedError() async {
        try? await Task.sleep(for: .seconds(3))
        await providerError(mixed: false)
    }
    func errorBoundary() async {
        transcript.append(Self.message(nextID("user"), "user", "Continue"))
        await providerError(mixed: false)
    }

    func deliverWorkerResult() async {
        transcript.append(Self.workerResult(nextID("worker")))
        await deliver()
    }

    func ask() async {
        pending = [Self.question]
        await deliver()
    }

    private func answer() async {
        try? await Task.sleep(for: .milliseconds(100))
        pending = []
        transcript += Self.answeredQuestion(nextID("asked"))
        await deliver()
    }

    /// The canonical prompt carries its operation as its presentation ID, the
    /// receipt the composer resolves its outgoing row by.
    private func run(_ text: String, operationID: String) async {
        try? await Task.sleep(for: .milliseconds(150))
        transcript.append(Self.message(nextID("user"), "user", text, presentationID: operationID))
        phase = .running
        await deliver()
        if text.contains("slow") { return }
        try? await Task.sleep(for: text == "away" ? .seconds(3) : .milliseconds(500))
        await settle(stopReason: "stop")
    }

    private func settle(stopReason: String) async {
        guard phase == .running else { return }
        transcript.append(Self.message(nextID("assistant"), "assistant", stopReason == "stop" ? "Done." : "Stopped.", stopReason: stopReason))
        phase = .idle
        await deliver()
    }

    /// A live `session.snapshot`, as the Gateway sends the open session; a
    /// closed (backgrounded) connection loses it like a suspended app would.
    private func deliver() async {
        sequence += 1
        publish()
        let snapshot = snapshot()
        let event = try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("event"), "topic": .string("session.snapshot"), "sessionId": .string(Self.sessionID),
            "payload": try! JSONValue.encode(snapshot)]))
        await socket?.deliver(event)
    }

    private func snapshot() -> SessionSnapshot {
        let items = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONEncoder.gateway.encode(transcript))
        return SessionSnapshot(
            sessionId: Self.sessionID, runtimeGeneration: "haptics-runtime", revision: sequence, eventSequence: sequence,
            phase: phase, name: "Haptics fixture", cwd: "/fixture", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: items, transcriptStart: 0,
            transcriptTotal: items.count,
            streaming: errorStream.map { try! JSONDecoder.gateway.decode(TranscriptItem.self, from: JSONEncoder.gateway.encode($0)) }, leafEntryId: nil,
            operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "haptics-host", revision: sequence, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: pending),
            diagnostics: [])
    }

    private func nextID(_ prefix: String) -> String {
        entries += 1
        return "\(prefix)-\(entries)"
    }

    private static func message(_ id: String, _ role: String, _ text: String, stopReason: String? = nil, presentationID: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "presentationId": .string(presentationID ?? id), "timestamp": .string("2026-01-01T00:00:00Z"),
            "kind": .string("message"), "role": .string(role),
            "content": .array([.object(["id": .string("\(id)-text"), "ordinal": .number(0), "type": .string("text"), "text": .string(text)])])]
        if let stopReason { object["stopReason"] = .string(stopReason) }
        return .object(object)
    }

    private static func workerResult(_ id: String) -> JSONValue {
        return .object(["id": .string(id), "timestamp": .string("2026-01-01T00:00:00Z"), "kind": .string("customMessage"),
            "customType": .string("tron.home-task-result.v1"), "display": .bool(true),
            "content": .array([.object(["id": .string("\(id)-text"), "ordinal": .number(0), "type": .string("text"), "text": .string("Home task: Tidy docs | outcome: final")])]),
            "details": .object(["taskId": .string(id), "taskTitle": .string("Tidy docs"), "terminalEvidence": .object(["outcome": .string("final")])]),
            "semantic": .object(["version": .number(1), "sequence": .number(1), "direction": .string("inboundContext"),
                "contextEffect": .string("modelInput"), "delivery": .string("stored"), "visibility": .string("visible"), "kind": .string("message"),
                "origin": .object(["kind": .string("extension"), "title": .string("Home task"), "confidence": .string("receipt")])])])
    }

    /// A settled `ask_user` call and its canonical result: the read-only row.
    private static func answeredQuestion(_ id: String) -> [JSONValue] {
        let origin: JSONValue = .object(["source": .string(AskUserToolPresentation.tronSource), "owner": .object([
            "id": .string("tron-ask-user"), "title": .string("Ask User"), "source": .string(AskUserToolPresentation.tronSource)])])
        let questions: JSONValue = .array([.object(["question": .string("Which environment?"),
            "options": .array([.object(["label": .string("Staging")]), .object(["label": .string("Production")])])])])
        return [
            .object(["id": .string("\(id)-call"), "presentationId": .string("\(id)-call"), "timestamp": .string("2026-01-01T00:00:00Z"),
                "kind": .string("message"), "role": .string("assistant"), "stopReason": .string("toolUse"),
                "content": .array([.object(["id": .string("\(id)-content"), "ordinal": .number(0), "type": .string("toolCall"),
                    "toolCallId": .string(id), "name": .string("ask_user"), "arguments": .object(["questions": questions])])])]),
            .object(["id": .string("\(id)-result"), "presentationId": .string("\(id)-result"), "timestamp": .string("2026-01-01T00:00:00Z"),
                "kind": .string("message"), "role": .string("toolResult"), "toolCallId": .string(id), "toolName": .string("ask_user"),
                "toolLabel": .string("Ask User"), "isError": .bool(false), "extensionOrigin": origin,
                "content": .array([.object(["id": .string("\(id)-text"), "ordinal": .number(0), "type": .string("text"), "text": .string("Cancelled")])]),
                "details": .object(["title": .string("Deploy target"), "questions": questions, "answers": .object([:]), "cancelled": .bool(true)])]),
        ]
    }
}

private actor ChatHapticsSocket: GatewaySocketConnection {
    private let gateway: ChatHapticsGateway
    private var inbound: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    init(gateway: ChatHapticsGateway) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"haptics-machine\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        await gateway.connect(self)
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { return }
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id)]
        switch await gateway.handle(method, params: request["params"]?.objectValue ?? [:]) {
        case .success(let result)?:
            response["ok"] = .bool(true); response["result"] = result
        case .failure(let failure)?:
            response["ok"] = .bool(false)
            response["error"] = .object(["code": .string(failure.code), "message": .string(failure.message), "retryable": .bool(failure.retryable)])
        case nil:
            response["ok"] = .bool(false)
            response["error"] = .object(["code": .string("fixture_unsupported"), "message": .string("Optional fixture read"), "retryable": .bool(false)])
        }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
    }
    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
    func deliver(_ data: Data) {
        guard !closed else { return }
        if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { inbound.append(data) }
    }
}
#endif
