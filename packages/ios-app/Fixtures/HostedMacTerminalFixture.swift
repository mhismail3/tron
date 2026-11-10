#if HOSTED_TEST
import Foundation
import os
import SwiftUI
import TronMobileCore

struct HostedMacTerminalFixture: View {
    @State private var model: AppModel
    @State private var gateway: MacTerminalFixtureGateway
    private let profile = GatewayProfile(id: "mac-terminal", label: "Fixture Mac", host: "mac-terminal.example.test",
                                         port: 9847, machineId: "mac-terminal-machine", deviceId: "fixture-iphone")

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-mac-terminal-scenario" }).dropFirst().first ?? "enroll"
        let configuration = ProcessInfo.processInfo.environment["TRON_MAC_TERMINAL_FIXTURE"]
            .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode(MacTerminalFixtureConfiguration.self, from: $0) }
        let gateway = MacTerminalFixtureGateway(scenario: scenario, configuration: configuration)
        _gateway = State(initialValue: gateway)
        _ = Self.startUnenrolled
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        if scenario == "remove-profile-switch" {
            try! profiles.save(GatewayProfile(id: "mac-terminal-b", label: "Fixture Mac B", host: "mac-terminal-b.example.test",
                port: 9847, machineId: "mac-terminal-machine-b", deviceId: "fixture-iphone-b"), token: "fixture-token-b", selecting: false)
        }
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in
            MacTerminalFixtureSocket(gateway: gateway, answers: !gateway.isStopped)
        })
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "mac-terminal-fixture"))))
    }

    @MainActor private static let startUnenrolled: Void = {
        try? MacTerminalEnrollmentStore().remove(machineID: "mac-terminal-machine")
        if let path = ProcessInfo.processInfo.environment["TRON_MAC_TERMINAL_FIXTURE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let configuration = try? JSONDecoder().decode(MacTerminalFixtureConfiguration.self, from: data) {
            try! Data().write(to: URL(fileURLWithPath: configuration.authorizedKeys), options: .atomic)
        }
    }()

    var body: some View {
        SettingsView()
        .environment(model)
        .tronPresentation()
        .tronSettingsLayout()
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-mac-terminal-light") ? .light : .dark)
        .environment(\.colorScheme, ProcessInfo.processInfo.arguments.contains("-mac-terminal-light") ? .light : .dark)
        .task {
            let gateway = gateway
            DarwinTrigger.observe("com.tron.mobile.fixture.mac-terminal.stop-gateway") { Task { await gateway.stop() } }
            for (suffix, profileID) in [("select-a", "mac-terminal"), ("select-b", "mac-terminal-b")] {
                DarwinTrigger.observe("com.tron.mobile.fixture.mac-terminal.\(suffix)") {
                    Task { @MainActor in
                        let selected = model.profiles.profiles.first { $0.id == profileID }!
                        try! model.profiles.select(selected)
                        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRON_MAC_TERMINAL_FIXTURE"]!).deletingLastPathComponent()
                        try! Data((model.profiles.selected?.machineId ?? "").utf8).write(to: root.appending(path: "selected-machine.txt"), options: .atomic)
                    }
                }
            }
            DarwinTrigger.observe("com.tron.mobile.fixture.mac-terminal.fail-removal") { Task { await gateway.failRemoval() } }
            try? await model.connectHostedGateway(profile: profile, token: "fixture-token")
        }
    }
}


private struct MacTerminalFixtureConfiguration: Decodable {
    let hosts: [String]
    let port: Int
    let username: String
    let hostKeys: [String]
    let otherHostKey: String
    let authorizedKeys: String

}

private actor MacTerminalFixtureGateway {
    private let scenario: String
    private let configuration: MacTerminalFixtureConfiguration?
    private var sockets: [MacTerminalFixtureSocket] = []
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    nonisolated var isStopped: Bool { stopped.withLock { $0 } }
    private var serverEnabled = false
    private var pendingRemoval: CheckedContinuation<Void, Never>?

    func failRemoval() { pendingRemoval?.resume(); pendingRemoval = nil }

    init(scenario: String, configuration: MacTerminalFixtureConfiguration?) {
        self.scenario = scenario
        self.configuration = configuration
    }

    func attach(_ socket: MacTerminalFixtureSocket) { sockets.append(socket) }

    func stop() async {
        stopped.withLock { $0 = true }
        for socket in sockets { await socket.close() }
        sockets.removeAll()
    }

    func handle(_ method: String, params: [String: JSONValue]) async -> (result: JSONValue?, error: JSONValue?) {
        if isStopped { return (nil, failure("The Gateway is stopped")) }
        switch method {
        case "macTerminal.status" where scenario == "loading":
            try? await Task.sleep(for: .seconds(600))
            return (nil, failure("The fixture held its status"))
        case "macTerminal.status":
            guard let configuration else { return (nil, failure("The journey harness did not describe its sshd")) }
            let hostKeys = serverEnabled ? (scenario == "mismatch" ? [configuration.otherHostKey] : configuration.hostKeys) : []
            return (.object([
                "username": .string(configuration.username), "port": .number(Double(configuration.port)),
                "hosts": .array(configuration.hosts.map(JSONValue.string)), "hostKeys": .array(hostKeys.map(JSONValue.string)),
                "serviceState": .string(serverEnabled ? "running" : "unconfigured"), "enrolled": .bool(false),
            ]), nil)
        case "settings.change":
            guard let configuration, let change = params["changes"]?.arrayValue?.first?.objectValue else {
                return (nil, failure("Unexpected settings change"))
            }
            if change["key"]?.stringValue == "permissions.macTerminalServer" {
                serverEnabled = change["value"]?.boolValue == true
                return (fixtureSettingsChangeResult(key: "permissions.macTerminalServer"), nil)
            }
            guard change["key"]?.stringValue == "permissions.macTerminalKey",
                  change["qualifiers"]?.objectValue?["device"]?.stringValue == "fixture-iphone" else {
                return (nil, failure("Unexpected settings change"))
            }
            if scenario == "remove-profile-switch", change["op"]?.stringValue == "unset" {
                await withCheckedContinuation { continuation in
                    pendingRemoval = continuation
                    let root = URL(fileURLWithPath: configuration.authorizedKeys).deletingLastPathComponent()
                    try! Data("pending".utf8).write(to: root.appending(path: "removal-pending.txt"), options: .atomic)
                }
                return (nil, failure("The original Mac refused this key removal"))
            }
            let line: String? = change["op"]?.stringValue == "set" ? change["value"]?.stringValue.map {
                "from=\"100.64.0.0/10\",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc \($0) tron-mac-terminal:fixture-iphone"
            } : nil
            do {
                try ((line.map { $0 + "\n" }) ?? "").write(toFile: configuration.authorizedKeys, atomically: true, encoding: .utf8)
                if line == nil { serverEnabled = false }
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

    init(gateway: MacTerminalFixtureGateway, answers: Bool) {
        self.gateway = gateway
        closed = !answers
        inbound = !answers ? [] : [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"mac-terminal-machine\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
        if answers { Task { await gateway.attach(self) } }
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
