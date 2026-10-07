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
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var homeStatusCount = 0
    private let profile = GatewayProfile(id: "home-shell-fixture", label: "Home fixture", host: "localhost", port: 9847, machineId: "home-shell-fixture")
    private let gateway: HostedHomeShellGateway
    private let homeActivity = PresentationActivityCoordinator()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let capabilityEnabled = !arguments.contains("-home-capability-absent")
        let initialState = arguments.first(where: { $0.hasPrefix("-home-shell-") })?.replacingOccurrences(of: "-home-shell-", with: "") ?? "undesignated"
        let gateway = HostedHomeShellGateway(capabilityEnabled: capabilityEnabled, initialState: initialState)
        self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(GatewayProfile(id: "home-shell-fixture", label: "Home fixture", host: "localhost", port: 9847, machineId: "home-shell-fixture"), token: "fixture-token")
        try! profiles.save(GatewayProfile(id: "competing-profile", label: "Other Mac", host: "other.example.test", port: 9847, machineId: "other-machine"), token: "other-fixture-token", selecting: false)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in HostedHomeShellSocket(gateway: gateway) })
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "home-shell-fixture"))))
    }

    var body: some View {
        Group {
            if ready {
                SessionShellView()
                    .environment(model)
                    .environment(\.tronPresentationActivityCoordinator, homeActivity)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .overlay(alignment: .top) {
                        VStack {
                            Text("home-status-count:\(homeStatusCount)")
                                .accessibilityIdentifier("fixture.home-status-count")
                            Text("home-diagnostics connected=\(model.connectionState) home-capable=\(model.homeStatus.isCapabilityEnabled) capabilities=\(String(describing: model.gatewayInfo?.capabilities)) home-phase=\(String(describing: model.homeStatus.status?.phase)) selected-profile=\(String(describing: model.profiles.selected?.id))")
                                .accessibilityIdentifier("fixture.home-diagnostics")
                        }
                        .font(.system(size: 1)).opacity(0.01)
                    }
            } else if let error {
                Text(error)
            } else {
                ProgressView()
            }
        }
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.sessions = [SessionSummary(id: "ordinary-session", name: "Ordinary session", cwd: "/workspace",
                    parentSessionId: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
                    messageCount: 0, firstMessage: "Ordinary session", phase: .idle, summaryRevision: 1,
                    gatewayProfileID: profile.id, gatewayProfileLabel: profile.label)]
                ready = true
            } catch { self.error = error.localizedDescription }
        }
        .task(id: ready) {
            guard ready else { return }
            while !Task.isCancelled {
                homeStatusCount = await gateway.statusCount()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}

@MainActor
struct HostedHomeRowAppearanceFixture: View {
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
            : arguments.contains("-home-undesignated") ? .undesignated
            : arguments.contains("-home-blocked") ? .blocked : .ready
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
        case .checkReceipt: break
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

private actor HostedHomeShellGateway {
    private let capabilityEnabled: Bool
    private let initialState: String
    private var designated: Bool
    private var homeStatusCount = 0
    init(capabilityEnabled: Bool, initialState: String) {
        self.capabilityEnabled = capabilityEnabled
        self.initialState = initialState
        designated = initialState == "ready"
    }
    func statusCount() -> Int { homeStatusCount }
    func capabilities() -> [String] { capabilityEnabled ? ["sessions.v1", "home.v1"] : ["sessions.v1"] }

    func handle(_ method: String, _ params: [String: JSONValue]) -> (JSONValue?, JSONValue?) {
        switch method {
        case "session.list":
            let row = SessionSummary(id: "ordinary-session", name: "Ordinary session", cwd: "/workspace", parentSessionId: nil,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z", messageCount: 0,
                firstMessage: "Ordinary session", phase: .idle, summaryRevision: 1)
            return (.object(["sessions": .array([try! JSONValue.encode(row)]), "nextCursor": .null,
                "listRevision": .number(1), "projectionToken": .string("home-shell-fixture:1"), "archivedCount": .number(0)]), nil)
        case "home.status":
            homeStatusCount += 1
            return (homeStatus(), nil)
        case "home.designate":
            designated = true
            return (.object(["homeId": .string("home-fixture"), "sessionId": .string("home-session"), "generation": .number(1)]), nil)
        case "session.open":
            let sessionID = params["sessionId"]?.stringValue ?? "home-session"
            let snapshot = SessionSnapshot(sessionId: sessionID, runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
                phase: .idle, name: sessionID == "home-session" ? "Home fixture chat" : "Ordinary session chat", cwd: "/workspace",
                parentSessionId: nil, model: nil, thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
                stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                    tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
                queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: nil,
                transcriptTotal: nil, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
                extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "fixture", revision: 1, capabilities: [], diagnostics: [],
                    semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                    surfaces: [], pendingInteractions: []), diagnostics: [])
            return (.object(["session": try! JSONValue.encode(snapshot), "syncToken": .string("fixture-sync"),
                "subscriptionToken": .string("fixture-subscription"), "completionRevision": .number(0)]), nil)
        case "session.sync": return (.object(["synchronized": .bool(true)]), nil)
        case "session.close": return (.object(["closed": .bool(true)]), nil)
        case "session.commands": return (.object(["commands": .array([])]), nil)
        case "session.attention.read": return (.object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)]), nil)
        default: return (nil, .object(["code": .string("not_found"), "message": .string("Not part of this fixture"), "retryable": .bool(false)]))
        }
    }

    private func homeStatus() -> JSONValue {
        let phase = designated ? "ready" : initialState == "disabled" ? "disabled"
            : initialState == "missing-session" ? "missing-session" : "undesignated"
        let sessionPresent = designated || initialState == "disabled"
        let enabled = designated || initialState == "missing-session"
        return .object(["phase": .string(phase),
            "activation": .object(["available": .bool(false)]),
            "readiness": .object(["ready": .bool(designated), "gaps": .array([])]),
            "recovery": .object(["action": .string(designated ? "none" : "designate")]),
            "available": .bool(true), "enabled": .bool(enabled),
            "homeId": designated || initialState == "disabled" || initialState == "missing-session" ? .string("home-fixture") : .null,
            "sessionId": sessionPresent ? .string("home-session") : .null,
            "generation": .number(1), "live": .bool(false), "sessionPresent": .bool(sessionPresent),
            "memory": .object(["configured": .bool(false), "open": .bool(false)])])
    }
}

