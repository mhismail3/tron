#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// A socket-held canonical refresh crosses the production AppModel and renderer.
/// The UI test owns the gate directory; no user profile or private draft state is touched.
@MainActor
struct HostedSettingsListRefreshFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var failure: String?
    @State private var activity = PresentationActivityCoordinator()
    private let socket: SettingsListRefreshSocket
    private let profile: GatewayProfile
    private let gate: URL
    private let target = SettingsTarget.global.gatewayTarget

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "-refresh-gate")!
        gate = URL(fileURLWithPath: arguments[index + 1])
        socket = SettingsListRefreshSocket(gate: gate)
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        profile = GatewayProfile(id: "list-refresh-fixture", label: "Fixture", host: "gateway.test", port: 9847,
                                 machineId: "fixture-machine", deviceId: "fixture-device")
        try! profiles.save(profile, token: "fixture-token")
        _model = State(initialValue: AppModel(client: GatewayClient(socketFactory: GatewaySocketFactory { [socket] _ in socket }),
            profiles: profiles, cache: SnapshotCache(root: gate.appending(path: "cache"))))
    }

    var body: some View {
        TronPresentationSurface(id: "fixture.list-refresh") {
            NavigationStack {
                VStack {
                    if ready {
                        Button("Admit refresh") {
                            Task {
                                do {
                                    await socket.arm()
                                    model.settingsTrust.noteSettingsChanged()
                                    try await model.refreshSettingsSnapshot(for: target)
                                    try Data().write(to: gate.appending(path: "published"))
                                } catch { failure = String(describing: error) }
                            }
                        }
                        SettingsRendererView(target: target, writeLayer: "global", presentation: .section("context"))
                    } else { ProgressView() }
                    if let failure { Text(failure) }
                }
                .navigationTitle("Refresh fixture")
            }
            .environment(model)
            .environment(\.tronPresentationActivityCoordinator, activity)
            .tronPresentation()
            .tronSettingsLayout()
            .task {
                do {
                    try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                    try await model.refreshSettingsSnapshot(for: target)
                    ready = true
                } catch { failure = String(describing: error) }
            }
        }
    }
}

private actor SettingsListRefreshSocket: GatewaySocketConnection {
    private let gate: URL
    private var held = false
    private var values = ["alpha"]
    private var hello = true
    private var closed = false
    private var receiver: CheckedContinuation<Data, Error>?
    private var pending: [Data] = []
    init(gate: URL) { self.gate = gate }
    func arm() { held = true }
    func resume() async {}
    func ping() async throws {}

    func send(_ data: Data) async throws {
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return }
        let result: JSONValue
        switch method {
        case "settings.resolve":
            if held {
                held = false
                try Data().write(to: gate.appending(path: "admitted"))
                while !FileManager.default.fileExists(atPath: gate.appending(path: "release").path) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                    if closed { throw CancellationError() }
                }
                values = ["canonical-latest"]
            }
            result = resolution()
        case "session.list": result = .object(["sessions": .array([]), "nextCursor": .null])
        case "settings.approvals": result = .object(["requests": .array([])])
        default: result = .object([:])
        }
        try enqueue(.object(["type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result]))
    }

    private func resolution() -> JSONValue {
        .object(["target": SettingsTarget.global.gatewayTarget, "layers": .array([.string("global")]),
            "sections": .array([.object(["id": .string("context"), "title": .string("Lists"), "order": .number(1)])]),
            "keys": .array([.object([
                "key": .string("fixture.paths"), "group": .string("context"), "value": .array(values.map(JSONValue.string)),
                "display": .string(values.joined(separator: ", ")), "layer": .string("global"), "applied": .bool(true),
                "overridden": .bool(false), "layers": .array([.object(["layer": .string("global")])]), "badges": .array([]),
                "presentation": .object(["label": .string("Paths"), "help": .string("Ordered paths"), "order": .number(1),
                    "importance": .string("essential"), "control": .string("list"), "valueKind": .string("stringList"),
                    "sessionOverridable": .bool(false), "projectSettable": .bool(false), "editable": .bool(true)])
            ])]), "diagnostics": .array([])])
    }
    private func enqueue(_ frame: JSONValue) throws {
        let data = try JSONEncoder.gateway.encode(frame)
        if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { pending.append(data) }
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
    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
}
#endif
