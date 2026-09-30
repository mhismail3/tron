#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Real managed child sheet with canonical read-only RPCs; gestures come from XCUITest.
@MainActor
struct HostedSubagentSheetFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    private let profile: GatewayProfile
    private let snapshot: SessionSnapshot
    @State private var presented = false
    private let process = SessionProcessActivity(
        processId: "worker", kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
        lifecycle: .init(state: .completed, sequence: 1, observedAt: "2026-01-01T00:00:02Z",
                         terminalAt: "2026-01-01T00:00:02Z", recentUntil: "2026-01-01T00:05:02Z"),
        visibility: .historical, startedAt: "2026-01-01T00:00:00Z", title: "Scroll worker",
        durationMs: 2_000, toolCallId: "call-worker", runId: "run-worker"
    )

    init() {
        let defaults = UserDefaults(suiteName: "subagent-scroll-fixture")!
        defaults.removePersistentDomain(forName: "subagent-scroll-fixture")
        profile = GatewayProfile(id: "display-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        defaults.set(try! JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let socket = HostedSubagentSheetSocket()
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in socket }),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "subagent-scroll-fixture"))
        ))
        let snapshot = SessionSnapshot(
            sessionId: "display-fixture", runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: "Display fixture", cwd: "/workspace", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
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

        self.snapshot = snapshot
    }

    var body: some View {
        NavigationStack {
            if ready {
                Button("Open subagent transcript") { presented = true }
            } else if let error { Text(error) }
        }
        .tronManagedSheet(isPresented: $presented, identity: "subagent-scroll") {
            ReadOnlySubagentSessionSheet(parentSessionID: snapshot.sessionId, process: process)
        }
        .environment(model)
        .preferredColorScheme(.dark)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.invalidateHostedPendingPresentation()
                model.installHostedSubscribedSnapshot(snapshot)
                ready = true

            } catch { self.error = String(describing: error) }
        }
    }
}

private actor HostedSubagentSheetSocket: GatewaySocketConnection {
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    private var closed = false
    func resume() async { }
    func ping() async throws { }
    func send(_ data: Data) async throws {
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        guard let object = request.objectValue, let id = object["id"]?.stringValue,
              object["method"]?.stringValue == "session.processTranscript.open" else { return }
        let items: [JSONValue] = (0..<32).map { index in
            .object([
                "id": .string("entry-\(index)"), "parentId": index > 0 ? .string("entry-\(index - 1)") : .null,
                "timestamp": .string("2026-01-01T00:00:01Z"), "kind": .string("message"), "role": .string("assistant"),
                "content": .array([.object(["id": .string("text-\(index)"), "type": .string("text"),
                    "text": .string("Child history row \(index). A bounded paragraph for scrolling.")])])
            ])
        }
        let result: JSONValue = .object([
            "leaseId": object["params"]?.objectValue?["viewerId"] ?? .string("lease-worker"),
            "processId": .string("worker"), "childSessionRef": .string("child-worker"),
            "revision": .string("transcript-1"), "page": .object([
                "items": .array(items), "start": .number(0), "end": .number(32), "total": .number(32),
                "nextEntryId": .null, "leafEntryId": .string("entry-31")
            ])
        ])
        let response = try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result
        ]))
        if let receiver { self.receiver = nil; receiver.resume(returning: response) }
        else { pending.append(response) }
    }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":6,"minProtocolVersion":6,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1","process-transcript.v2"]}"#.utf8)
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
