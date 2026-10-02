#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Real sheet/child controls and accepted create consumer; only transport and
/// the precise typed-result boundary are held. No production lifecycle hooks.
struct HostedNewSessionFixture: View {
    @Environment(\.scenePhase) private var phase
    @State private var activity = PresentationActivityCoordinator()
    @State private var model: AppModel
    @State private var ready = false
    @State private var showing = true
    @State private var counts = "creates:0 typed:0"
    @State private var trustCounts = "trusts:0 successor:0 fallback:false held:0 released:0 acceptedHeld:0"
    @State private var callbacks = 0
    @State private var owned = false
    private let gateway: NewSessionFixtureGateway
    private let scenario: String
    private let original = GatewayProfile(id: "new-session-original", label: "Original fixture", host: "original.example.test", port: 9847, machineId: "new-session-machine")
    private let replacement = GatewayProfile(id: "new-session-replacement", label: "Replacement fixture", host: "replacement.example.test", port: 9847, machineId: "new-session-replacement-machine")

    init() {
        let args = ProcessInfo.processInfo.arguments
        let scenario = args.drop(while: { $0 != "-new-session-scenario" }).dropFirst().first ?? "draft"
        self.scenario = scenario
        let gateway = NewSessionFixtureGateway(scenario: scenario); self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(original, token: "fixture-only-token")
        try! profiles.save(replacement, token: "fixture-only-replacement-token", selecting: false)
        let model = AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { request in
            NewSessionFixtureSocket(gateway: gateway, replacement: request.url?.host == "replacement.example.test")
        }), profiles: profiles, cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "new-session-fixture")))
        model.defaultWorkspace = "/fixture/original"
        if scenario.hasPrefix("accepted") {
            model.hostedAfterSessionCreateResult = { await gateway.holdTypedResult() }
        }
        if scenario.hasPrefix("trust-before") {
            model.hostedBeforeNewSessionSubmission = { await gateway.holdSubmission() }
        }
        if scenario == "trust-accepted-background" {
            model.hostedAfterNewSessionTrustResult = { await gateway.holdAcceptedTrust() }
        }
        _model = State(initialValue: model)
    }
    var body: some View {
        NavigationStack {
            VStack {
                Text(counts).accessibilityIdentifier("fixture.create-counts")
                Text(trustCounts).accessibilityIdentifier("fixture.trust-counts")
                Text("callbacks:\(callbacks) owned:\(owned)").accessibilityIdentifier("fixture.create-result")
                Text("\(model.connectionState) socket:\(model.knowledgePresentationIdentity.connectionID.map(String.init) ?? "none") profile:\(model.profiles.selected?.id ?? "none")").accessibilityIdentifier("fixture.create-connection")
            }
        }
        .environment(model)
        .tronPresentation()
        .tronManagedSheet(isPresented: Binding(get: { ready && showing }, set: { showing = $0 }), identity: "fixture.new-session") {
            NewSessionSheet(initialDraftText: "Fixture original prompt") { route in
                callbacks += 1; owned = model.ownsNavigationRoute(route)
                showing = false
            }
            .environment(model)
            .presentationDetents([.large])
        }
        .environment(\.tronPresentationActivityCoordinator, activity)
        .task {
            do { try await model.connectHostedGateway(profile: original, token: "fixture-only-token"); ready = true }
            catch { counts = "fixture-error" }
        }
        .task { for await value in gateway.updates() { counts = value.creates; trustCounts = value.trust } }
        .onChange(of: model.knowledgePresentationIdentity) { _, identity in
            if scenario == "trust-before-profile",
               model.profiles.selected?.id == replacement.id,
               model.connectionState == .connected,
               identity.lifecycleGeneration != nil {
                Task { await gateway.releaseSubmission() }
            }
        }
        .onChange(of: phase) { _, value in
            switch value {
            case .background:
                model.enteredBackground()
                Task {
                    if scenario.contains("replace-profile") { await model.switchGateway(replacement) }
                    await gateway.releaseTypedResult()
                    if scenario == "trust-before-background" { await gateway.releaseSubmission() }
                    if scenario == "trust-accepted-background" { await gateway.releaseAcceptedTrust() }
                }
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
    }
}

private actor NewSessionFixtureGateway {
    private var creates = 0, typed = 0
    private var held: CheckedContinuation<Void, Never>?
    struct Counts: Sendable { let creates: String; let trust: String }
    private let scenario: String
    private var trusts = 0, successorTrusts = 0, submissionHeld = 0, submissionReleased = 0, acceptedHeld = 0
    private var fallbackMatches = false
    private var trustResolved = false
    private var heldSubmission: CheckedContinuation<Void, Never>?
    private var heldAcceptedTrust: CheckedContinuation<Void, Never>?
    private var streams: [AsyncStream<Counts>.Continuation] = []
    init(scenario: String) { self.scenario = scenario }
    nonisolated func updates() -> AsyncStream<Counts> { AsyncStream { c in Task { await self.add(c) } } }
    private func add(_ c: AsyncStream<Counts>.Continuation) { streams.append(c); publish() }
    private func publish() {
        let counts = Counts(creates: "creates:\(creates) typed:\(typed)", trust: "trusts:\(trusts) successor:\(successorTrusts) fallback:\(fallbackMatches) held:\(submissionHeld) released:\(submissionReleased) acceptedHeld:\(acceptedHeld)")
        streams.forEach { $0.yield(counts) }
    }
    func holdSubmission() async {
        submissionHeld += 1; publish()
        await withCheckedContinuation { heldSubmission = $0 }
    }
    func releaseSubmission() {
        guard let heldSubmission else { return }
        self.heldSubmission = nil; submissionReleased += 1
        heldSubmission.resume(); publish()
    }
    func holdAcceptedTrust() async {
        acceptedHeld += 1; publish()
        await withCheckedContinuation { heldAcceptedTrust = $0 }
    }
    func releaseAcceptedTrust() { heldAcceptedTrust?.resume(); heldAcceptedTrust = nil }
    func holdTypedResult() async {
        typed += 1; publish()
        await withCheckedContinuation { held = $0 }
    }
    func releaseTypedResult() { held?.resume(); held = nil }
    func handle(_ method: String, params: [String: JSONValue], replacement: Bool) -> JSONValue? {
        switch method {
        case "settings.get": return .object(["effective": .object([:])])
        case "trust.inspect": return .object(["requiresDecision": .bool(scenario.hasPrefix("trust-") && !trustResolved), "effectiveDecision": scenario.hasPrefix("trust-") && !trustResolved ? .null : .bool(false)])
        case "trust.set":
            trusts += 1
            if replacement { successorTrusts += 1 }
            fallbackMatches = params["cwd"] == .string("/fixture/original") && params["decision"] == .bool(false)
            trustResolved = true; publish()
            return .object(["requiresDecision": .bool(false), "effectiveDecision": .bool(false)])
        case "git.inspect": return .object(["isRepository": .bool(true), "branch": .string("main"), "dirty": .bool(false), "branches": .array([.object(["name": .string("main"), "checkedOut": .bool(true)]), .object(["name": .string("fixture-base"), "checkedOut": .bool(false)])]), "commits": .array([])])
        case "session.create": creates += 1; publish(); return .object(["sessionId": .string("fixture-created-session")])
        case "session.list", "session.listUpdated": return .object(["sessions": .array([])])
        case "system.metadata": return .object([:])
        case "attention.list": return .object(["items": .array([])])
        case "filesystem.list": return .object(["path": params["path"] ?? .string("/fixture/original"), "entries": .array([.object(["name": .string("replacement"), "path": .string("/fixture/replacement"), "kind": .string("directory"), "hidden": .bool(false)])])])
        default: return nil
        }
    }
}

private actor NewSessionFixtureSocket: GatewaySocketConnection {
    private let gateway: NewSessionFixtureGateway
    private let replacement: Bool
    private var inbound: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    init(gateway: NewSessionFixtureGateway, replacement: Bool) {
        self.gateway = gateway
        self.replacement = replacement
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":6,\"minProtocolVersion\":6,\"machineId\":\"\(replacement ? "new-session-replacement-machine" : "new-session-machine")\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { return }
        let result = await gateway.handle(method, params: request["params"]?.objectValue ?? [:], replacement: replacement)
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(result != nil)]
        if let result { response["result"] = result }
        else { response["error"] = .object(["code": .string("fixture_unsupported"), "message": .string("Optional fixture read"), "retryable": .bool(false)]) }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
    }
    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
    private func deliver(_ data: Data) { if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { inbound.append(data) } }
}
#endif
