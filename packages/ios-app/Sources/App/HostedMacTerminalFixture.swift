#if HOSTED_TEST
import Foundation
import SwiftUI
import TronMobileCore

/// The real Settings root with a synthetic Gateway that answers Mac Terminal's
/// two enrollment calls, for `TronMacTerminalUITests`. Everything after
/// enrollment is real: the app's Secure Enclave-or-Simulator key, its
/// MacTerminalSSH client, and a real OpenSSH sshd on this Mac's Tailscale
/// address that `scripts/ios-mac-terminal-journey` starts and describes in the
/// JSON file named by `TRON_MAC_TERMINAL_FIXTURE`. The synthetic Gateway writes
/// the enrolled key into that sshd's authorized_keys, as the real Gateway's
/// `MacTerminalKeys` does (proved by packages/gateway `npm run test:mac-terminal`),
/// and can stop answering to prove the shell does not need it.
struct HostedMacTerminalFixture: View {
    @State private var model: AppModel
    private let gateway: MacTerminalFixtureGateway
    private let profile = GatewayProfile(id: "mac-terminal", label: "Fixture Mac", host: "mac-terminal.example.test",
                                         port: 9847, machineId: "mac-terminal-machine", deviceId: "fixture-iphone")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-mac-terminal-scenario" }).dropFirst().first ?? "enroll"
        let configuration = ProcessInfo.processInfo.environment["TRON_MAC_TERMINAL_FIXTURE"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode(MacTerminalFixtureConfiguration.self, from: $0) }
        let gateway = MacTerminalFixtureGateway(scenario: scenario, configuration: configuration)
        self.gateway = gateway
        // Each launch starts unenrolled: no key and no cached enrollment.
        try? MacTerminalEnrollmentStore().remove(machineID: "mac-terminal-machine")
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in MacTerminalFixtureSocket(gateway: gateway) })
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "mac-terminal-fixture"))))
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsView()
            HStack {
                Button("Stop Gateway") { Task { await gateway.stop() } }
                    .accessibilityIdentifier("fixture.stop-gateway")
                Text("\(model.connectionState)").accessibilityIdentifier("fixture.connection")
            }
            .font(.caption).padding(6)
        }
        .environment(model)
        .tronPresentation()
        .tronSettingsLayout()
        .preferredColorScheme(.dark)
        .task {
            try? await model.connectHostedGateway(profile: profile, token: "fixture-token")
        }
    }
}

private struct MacTerminalFixtureConfiguration: Decodable {
    let hosts: [String]
    let port: Int
    let username: String
    let hostKeys: [String]
    /// A valid host key that is not the sshd's, for the mismatch scenario.
    let otherHostKey: String
    let authorizedKeys: String
}

private actor MacTerminalFixtureGateway {
    private let scenario: String
    private let configuration: MacTerminalFixtureConfiguration?
    private var sockets: [MacTerminalFixtureSocket] = []
    private var stopped = false
    private var remoteLoginChecks = 0

    init(scenario: String, configuration: MacTerminalFixtureConfiguration?) {
        self.scenario = scenario
        self.configuration = configuration
    }

    func attach(_ socket: MacTerminalFixtureSocket) -> Bool {
        guard !stopped else { return false }
        sockets.append(socket)
        return true
    }

    /// The Gateway goes away: open sockets close and new ones are refused.
    func stop() async {
        stopped = true
        for socket in sockets { await socket.close() }
        sockets.removeAll()
    }

    func handle(_ method: String, params: [String: JSONValue]) -> (result: JSONValue?, error: JSONValue?) {
        switch method {
        case "macTerminal.status":
            guard let configuration else { return (nil, failure("The journey harness did not describe its sshd")) }
            remoteLoginChecks += 1
            // `remote-login-off` answers off on the first check only, as if the
            // maintainer turned Remote Login on before tapping Check Again.
            let off = scenario == "remote-login-off" && remoteLoginChecks < 2
            let hostKeys = scenario == "mismatch" ? [configuration.otherHostKey] : configuration.hostKeys
            return (.object([
                "username": .string(configuration.username), "port": .number(Double(configuration.port)),
                "hosts": .array(configuration.hosts.map(JSONValue.string)), "hostKeys": .array(hostKeys.map(JSONValue.string)),
                "remoteLogin": .string(off ? "off" : "on"), "enrolled": .bool(false),
            ]), nil)
        case "settings.change":
            guard let configuration,
                  let change = params["changes"]?.arrayValue?.first?.objectValue,
                  change["key"]?.stringValue == "permissions.macTerminalKey",
                  change["qualifiers"]?.objectValue?["device"]?.stringValue == "fixture-iphone" else {
                return (nil, failure("Unexpected settings change"))
            }
            let line: String? = change["op"]?.stringValue == "set" ? change["value"]?.stringValue.map {
                "from=\"100.64.0.0/10,fd7a:115c:a1e0::/48\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc \($0) tron-mac-terminal:fixture-iphone"
            } : nil
            do {
                try ((line.map { $0 + "\n" }) ?? "").write(toFile: configuration.authorizedKeys, atomically: true, encoding: .utf8)
            } catch {
                return (nil, failure("Could not write the journey's authorized_keys: \(error.localizedDescription)"))
            }
            return (fixtureSettingsChangeResult(key: "permissions.macTerminalKey"), nil)
        default:
            return (nil, nil)
        }
    }

    private func failure(_ message: String) -> JSONValue {
        .object(["code": .string("fixture_failure"), "message": .string(message), "retryable": .bool(false)])
    }
}

private actor MacTerminalFixtureSocket: GatewaySocketConnection {
    private let gateway: MacTerminalFixtureGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    init(gateway: MacTerminalFixtureGateway) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"mac-terminal-machine\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
        Task { if await !gateway.attach(self) { await self.close() } }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"] == .string("request"), let id = frame["id"]?.stringValue,
              let method = frame["method"]?.stringValue else { return }
        let reply = await gateway.handle(method, params: frame["params"]?.objectValue ?? [:])
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(reply.result != nil)]
        if let result = reply.result { response["result"] = result }
        else { response["error"] = reply.error ?? .object(["code": .string("fixture_unsupported"), "message": .string("Optional fixture read"), "retryable": .bool(false)]) }
        if let encoded = try? JSONEncoder.gateway.encode(JSONValue.object(response)) { deliver(encoded) }
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
