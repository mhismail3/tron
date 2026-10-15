#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Real ChatView over a fixture socket for the annotate journey: a completed
/// Markdown assistant response to select from, and a `session.prompt` handler
/// that records the exact transport text the model would receive.
@MainActor
struct HostedChatAnnotationFixture: View {
    static let transcriptData = Data(#"""
        [
          {"id":"ask","parentId":null,"presentationId":"ask","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"ask-text","ordinal":0,"type":"text","text":"How should the gateway retry dropped connections?"}]},
          {"id":"answer","parentId":"ask","presentationId":"answer","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"answer-text","ordinal":0,"type":"text","text":"## Retry policy\n\nThe gateway should retry dropped connections with **exponential backoff**, starting at one second and capping at thirty seconds. Each attempt adds jitter so many phones do not reconnect at once.\n\nKeep the session open while retrying:\n\n- Accepted prompts continue on the Mac.\n- The phone receives an authoritative snapshot when it returns.\n\nSee the [reconnect notes](https://example.com/reconnect) for the full contract."}],"provider":"anthropic","modelId":"claude-opus-5-5"}
        ]
        """#.utf8)

    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var lastPrompt = "none"
    private let profile: GatewayProfile
    private let snapshot: SessionSnapshot
    private let socket = HostedChatAnnotationSocket()
    private let probe = ChatHostedProbe()
    private let dark = !ProcessInfo.processInfo.arguments.contains("-annotation-light")

    init() {
        let defaults = UserDefaults(suiteName: "chat-annotation-fixture")!
        defaults.removePersistentDomain(forName: "chat-annotation-fixture")
        profile = GatewayProfile(id: "annotation-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        defaults.set(try! JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let socket = socket
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in socket }),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "chat-annotation-fixture"))
        ))
        var snapshot = SessionSnapshot(
            sessionId: "annotation-fixture", runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: "Annotation fixture", cwd: "/workspace", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 1, assistantMessages: 1, toolCalls: 0, toolResults: 0, totalMessages: 2,
                               tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: nil,
            transcriptTotal: nil, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(
                version: 3, hostEpoch: "fixture-host", revision: 1, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil,
                                     widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: []
            ), diagnostics: []
        )
        snapshot.transcript = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: Self.transcriptData)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        self.snapshot = snapshot
    }

    var body: some View {
        NavigationStack {
            if ready {
                ChatView(sessionID: snapshot.sessionId, hostedProbe: probe)
            } else if let error { Text(error) }
        }
        .environment(model)
        .preferredColorScheme(dark ? .dark : .light)
        .tronPresentation()
        .overlay(alignment: .topLeading) {
            // The exact transport text, for the journey's assertion only.
            Text(lastPrompt)
                .font(.system(size: 1)).opacity(0.01)
                .accessibilityIdentifier("fixture.last-prompt")
                .allowsHitTesting(false)
        }
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.invalidateHostedPendingPresentation()
                model.installHostedSubscribedSnapshot(snapshot)
                let sessionID = snapshot.sessionId
                probe.fixtureOpenPresentation = {
                    guard let target = model.presentationTarget(for: sessionID) else { throw CancellationError() }
                    return target.generation
                }
                ready = true
            } catch { self.error = String(describing: error) }
        }
        .task(id: ready) {
            guard ready else { return }
            while !Task.isCancelled {
                lastPrompt = await socket.lastPrompt ?? "none"
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}

private actor HostedChatAnnotationSocket: GatewaySocketConnection {
    private var hello = true
    private var pending: [Data] = []
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    private(set) var lastPrompt: String?

    func resume() async { }
    func ping() async throws { }

    func send(_ data: Data) async throws {
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let object = request.objectValue, let id = object["id"]?.stringValue,
              object["method"]?.stringValue == "session.prompt" else { return }
        lastPrompt = object["params"]?.objectValue?["text"]?.stringValue
        deliver(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true),
            "result": .object(["operationId": .string("annotation-operation")]),
        ])))
    }

    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }

    func close() async {
        closed = true
        pending.removeAll()
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }

    private func deliver(_ data: Data) {
        if let receiver { self.receiver = nil; receiver.resume(returning: data) }
        else { pending.append(data) }
    }
}
#endif
