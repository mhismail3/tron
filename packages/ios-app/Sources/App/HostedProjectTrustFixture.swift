#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Directly mounted real Project Trust controls. Only the synthetic transport
/// delays replies; canonical fake decisions/events/reads remain independent.
struct HostedProjectTrustFixture: View {
    @Environment(\.scenePhase) private var phase
    @State private var model: AppModel
    @State private var presentationActivity = PresentationActivityCoordinator()
    @State private var ready = false
    @State private var error: String?
    @State private var originalCounts = ""
    @State private var replacementCounts = ""
    private let originalGateway: ProjectTrustFixtureGateway
    /// The `floors` scenario mounts Permissions › Floors instead of Project Trust.
    private let mountsFloors: Bool
    private let replacementGateway: ProjectTrustFixtureGateway
    private let original = GatewayProfile(id: "trust-original", label: "Original fixture", host: "original.example.test", port: 9847, machineId: "trust-original-machine")
    private let replacement = GatewayProfile(id: "trust-replacement", label: "Replacement fixture", host: "replacement.example.test", port: 9847, machineId: "trust-replacement-machine")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-project-trust-scenario" }).dropFirst().first ?? "held"
        let gateway = ProjectTrustFixtureGateway(scenario: scenario, initialDecision: nil)
        let successor = ProjectTrustFixtureGateway(scenario: "ordered", initialDecision: false)
        originalGateway = gateway
        mountsFloors = scenario == "floors"
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
                    if mountsFloors {
                        NavigationStack { SettingsRendererView(target: SettingsTarget.global.gatewayTarget, writeLayer: "mac", presentation: .section("permissions")) }
                            .tronSettingsLayout()
                    } else {
                        NavigationStack { TrustSettingsView(target: TrustTarget(cwd: "/fixture/project")) }
                            .tronSettingsLayout()
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
        .environment(\.tronPresentationActivityCoordinator, presentationActivity)
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
    /// The maintainer's override; nil is the code floor (approve).
    private var floorOverride: String?
    private var floor: String { floorOverride ?? "approve" }
    private var floorPreviews = 0, floorApplies = 0

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
        let counts = "sets:\(sets) commands:\(receipts.count) repeats:\(repeats) held:\(held) firstReply:\(firstReply) readsTrue:\(readsTrue) readsFalse:\(readsFalse) canonical:\(decision.map(String.init) ?? "nil") queries:\(queries) wrongCWD:\(wrongCWD) heldReads:\(heldReads) releasedReads:\(releasedReads) floor:\(floor) previews:\(floorPreviews) applies:\(floorApplies)"
        streams.forEach { $0.yield(counts + " | " + trace.joined(separator: " > ")) }
    }
    private func inspection() -> JSONValue {
        // A chat in a subdirectory: the Gateway records the decision for its Project root.
        .object(["cwd": .string("/fixture/project"), "projectDir": .string("/fixture"), "requiresDecision": .bool(true),
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

    private func floorRow() -> JSONValue {
        let labels = ["quiet": "Quiet", "notify": "Notify", "approve": "Approve"]
        return .object(["key": .string("permissions.floor"),
            "qualifiers": .object(["direction": .string("widen"), "key": .string("permissions.projectTrust")]),
            "group": .string("permissions"), "subgroup": .null, "value": .string(floor),
            "display": .string(labels[floor] ?? floor), "layer": .string(floorOverride == nil ? "builtin" : "mac"), "applied": .bool(true),
            "layers": .array([.object(["layer": .string("mac")])]),
            "badges": .array([.object(["kind": .string("layer"), "label": .string(floorOverride == nil ? "Built-in" : "Mac")]),
                              .object(["kind": .string("scope"), "label": .string("Project trust: loosening")])]),
            "presentation": .object(["label": .string("Project trust: loosening"),
                "help": .string("Lowering this floor requires your confirmation."), "order": .number(10), "importance": .string("advanced"),
                "control": .string("choice"), "valueKind": .string("orderedChoice"), "options": .array(["quiet", "notify", "approve"].map { tier in
                    .object(["value": .string(tier), "label": .string(labels[tier]!)])
                })])])
    }

    /// Lowering a floor is an approve-tier change carrying confirm text; raising
    /// it applies at quiet tier. A dry run only previews, so the count shows it.
    private func applyFloor(_ params: [String: JSONValue], _ change: [String: JSONValue]) -> (JSONValue?, JSONValue?) {
        let rank = ["quiet": 0, "notify": 1, "approve": 2]
        guard change["op"]?.stringValue == "set", let target = change["value"]?.stringValue, let targetRank = rank[target] else {
            return (nil, .object(["code": .string("fixture_unsupported"), "message": .string("Floor fixture supports set only"), "retryable": .bool(false)]))
        }
        let lowering = targetRank < (rank[floor] ?? 2)
        if params["dryRun"]?.boolValue == true {
            floorPreviews += 1
            record("floor-preview:\(target)")
            let tier = lowering ? "approve" : "quiet"
            let confirm: JSONValue = lowering ? .string("Lowering this floor lets agents' project-trust changes apply without your tap.") : .null
            return (.object(["tier": .string(tier), "changes": .array([.object(["changeId": .string("floor-change"), "tier": .string(tier), "confirm": confirm])])]), nil)
        }
        floorApplies += 1
        floorOverride = target
        record("floor-apply:\(target)")
        return (fixtureSettingsChangeResult(key: "permissions.floor"), nil)
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
        case "settings.resolve":
            return (.object(["keys": .array([floorRow()])]), nil)
        case "settings.change":
            if let floorChange = params["changes"]?.arrayValue?.first?.objectValue, floorChange["key"]?.stringValue == "permissions.floor" {
                return applyFloor(params, floorChange)
            }
            let change = fixtureTrustChange(params)
            guard change.isTrust else { return (nil, nil) }
            sets += 1
            guard let commandID = params["commandId"]?.stringValue else { return (nil, nil) }
            if let receipt = receipts[commandID] { repeats += 1; record("repeat:\(commandID)"); return (receipt, nil) }
            if change.cwd != .string("/fixture/project") { wrongCWD += 1 }
            decision = change.decision
            let canonical = inspection()
            let result = fixtureSettingsChangeResult(key: "permissions.projectTrust", result: canonical)
            // The real TrustService mutex protects application/commit, not
            // network response delivery. No await separates these fake commits.
            receipts[commandID] = result
            let isFirst = receipts.count == 1
            record("commit:\(decision.map(String.init) ?? "nil"):\(commandID)")
            for socket in sockets { await socket.emitTrustChanged(canonical) }
            record("changed:\(decision.map(String.init) ?? "nil")")
            if isFirst, holdFirst {
                held += 1
                await withCheckedContinuation { firstContinuation = $0; record("hold-first") }
                firstReply += 1
                record("typed-first:true")
            } else {
                record("typed:\(change.decision.map(String.init) ?? "nil")")
            }
            return (result, nil)
        case "command.status":
            queries += 1
            let commandID = params["commandId"]?.stringValue ?? ""
            record("status:\(commandID)")
            if params["method"] == .string("settings.change"), let result = receipts[commandID] {
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
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"\(machineID)\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
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

/// Reads a fixture `settings.change` that changes project trust.
func fixtureTrustChange(_ params: [String: JSONValue]) -> (cwd: JSONValue?, decision: Bool?, isTrust: Bool) {
    let change = params["changes"]?.arrayValue?.first?.objectValue
    let isTrust = change?["key"]?.stringValue == "permissions.projectTrust"
    return (params["target"]?.objectValue?["cwd"], change?["op"]?.stringValue == "set" ? change?["value"]?.boolValue : nil, isTrust)
}

/// A fixture `settings.change` outcome for one applied change.
func fixtureSettingsChangeResult(key: String, result: JSONValue? = nil, revision: Int? = nil) -> JSONValue {
    var change: [String: JSONValue] = ["changeId": .string("fixture-change"), "key": .string(key), "status": .string("applied"), "tier": .string("quiet")]
    if let result { change["result"] = result }
    if let revision { change["revision"] = .number(Double(revision)) }
    return .object(["status": .string("applied"), "changes": .array([.object(change)])])
}

#endif