private actor HostedHomeShellSocket: GatewaySocketConnection {
    private let gateway: HostedHomeShellGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: HostedHomeShellGateway) {
        self.gateway = gateway
        inbound = []
        Task {
            let caps = await gateway.capabilities()
            let data = try! JSONEncoder.gateway.encode(JSONValue.object(["type": .string("hello"), "gatewayVersion": .string("fixture"),
                "piVersion": .string("fixture"), "protocolVersion": .number(7), "minProtocolVersion": .number(7),
                "machineId": .string("home-shell-fixture"), "machineName": .string("Home fixture"),
                "gatewayChannel": .string("stable"), "capabilities": .array(caps.map(JSONValue.string))]))
            await deliver(data)
        }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue,
              let method = frame["method"]?.stringValue else { return }
        let result = await gateway.handle(method, frame["params"]?.objectValue ?? [:])
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(result.1 == nil)]
        if let body = result.0 { response["result"] = body }
        if let failure = result.1 { response["error"] = failure }
        await deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
    }
    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }
    func close() async { closed = true; let pending = receivers; receivers.removeAll(); pending.forEach { $0.resume(throwing: CancellationError()) } }
    private func deliver(_ data: Data) { if receivers.isEmpty { inbound.append(data) } else { receivers.removeFirst().resume(returning: data) } }
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
