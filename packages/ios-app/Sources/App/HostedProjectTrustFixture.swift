#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Directly mounted real Project Trust controls. Only the synthetic transport
/// delays replies; canonical fake decisions/events/reads remain independent.
struct HostedProjectTrustFixture: View {
    @Environment(\.scenePhase) private var phase
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var originalCounts = ""
    @State private var replacementCounts = ""
    private let originalGateway: ProjectTrustFixtureGateway
    private let replacementGateway: ProjectTrustFixtureGateway
    private let original = GatewayProfile(id: "trust-original", label: "Original fixture", host: "original.example.test", port: 9847, machineId: "trust-original-machine")
    private let replacement = GatewayProfile(id: "trust-replacement", label: "Replacement fixture", host: "replacement.example.test", port: 9847, machineId: "trust-replacement-machine")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-project-trust-scenario" }).dropFirst().first ?? "held"
        let gateway = ProjectTrustFixtureGateway(scenario: scenario, initialDecision: nil)
        let successor = ProjectTrustFixtureGateway(scenario: "ordered", initialDecision: false)
        originalGateway = gateway
        replacementGateway = successor
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(original, token: "fixture-only-token")
        try! profiles.save(replacement, token: "fixture-only-successor-token", selecting: false)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { request in
            let replacesAuthority = request.url?.host == "replacement.example.test"
            return ProjectTrustFixtureSocket(gateway: replacesAuthority ? successor : gateway,
                                             machineID: replacesAuthority ? "trust-replacement-machine" : "trust-original-machine")
        })
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "project-trust-fixture"))))
    }

    var body: some View {
        TronPresentationSurface(id: "fixture.project-trust") {
            VStack(spacing: 0) {
                if ready {
                    NavigationStack { TrustSettingsView(target: TrustTarget(cwd: "/fixture/project")) }
                        .tronSettingsLayout()
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
            do { try await model.connectHostedGateway(profile: original, token: "fixture-only-token"); ready = true }
            catch { self.error = error.localizedDescription }
        }
        .task { for await value in originalGateway.updates() { originalCounts = value } }
        .task { for await value in replacementGateway.updates() { replacementCounts = value } }
        .onChange(of: phase) { _, value in
            switch value {
            case .background: model.enteredBackground()
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
    }

    private var fixtureBar: some View {
        VStack(spacing: 4) {
            Text(originalCounts.components(separatedBy: " | ").first ?? originalCounts)
                .font(.caption2.monospaced()).lineLimit(3)
                .accessibilityIdentifier("fixture.trust-original").accessibilityValue(originalCounts)
            Text(replacementCounts.components(separatedBy: " | ").first ?? replacementCounts)
                .font(.caption2.monospaced()).lineLimit(3)
                .accessibilityIdentifier("fixture.trust-replacement").accessibilityValue(replacementCounts)
            Text("\(model.connectionState) profile:\(model.profiles.selected?.id ?? "none") trustRevision:\(model.trustRevision)")
                .font(.caption2).accessibilityIdentifier("fixture.trust-connection")
            Text(model.noticeCenter.notices.map { $0.title + " " + ($0.message ?? "") }.joined(separator: " | "))
                .font(.caption2).accessibilityIdentifier("fixture.trust-notices")
            HStack {
                Button("Release first reply") { Task { await originalGateway.releaseFirst() } }
                    .accessibilityIdentifier("fixture.release-trust")
                Button("Release reads") { Task { await originalGateway.releaseReads() } }
                    .accessibilityIdentifier("fixture.release-trust-reads")
                Button("Replace Mac") { Task { await model.switchGateway(replacement) } }
                    .accessibilityIdentifier("fixture.replace-trust-profile")
            }
            .buttonStyle(.bordered).font(.caption)
        }
        .padding(8)
    }
}

private actor ProjectTrustFixtureGateway {
    private let holdFirst: Bool
    private let holdTrueReads: Bool
    private let failHeldReads: Bool
    private var decision: Bool?
    private var sets = 0, repeats = 0, wrongCWD = 0, queries = 0
    private var readsTrue = 0, readsFalse = 0, held = 0, firstReply = 0
    private var receipts: [String: JSONValue] = [:]
    private var sockets: [ProjectTrustFixtureSocket] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var readContinuations: [CheckedContinuation<Void, Never>] = []
    private var heldReads = 0, releasedReads = 0
    private var streams: [AsyncStream<String>.Continuation] = []
    private var trace: [String] = []

    init(scenario: String, initialDecision: Bool?) {
        holdFirst = scenario == "held"
        holdTrueReads = scenario.hasPrefix("inspect-")
        failHeldReads = scenario == "inspect-error-held"
        decision = initialDecision
    }
    func attach(_ socket: ProjectTrustFixtureSocket) { sockets.append(socket) }
    nonisolated func updates() -> AsyncStream<String> { AsyncStream { c in Task { await self.add(c) } } }
    private func add(_ c: AsyncStream<String>.Continuation) { streams.append(c); publish() }
    private func record(_ value: String) { trace.append(value); if trace.count > 80 { trace.removeFirst() }; publish() }
    private func publish() {
        let counts = "sets:\(sets) commands:\(receipts.count) repeats:\(repeats) held:\(held) firstReply:\(firstReply) readsTrue:\(readsTrue) readsFalse:\(readsFalse) canonical:\(decision.map(String.init) ?? "nil") queries:\(queries) wrongCWD:\(wrongCWD) heldReads:\(heldReads) releasedReads:\(releasedReads)"
        streams.forEach { $0.yield(counts + " | " + trace.joined(separator: " > ")) }
    }
    private func inspection() -> JSONValue {
        .object(["cwd": .string("/fixture/project"), "requiresDecision": .bool(true),
                 "savedDecision": decision.map(JSONValue.bool) ?? .null,
                 "defaultDecision": .string("ask"), "effectiveDecision": decision.map(JSONValue.bool) ?? .null])
    }
    func releaseFirst() {
        guard let firstContinuation else { return }
        self.firstContinuation = nil
        record("release-first")
        firstContinuation.resume()
    }

    func releaseReads() {
        let waiting = readContinuations; readContinuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func handle(_ method: String, params: [String: JSONValue]) async -> (result: JSONValue?, error: JSONValue?) {
        switch method {
        case "trust.inspect":
            if params["cwd"] != .string("/fixture/project") { wrongCWD += 1 }
            if decision == true { readsTrue += 1 }
            if decision == false { readsFalse += 1 }
            let snapshot = inspection()
            record("inspect:\(decision.map(String.init) ?? "nil")")
            if holdTrueReads, decision == true {
                heldReads += 1
                await withCheckedContinuation { readContinuations.append($0); record("hold-inspect") }
                releasedReads += 1
                record("release-inspect")
                if failHeldReads {
                    return (nil, .object(["code": .string("fixture_old_read"), "message": .string("Earlier trust read failure"), "retryable": .bool(false)]))
                }
            }
            return (snapshot, nil)
        case "trust.set":
            sets += 1
            guard let commandID = params["commandId"]?.stringValue else { return (nil, nil) }
            if let receipt = receipts[commandID] { repeats += 1; record("repeat:\(commandID)"); return (receipt, nil) }
            if params["cwd"] != .string("/fixture/project") { wrongCWD += 1 }
            decision = params["decision"]?.boolValue
            let result = inspection()
            // The real TrustService mutex protects application/commit, not
            // network response delivery. No await separates these fake commits.
            receipts[commandID] = result
            let isFirst = receipts.count == 1
            record("commit:\(decision.map(String.init) ?? "nil"):\(commandID)")
            for socket in sockets { await socket.emitTrustChanged(result) }
            record("changed:\(decision.map(String.init) ?? "nil")")
            if isFirst, holdFirst {
                held += 1
                await withCheckedContinuation { firstContinuation = $0; record("hold-first") }
                firstReply += 1
                record("typed-first:true")
            } else {
                record("typed:\(params["decision"]?.boolValue.map(String.init) ?? "nil")")
            }
            return (result, nil)
        case "command.status":
            queries += 1
            let commandID = params["commandId"]?.stringValue ?? ""
            record("status:\(commandID)")
            if params["method"] == .string("trust.set"), let result = receipts[commandID] {
                return (.object(["status": .string("completed"), "result": result]), nil)
            }
            return (.object(["status": .string("missing")]), nil)
        case "session.list", "session.listUpdated": return (.object(["sessions": .array([])]), nil)
        case "system.metadata": return (.object([:]), nil)
        case "attention.list": return (.object(["items": .array([])]), nil)
        default: return (nil, nil)
        }
    }
}

private actor ProjectTrustFixtureSocket: GatewaySocketConnection {
    private let gateway: ProjectTrustFixtureGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: ProjectTrustFixtureGateway, machineID: String) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":7,\"minProtocolVersion\":7,\"machineId\":\"\(machineID)\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
        Task { await gateway.attach(self) }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"] == .string("request"), let id = frame["id"]?.stringValue,
              let method = frame["method"]?.stringValue else { return }
        // Independent request dispatch matches the transport. Holding a reply
        // must not hold the client's sender or the fake canonical mutation lane.
        Task {
            let reply = await gateway.handle(method, params: frame["params"]?.objectValue ?? [:])
            sendReply(id: id, reply: reply)
        }
    }
    private func sendReply(id: String, reply: (result: JSONValue?, error: JSONValue?)) {
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(reply.result != nil)]
        if let result = reply.result { response["result"] = result }
        else { response["error"] = reply.error ?? .object(["code": .string("fixture_unsupported"), "message": .string("Optional fixture read"), "retryable": .bool(false)]) }
        if let data = try? JSONEncoder.gateway.encode(JSONValue.object(response)) { deliver(data) }
    }
    func emitTrustChanged(_ inspection: JSONValue) {
        if let data = try? JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("event"), "topic": .string("trust.changed"), "payload": inspection])) { deliver(data) }
    }
    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }
    func close() async {
        closed = true
        let waiting = receivers; receivers.removeAll()
        waiting.forEach { $0.resume(throwing: CancellationError()) }
    }
    private func deliver(_ data: Data) {
        guard !closed else { return }
        if receivers.isEmpty { inbound.append(data) }
        else { receivers.removeFirst().resume(returning: data) }
    }
}
#endif
