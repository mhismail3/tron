#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// The real chat/composer and read-only child RPC path with bounded provider DTOs.
/// No provider execution or user store is involved in this presentation journey.
@MainActor
struct HostedSubagentParityFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    private let profile: GatewayProfile
    private let snapshot: SessionSnapshot
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let probe = ChatHostedProbe()

    init() {
        let defaults = UserDefaults(suiteName: "subagent-parity-fixture")!
        defaults.removePersistentDomain(forName: "subagent-parity-fixture")
        self.defaults = defaults
        profile = GatewayProfile(id: "parity", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        defaults.set(try! JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let socket = HostedSubagentParitySocket()
        cacheRoot = FileManager.default.temporaryDirectory.appending(path: "subagent-parity-\(UUID().uuidString)")
        _model = State(initialValue: AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { _ in socket }),
            profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: cacheRoot)))
        let historic = ProcessInfo.processInfo.arguments.contains("-historical")
        let owner: ExtensionOwner = try! JSONDecoder.gateway.decode(ExtensionOwner.self, from: Data("""
            {"id":"provider","title":"Subagents","source":"\(historic ? "npm:pi-subagents@0.59.0" : "tron:pi-subagents@fixture#build")","kind":"subagent"}
            """.utf8))
        let semantic = ExtensionSemanticState(statuses: ["provider": "PRIVATE PROVIDER STATUS"], statusOwners: ["provider": owner],
            working: .init(visible: false), widgets: [.init(key: "provider", lines: ["PI_SUBAGENT_ASYNC_JSON: PRIVATE"], placement: .aboveEditor, owner: owner)],
            toolsExpanded: false, editorRevision: 0, editorText: "")
        let startedAt = ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-10))
        let process = SessionProcessActivity(processId: "worker", kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
            lifecycle: .init(state: .running, sequence: 1, observedAt: startedAt), visibility: .active,
            startedAt: startedAt, title: "Worker", currentTool: "read", currentPathBasename: "parity.txt",
            model: "fixture/model", thinking: "medium", outputTail: "PARITY_CHILD_COMPLETE", toolCount: 2, turnCount: 1, toolCallId: "launch", runId: "run-worker")
        var snapshot = SessionSnapshot(sessionId: "parity", runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: historic ? "Historical subagents" : "Subagents", cwd: "/workspace", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: 0,
            transcriptTotal: 4, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
            processActivities: historic ? [] : [process],
            extensionPresentation: .init(version: 3, hostEpoch: "fixture-host", revision: 1, capabilities: [], diagnostics: [],
                semanticState: semantic, surfaces: try! JSONDecoder.gateway.decode([ExtensionSurface].self, from: Data(#"""
                    [{"id":"provider-frame","kind":"widget","placement":"aboveEditor","lifecycle":"retained","revision":1,"focused":false,"inputMode":"none","provenance":{"source":"tron:pi-subagents@fixture#build","kind":"subagent"},"frame":{"width":80,"height":1,"plainText":"PRIVATE PROVIDER FRAME","lines":[{"plainText":"PRIVATE PROVIDER FRAME","runs":[{"text":"PRIVATE PROVIDER FRAME","style":{}}]}]}}]
                    """#.utf8)), pendingInteractions: []), diagnostics: [])
        snapshot.transcript = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: Self.transcript)
        // Hold the wire projection before canonical binding to exercise the
        // two runtime-owned input lifetimes, not the canonical wake filter.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-pending-wake") || arguments.contains("-queued-wake") {
            let wake = snapshot.transcript.removeLast()
            let input: [String: JSONValue] = [
                "id": .string("wake"), "createdAt": .string(wake.timestamp),
                "text": .string("Subagent updates above."), "attachmentCount": .number(0),
                "behavior": arguments.contains("-pending-wake") ? .null : .string("steer"),
                "semantic": try! JSONValue.encode(wake.semantic!)
            ]
            let data = try! JSONEncoder.gateway.encode(JSONValue.object(input))
            snapshot.transcriptTotal = snapshot.transcript.count
            if arguments.contains("-pending-wake") {
                snapshot.phase = .compacting
                snapshot.pendingPrompt = try! JSONDecoder.gateway.decode(SessionSnapshot.PendingPrompt.self, from: data)
            } else {
                snapshot.phase = .running
                snapshot.queuedItems = [try! JSONDecoder.gateway.decode(SessionSnapshot.QueuedMessage.self, from: data)]
            }
        }
        if arguments.contains("-queued-maintainer") {
            snapshot.phase = .running
            snapshot.queuedItems.append(.init(id: "maintainer", behavior: .steer,
                text: "Maintainer queued message", attachmentCount: 0))
        }
        self.snapshot = snapshot
    }

    static let transcript = Data(#"""
    [
      {"id":"progress","parentId":null,"presentationId":"progress","timestamp":"2026-01-01T00:00:00Z","kind":"customMessage","customType":"subagent_supervisor_request","display":true,"details":{"reason":"progress_update"},"content":[{"id":"p","ordinal":0,"type":"text","text":"Worker has finished discovery."}],"semantic":{"version":1,"direction":"inboundContext","contextEffect":"modelInput","delivery":"stored","visibility":"visible","kind":"message","origin":{"kind":"subagent","title":"Subagents","confidence":"receipt"},"sequence":1}},
      {"id":"note","parentId":"progress","presentationId":"note","timestamp":"2026-01-01T00:00:01Z","kind":"customMessage","customType":"subagent-incremental-child-notify","display":true,"content":[{"id":"n","ordinal":0,"type":"text","text":"Reviewer child result: no blockers."}],"semantic":{"version":1,"direction":"inboundContext","contextEffect":"modelInput","delivery":"stored","visibility":"visible","kind":"message","origin":{"kind":"subagent","title":"Subagents","confidence":"receipt"},"sequence":2}},
      {"id":"decision","parentId":"note","presentationId":"decision","timestamp":"2026-01-01T00:00:02Z","kind":"customMessage","customType":"subagent_supervisor_request","display":true,"details":{"reason":"need_decision"},"content":[{"id":"d","ordinal":0,"type":"text","text":"May the worker proceed?"}],"semantic":{"version":1,"direction":"inboundContext","contextEffect":"modelInput","delivery":"triggeredTurn","visibility":"visible","kind":"message","origin":{"kind":"subagent","title":"Subagents","confidence":"receipt"},"sequence":3}},
      {"id":"wake","parentId":"decision","presentationId":"wake","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"w","ordinal":0,"type":"text","text":"Subagent updates above."}],"semantic":{"version":1,"direction":"hiddenInternal","contextEffect":"modelInput","delivery":"stored","visibility":"hidden","kind":"subagentWake","origin":{"kind":"subagent","title":"Subagents","confidence":"receipt"},"sequence":4}}
    ]
    """#.utf8)

    var body: some View {
        NavigationStack {
            if ready {
                if ProcessInfo.processInfo.arguments.contains("-resources") { ProjectResourcesView(sessionID: snapshot.sessionId) }
                else { ChatView(sessionID: snapshot.sessionId, hostedProbe: probe) }
            }
            else if let error { Text(error) }
        }
        .environment(model)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-light") ? .light : .dark)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.invalidateHostedPendingPresentation()
                model.installHostedSubscribedSnapshot(snapshot)
                probe.fixtureOpenPresentation = {
                    guard let target = model.presentationTarget(for: snapshot.sessionId) else { throw CancellationError() }
                    return target.generation
                }
                ready = true
            } catch { self.error = String(describing: error) }
        }
        .onDisappear {
            Task {
                await model.teardown()
                try? FileManager.default.removeItem(at: cacheRoot)
                defaults.removePersistentDomain(forName: "subagent-parity-fixture")
            }
        }
    }
}

private actor HostedSubagentParitySocket: GatewaySocketConnection {
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    func resume() async { }
    func ping() async throws { }
    func send(_ data: Data) async throws {
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let object = request.objectValue, let id = object["id"]?.stringValue,
              let method = object["method"]?.stringValue else { return }
        let result: JSONValue
        if method == "session.resources" {
            result = try JSONDecoder.gateway.decode(JSONValue.self, from: Data(#"""
            {"skills":{"skills":[{"name":"pi-subagents","description":"Technical guidance for operator-requested delegation","path":"/provider/skills/pi-subagents/SKILL.md","scope":"user","source":"tron:pi-subagents@fixture#build","distribution":"external"}],"diagnostics":[]},"prompts":{"prompts":[{"name":"council","description":"Run a bounded supervisor-mediated council of advisors and write a decision memo","argumentHint":"<question>","path":"/provider/prompts/council.md","scope":"user","source":"tron:pi-subagents@fixture#build","distribution":"external"}],"diagnostics":[]},"subagents":[{"name":"parity-worker","description":"Read-only parity child","model":"parity-child/child","source":"project","distribution":"local"}],"subagentDiagnostics":"1 invalid subagent definition(s): Agent 'parity-invalid.md' uses removed frontmatter field 'fallbackModels'. Configure one model instead.","commands":[]}
            """#.utf8))
        } else if method == "session.processTranscript.open" {
            result = .object([
            "leaseId": object["params"]?.objectValue?["viewerId"] ?? .string("lease-worker"),
            "processId": .string("worker"), "childSessionRef": .string("child-worker"), "revision": .string("child-1"),
            "page": .object(["items": .array([.object([
                "id": .string("child-entry"), "presentationId": .string("child-entry"), "parentId": .null,
                "timestamp": .string("2026-01-01T00:00:01Z"), "kind": .string("message"), "role": .string("assistant"),
                "content": .array([.object(["id": .string("child-text"), "ordinal": .number(0), "type": .string("text"), "text": .string("Child transcript reached through the native row.")])])
            ])]), "start": .number(0), "end": .number(1), "total": .number(1), "nextEntryId": .null, "leafEntryId": .string("child-entry")])
        ])
        } else { return }
        let response = try JSONEncoder.gateway.encode(JSONValue.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
        if let receiver { self.receiver = nil; receiver.resume(returning: response) }
        else { pending.append(response) }
    }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":7,"minProtocolVersion":7,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1","process-transcript.v2"]}"#.utf8)
        }
        if !pending.isEmpty { return pending.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { closed = true; pending.removeAll(); receiver?.resume(throwing: CancellationError()); receiver = nil }
}
#endif
