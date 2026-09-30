#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Hosted Connected Services/MCP journey backed only by a scripted in-app Gateway.
struct HostedIntegrationsFixtureView: View {
    private let profile = GatewayProfile(id: "integration-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-integrations")
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    private let surface: IntegrationsSettingsView.Surface
    private let dark: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-integrations-scenario" }).dropFirst().first ?? "default"
        let surfaceName = arguments.drop(while: { $0 != "-integrations-surface" }).dropFirst().first ?? "services"
        surface = surfaceName == "mcp" ? .mcpServers : .connectedServices
        dark = arguments.contains("-ui-dark-mode")
        let gateway = HostedIntegrationsGateway(scenario: scenario)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in HostedIntegrationsSocket(gateway: gateway) })
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-integrations-fixture"))))
    }

    var body: some View {
        Group {
            if ready {
                NavigationStack { IntegrationsSettingsView(surface: surface) }
                    .environment(model)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .tronSettingsVisualTheme(accent: .tronCyan)
            } else if let error {
                Text(error)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(dark ? .dark : .light)
        .task {
            do { try await model.connectHostedGateway(profile: profile, token: "fixture-token"); ready = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

actor HostedIntegrationsGateway {
    private let scenario: String
    private var sockets: [HostedIntegrationsSocket] = []
    init(scenario: String) { self.scenario = scenario }
    func attach(_ socket: HostedIntegrationsSocket) { sockets.append(socket) }

    func handle(method: String, params: [String: JSONValue]) async -> (JSONValue?, JSONValue?) {
        if method == "connections.list" { return (snapshot(), nil) }
        if method == "knowledge.x.credits" {
            try? await Task.sleep(for: .milliseconds(5_000))
            if scenario == "credits-fail" {
                return (nil, .object(["code": .string("unavailable"), "message": .string("Fixture credit failure"), "retryable": .bool(true)]))
            }
            return (.object(["freeBalance": .number(0), "prepaidBalance": .number(4.2), "totalBalance": .number(4.2)]), nil)
        }
        return (nil, .object(["code": .string("unsupported"), "message": .string("Not used by this fixture"), "retryable": .bool(false)]))
    }

    private func snapshot() -> JSONValue {
        let definitions: [JSONValue] = [definition("knowledge.raindrop", "Raindrop", "knowledge-connector", [capability("read", "Read bookmarks")]),
                                        definition("knowledge.jev", "Jev", "knowledge-connector", [capability("tag", "Tag sources")]),
                                        definition("knowledge.x", "X", "knowledge-connector", [capability("read", "Read bookmarks")]),
                                        definition("mcp.remote-http", "MCP server", "mcp", [capability("tools", "Tools")]),
                                        definition("mcp.available", "Remote MCP", "mcp", [capability("tools", "Tools")])]
        let instances: [JSONValue] = [instance("raindrop-1", "knowledge.raindrop", "knowledge-connector", "raindrop-account", "ready", "Mira", collections: [.object(["collectionId": .string("11"), "role": .string("research")])]),
                                      instance("jev-1", "knowledge.jev", "knowledge-connector", "jev-account", "setup-required", nil),
                                      instance("x-1", "knowledge.x", "knowledge-connector", "x-account", "ready", "@luna"),
                                      instance("mcp-1", "mcp.remote-http", "mcp", "local-search", "ready", nil)]
        let capabilities = instances.compactMap { item -> JSONValue? in
            guard let id = item.objectValue?["id"]?.stringValue, let definitionId = item.objectValue?["definitionId"]?.stringValue else { return nil }
            let capabilityID = definitionId == "knowledge.jev" ? "tag" : (definitionId == "mcp.remote-http" ? "tools" : "read")
            return .object(["id": .string(capabilityID), "availability": .string(definitionId == "knowledge.jev" ? "requires-setup" : "available"),
                            "effects": .array([.string("read")]), "definitionId": .string(definitionId), "connectionId": .string(id),
                            "provenance": .object(["owner": .string("connection"), "definitionId": .string(definitionId), "connectionId": .string(id)])])
        }
        let operations: [JSONValue] = instances.map { item in
            .object(["operationId": .string("setup-\(item.objectValue?["id"]?.stringValue ?? "")"),
                     "instanceId": item.objectValue?["id"] ?? .string(""), "definitionId": item.objectValue?["definitionId"] ?? .string(""),
                     "method": .string(item.objectValue?["definitionId"]?.stringValue == "knowledge.x" ? "oauth" : "token"),
                     "status": .string("completed"), "createdAt": .string("2026-09-30T00:00:00Z"), "updatedAt": .string("2026-09-30T00:00:00Z")])
        }
        return .object(["definitions": .array(definitions), "instances": .array(instances), "setupOperations": .array(operations),
                        "capabilities": .array(capabilities), "stateRevision": .number(1)])
    }

    private func definition(_ id: String, _ name: String, _ implementation: String, _ capabilities: [JSONValue]) -> JSONValue {
        .object(["schemaVersion": .number(1), "id": .string(id), "implementation": .string(implementation), "displayName": .string(name),
                 "setupMethods": .array([.string(id == "knowledge.x" ? "oauth" : (implementation == "mcp" ? "endpoint" : "token"))]),
                 "capabilities": .array(capabilities)])
    }
    private func capability(_ id: String, _ name: String) -> JSONValue {
        .object(["id": .string(id), "displayName": .string(name), "effects": .array([.string("read")]), "supported": .bool(true)])
    }
    private func instance(_ id: String, _ definition: String, _ implementation: String, _ account: String, _ health: String, _ displayName: String?, collections: [JSONValue]? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "definitionId": .string(definition), "implementation": .string(implementation),
            "providerAccountId": .string(account), "credentialConfigured": .bool(true), "credentialAvailability": .string("available"),
            "providerIdentity": .string("admitted"), "policy": .object(["enabled": .bool(true), "allowWrites": .bool(false), "paidAccessApproved": .bool(true), "paidBudgetCents": .number(1000), "recurringApproved": .bool(false)]),
            "health": .string(health), "createdAt": .string("2026-09-30T00:00:00Z"), "updatedAt": .string("2026-09-30T00:00:00Z"), "setupRevision": .number(1)]
        if let displayName { fields["providerDisplayName"] = .string(displayName) }
        if let collections { fields["raindropCollections"] = .array(collections) }
        return .object(fields)
    }
}

actor HostedIntegrationsSocket: GatewaySocketConnection {
    private let gateway: HostedIntegrationsGateway
    private var inbound = [Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":6,"minProtocolVersion":6,"machineId":"fixture-integrations","machineName":"Studio server","gatewayChannel":"stable","capabilities":["connections.v1","knowledge.x.credits.v1"]}"#.utf8)]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: HostedIntegrationsGateway) { self.gateway = gateway; Task { await gateway.attach(self) } }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return }
        let result = await gateway.handle(method: method, params: frame["params"]?.objectValue ?? [:])
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(result.1 == nil)]
        if let value = result.0 { response["result"] = value }
        if let error = result.1 { response["error"] = error }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
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
#endif
