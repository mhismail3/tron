#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Real chat and media loader for out-of-process menu/status-bar gestures.
@MainActor
struct HostedChatDisplayFixture: View {
    static let imageTranscriptData = Data(#"""
        [
          {"id":"image-request","parentId":null,"presentationId":"image-request","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"image-call-content","ordinal":0,"type":"toolCall","toolCallId":"image-call","name":"display","arguments":{"presentation":{"surface":"inline"}}}]},
          {"id":"image-result","parentId":"image-request","presentationId":"image-result","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"image-result-text","ordinal":0,"type":"text","text":"Displayed Orientation Image."}],"toolCallId":"image-call","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"orientation-image","revision":1,"title":"Orientation Image","altText":"Red above blue, with the close badge at top right.","kind":"image","presentation":{"requestedSurface":"inline","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Orientation Image","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc40","name":"orientation.png","mimeType":"image/png","size":1024,"kind":"image"}}}
        ]
        """#.utf8)
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    private let profile: GatewayProfile
    private let snapshot: SessionSnapshot
    private let probe = ChatHostedProbe()

    init() {
        let defaults = UserDefaults(suiteName: "chat-display-fixture")!
        defaults.removePersistentDomain(forName: "chat-display-fixture")
        profile = GatewayProfile(id: "display-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        defaults.set(try! JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let socket = HostedChatDisplaySocket()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 80, width: 160, height: 80))
        }.pngData()!
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in socket }),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "chat-display-fixture")),
            chatMediaFetch: { _ in ChatMediaPayload(data: image, mimeType: "image/png") }
        ))
        var snapshot = SessionSnapshot(
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

        let history = (0..<30).map { index in
            ["id": "history-\(index)", "presentationId": "history-\(index)", "timestamp": "2026-01-01T00:00:00Z",
             "kind": "message", "role": "assistant", "content": [["id": "text-\(index)", "ordinal": 0,
             "type": "text", "text": index == 0 ? "Oldest loaded history" : "History row \(index). A bounded fixture paragraph for the reader."]]] as [String: Any]
        }
        snapshot.transcript = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: history))
        snapshot.transcript += try! JSONDecoder.gateway.decode([TranscriptItem].self, from: Self.imageTranscriptData)
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
        .preferredColorScheme(.dark)
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
    }
}

@MainActor
struct HostedHomeDashboardFixture: View {
    @State private var status: HomeStatusDTO?
    @State private var isDesignating = false
    @State private var route: String?
    private let capabilityEnabled: Bool
    private let darkAppearance: Bool
    private let accessibilityType: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        capabilityEnabled = !arguments.contains("-home-capability-absent")
        darkAppearance = arguments.contains("-home-dark")
        accessibilityType = arguments.contains("-home-accessibility-type")
        let phase: HomeStatusDTO.Phase = arguments.contains("-home-disabled") ? .disabled
            : arguments.contains("-home-missing-session") ? .missingSession
            : arguments.contains("-home-undesignated") ? .undesignated : .ready
        _status = State(initialValue: Self.status(phase: phase))
    }

    var body: some View {
        NavigationStack {
            List {
                if capabilityEnabled {
                    Section {
                        Button(action: activateHome) {
                            HomePinnedRow(status: status, isDesignating: isDesignating)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-pinned-row")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(SessionDashboardLayout.rowInsets)
                    }
                }
                Section {
                    Text("Ordinary session")
                        .accessibilityIdentifier("ordinary-session-row")
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sessions")
            .navigationDestination(isPresented: Binding(
                get: { route != nil },
                set: { if !$0 { route = nil } }
            )) {
                if let route {
                    Text("Profile route: \(route)")
                        .accessibilityIdentifier("home-exact-profile-route")
                }
            }
        }
        .preferredColorScheme(darkAppearance ? .dark : .light)
        .dynamicTypeSize(accessibilityType ? .accessibility3 : .large)
        .tronPresentation()
    }

    private func activateHome() {
        switch HomePinnedRowPolicy.action(for: status) {
        case .open(let sessionID): route = "home-fixture:\(sessionID)"
        case .designate:
            isDesignating = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                status = Self.status(phase: .ready)
                isDesignating = false
                if case .open(let sessionID) = HomePinnedRowPolicy.action(for: status) {
                    route = "home-fixture:\(sessionID)"
                }
            }
        case .unavailable:
            break
        }
    }

    private static func status(phase: HomeStatusDTO.Phase) -> HomeStatusDTO? {
        let sessionPresent = phase != .undesignated && phase != .missingSession
        let enabled = phase != .undesignated && phase != .disabled
        var value: [String: JSONValue] = [
            "phase": .string(phase.rawValue),
            "activation": .object(["available": .bool(false)]),
            "readiness": .object(["ready": .bool(phase == .ready), "gaps": .array([])]),
            "recovery": .object(["action": .string("none")]),
            "available": .bool(true), "enabled": .bool(enabled),
            "live": .bool(false), "sessionPresent": .bool(sessionPresent),
            "memory": .object(["configured": .bool(false), "open": .bool(false)]),
        ]
        if sessionPresent { value["sessionId"] = .string("home-current-session") }
        if enabled { value["homeId"] = .string("home-fixture-id") }
        value["generation"] = .number(1)
        return try? HomeStatusDTO.decode(.object(value))
    }
}

private actor HostedChatDisplaySocket: GatewaySocketConnection {
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    func resume() async { }
    func send(_ data: Data) async throws { }
    func ping() async throws { }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":7,"minProtocolVersion":7,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
        }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async {
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}
#endif
