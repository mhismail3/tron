#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Hosted Connected Services/MCP journey backed only by a scripted in-app Gateway.
struct HostedIntegrationsFixtureView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let profile = GatewayProfile(id: "integration-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-integrations")
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var gateway: HostedIntegrationsGateway
    @State private var oauthCounters = "begins:0 completes:0 queries:0 mismatches:0"
    @State private var mcpOriginalCounters = "add:0 token:0 retargets:0 released:0"
    @State private var mcpReplacementCounters = "add:0 token:0 retargets:0 released:0"
    @State private var hasReplacedMCPAuthority = false
    @State private var replacementGateway: HostedIntegrationsGateway
    private let mcpScenario: String?
    private let replacementProfile = GatewayProfile(id: "replacement-integration-fixture", label: "Replacement Mac", host: "replacement.example.test", port: 9847, machineId: "fixture-integrations-replacement")
    private let dark: Bool
    private let recoveryScenario: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-integrations-scenario" }).dropFirst().first ?? "default"
        recoveryScenario = scenario.hasPrefix("connection-") ? scenario : nil
        mcpScenario = scenario.hasPrefix("mcp-") ? scenario : nil
        dark = arguments.contains("-ui-dark-mode")
        let gateway = HostedIntegrationsGateway(scenario: scenario)
        _gateway = State(initialValue: gateway)
        let replacementGateway = HostedIntegrationsGateway(scenario: "mcp-replacement")
        _replacementGateway = State(initialValue: replacementGateway)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { request in
            let replacement = request.url?.host == "replacement.example.test"
            return HostedIntegrationsSocket(gateway: replacement ? replacementGateway : gateway,
                machineID: replacement ? "fixture-integrations-replacement" : "fixture-integrations")
        })
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        if scenario == "mcp-replace-mac" { try! profiles.save(replacementProfile, token: "replacement-fixture-token", selecting: false) }
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-integrations-fixture"))))
    }

    var body: some View {
        Group {
            if let recoveryScenario {
                HostedConnectionRetryFixture(scenario: recoveryScenario)
            } else if ready {
                NavigationStack {
                    VStack {
                        if mcpScenario != nil {
                            MCPServersSettingsView(projectCWD: nil)
                            Text(mcpOriginalCounters).font(.caption2).accessibilityIdentifier("fixture.mcp-original")
                            Text(mcpReplacementCounters).font(.caption2).accessibilityIdentifier("fixture.mcp-replacement")
                            Text(model.knowledgeDestinationIdentity.profileID ?? "none").font(.caption2).accessibilityIdentifier("fixture.destination")
                        } else { IntegrationsSettingsView() }
                        Text(oauthCounters).font(.caption2).lineLimit(2).frame(height: 32)
                            .accessibilityIdentifier("fixture.oauth-counters")
                    }
                }
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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.enteredBackground()
                Task {
                    if mcpScenario == "mcp-replace-mac", !hasReplacedMCPAuthority {
                        hasReplacedMCPAuthority = true
                        await model.switchGateway(replacementProfile)
                    }
                    await gateway.releaseMCPReply()
                    await gateway.releaseOAuthReply()
                }
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
        .task {
            guard recoveryScenario == nil else { return }
            for await value in gateway.counterUpdates() { oauthCounters = value }
        }
        .task {
            guard mcpScenario != nil else { return }
            for await value in gateway.mcpCounterUpdates() { mcpOriginalCounters = value }
        }
        .task {
            guard mcpScenario != nil else { return }
            for await value in replacementGateway.mcpCounterUpdates() { mcpReplacementCounters = value }
        }
        .task {
            guard recoveryScenario == nil else { return }
            do { try await model.connectHostedGateway(profile: profile, token: "fixture-token"); ready = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

actor HostedIntegrationsGateway {
    private let scenario: String
    private var sockets: [HostedIntegrationsSocket] = []
    private var receipts: [String: JSONValue] = [:]
    private var mcpAddCount = 0
    private var mcpTokenCount = 0
    private var mcpRetargets = 0
    private var mcpReleased = 0
    private var mcpServerName = ""
    private var mcpReply: CheckedContinuation<Void, Never>?
    private var mcpContinuations: [AsyncStream<String>.Continuation] = []
    nonisolated func mcpCounterUpdates() -> AsyncStream<String> {
        AsyncStream { value in Task { await self.addMCPContinuation(value) } }
    }
    private func addMCPContinuation(_ value: AsyncStream<String>.Continuation) { mcpContinuations.append(value); publishMCPCounters() }
    private func publishMCPCounters() {
        let value = "add:\(mcpAddCount) token:\(mcpTokenCount) retargets:\(mcpRetargets) released:\(mcpReleased)"
        mcpContinuations.forEach { $0.yield(value) }
    }
    func releaseMCPReply() { mcpReply?.resume(); mcpReply = nil }
    private var oauthBegins = 0
    private var oauthCompletes = 0
    private var receiptQueries = 0
    private var queryMismatches = 0
    private var commands: [String: String] = [:]
    private var receiptErrors: [String: JSONValue] = [:]
    private var counterContinuations: [AsyncStream<String>.Continuation] = []
    nonisolated func counterUpdates() -> AsyncStream<String> {
        AsyncStream { continuation in Task { await self.addCounterContinuation(continuation) } }
    }
    private func addCounterContinuation(_ value: AsyncStream<String>.Continuation) {
        counterContinuations.append(value); publishCounters()
    }
    private func publishCounters() {
        let value = "begins:\(oauthBegins) completes:\(oauthCompletes) queries:\(receiptQueries) mismatches:\(queryMismatches)"
        counterContinuations.forEach { $0.yield(value) }
    }
    private var oauthInstanceID = ""
    private var oauthReply: CheckedContinuation<Void, Never>?
    func releaseOAuthReply() { oauthReply?.resume(); oauthReply = nil }
    init(scenario: String) { self.scenario = scenario }
    func attach(_ socket: HostedIntegrationsSocket) { sockets.append(socket) }

    func handle(method: String, params: [String: JSONValue]) async -> (JSONValue?, JSONValue?) {
        if method == "mcp.list" { return (.object(["servers": .array([]), "errors": .number(0)]), nil) }
        if method == "mcp.add", let command = params["commandId"]?.stringValue {
            mcpAddCount += 1; mcpServerName = params["server"]?.stringValue ?? ""
            let result: JSONValue = .object(["added": .bool(true)])
            commands[command] = method; receipts[command] = result; publishMCPCounters()
            if scenario == "mcp-held-add" || scenario == "mcp-replace-mac" {
                await withCheckedContinuation { mcpReply = $0 }
                mcpReleased += 1; publishMCPCounters()
            }
            return (result, nil)
        }
        if method == "mcp.token.set" {
            mcpTokenCount += 1
            if params["server"]?.stringValue != mcpServerName || params["token"]?.stringValue != "fixture-original-token" { mcpRetargets += 1 }
            publishMCPCounters()
            return (.object(["stored": .bool(true)]), nil)
        }
        if method == "connections.list" { return (snapshot(), nil) }
        if method == "command.status", let command = params["commandId"]?.stringValue {
            receiptQueries += 1
            if commands[command] != params["method"]?.stringValue { queryMismatches += 1 }
            publishCounters()
            if let error = receiptErrors[command] { return (nil, error) }
            if let value = receipts[command] {
                return (.object(["status": .string("completed"), "result": value]), nil)
            }
            return (.object(["status": .string("missing")]), nil)
        }
        if method == "knowledge.x.oauth.begin", let command = params["commandId"]?.stringValue {
            oauthBegins += 1; commands[command] = method; publishCounters()
            oauthInstanceID = params["instanceId"]?.stringValue ?? "fixture"
            let result: JSONValue = .object(["operationId": .string("fixture-oauth-operation"),
                "instanceId": params["instanceId"] ?? .string("fixture"),
                "authorizationUrl": .string("https://twitter.com/i/oauth2/authorize?state=fixture"),
                "state": .string("fixture")])
            if scenario != "oauth-missing" { receipts[command] = result }
            if scenario == "oauth-delayed" || scenario == "oauth-missing" { await withCheckedContinuation { oauthReply = $0 } }
            if oauthBegins != 1 { return (nil, .object(["code": .string("duplicate"), "message": .string("OAuth begin replayed"), "retryable": .bool(false)])) }
            return (result, nil)
        }
        if method == "knowledge.x.oauth.complete", let command = params["commandId"]?.stringValue {
            oauthCompletes += 1; commands[command] = method; publishCounters()
            if scenario == "oauth-expired" {
                let error: JSONValue = .object(["code": .string("conflict"), "message": .string("X OAuth setup expired; start authorization again"), "retryable": .bool(false)])
                receiptErrors[command] = error
                await withCheckedContinuation { oauthReply = $0 }
                return (nil, error)
            }
            let value = instance(oauthInstanceID, "knowledge.x", "knowledge-connector", "fixture-x-account", "ready", "Connected test X")
            receipts[command] = value
            if scenario == "oauth-complete-delayed" { await withCheckedContinuation { oauthReply = $0 } }
            return (value, nil)
        }
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
        let definitions: [JSONValue] = [definition("knowledge.raindrop", "Raindrop", [capability("read", "Read bookmarks")]),
                                        definition("knowledge.x", "X", [capability("read", "Read bookmarks")])]
        var instances: [JSONValue] = [instance("raindrop-1", "knowledge.raindrop", "knowledge-connector", "raindrop-account", "ready", "Mira", collections: [.object(["collectionId": .string("63441068"), "role": .string("research")])]),
                                      instance("raindrop-2", "knowledge.raindrop", "knowledge-connector", "raindrop-second", "setup-required", nil),
                                      instance("x-1", "knowledge.x", "knowledge-connector", "x-account", "ready", "@luna")]
        if oauthCompletes > 0, scenario != "oauth-expired" {
            instances.append(instance(oauthInstanceID, "knowledge.x", "knowledge-connector", "fixture-x-account", "ready", "Connected test X"))
        }
        let capabilities = instances.compactMap { item -> JSONValue? in
            guard let id = item.objectValue?["id"]?.stringValue, let definitionId = item.objectValue?["definitionId"]?.stringValue else { return nil }
            let health = item.objectValue?["health"]?.stringValue
            return .object(["id": .string("read"), "availability": .string(health == "setup-required" ? "requires-setup" : "available"),
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

    private func definition(_ id: String, _ name: String, _ capabilities: [JSONValue]) -> JSONValue {
        .object(["schemaVersion": .number(1), "id": .string(id), "implementation": .string("knowledge-connector"), "displayName": .string(name),
                 "setupMethods": .array([.string(id == "knowledge.x" ? "oauth" : "token")]),
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
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: HostedIntegrationsGateway, machineID: String = "fixture-integrations") {
        self.gateway = gateway
        inbound = [try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"), "gatewayVersion": .string("fixture"), "piVersion": .string("fixture"),
            "protocolVersion": .number(6), "minProtocolVersion": .number(6), "machineId": .string(machineID),
            "machineName": .string("Studio server"), "gatewayChannel": .string("stable"), "capabilities": .array([.string("connections.v1")])]))]
        Task { await gateway.attach(self) }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue, let method = frame["method"]?.stringValue else { return }
        Task {
            let result = await gateway.handle(method: method, params: frame["params"]?.objectValue ?? [:])
            await reply(id: id, result: result)
        }
    }
    private func reply(id: String, result: (JSONValue?, JSONValue?)) {
        guard !closed else { return }
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(result.1 == nil)]
        if let value = result.0 { response["result"] = value }
        if let error = result.1 { response["error"] = error }
        guard let data = try? JSONEncoder.gateway.encode(JSONValue.object(response)) else { return }
        deliver(data)
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

/// Real Mac details, with only the transport and recovery clock scripted.
private struct HostedConnectionRetryFixture: View {
    private let profile = GatewayProfile(id: "recovery-fixture", label: "Recovery server", host: "localhost", port: 9847, machineId: "fixture-integrations")
    @State private var model: AppModel

    init(scenario: String) {
        let failures = scenario == "connection-unreachable" ? 2 : 1
        let factory = HostedRecoverySocketFactory(failures: failures)
        let origin = ContinuousClock().now
        let clock = MonotonicClock(now: { ContinuousClock().now }, sleep: { duration in
            // First unreachable attempt advances; the next delay is parked until Retry cancels it.
            try await Task.sleep(for: duration >= .seconds(10) ? .seconds(3_600) : duration)
        }, gridOrigin: origin)
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in factory.next() }),
            profiles: profiles, clock: clock,
            reconnectDelayPolicy: ReconnectDelayPolicy(initialSeconds: failures == 2 ? 0.1 : 100,
                multiplier: 1_000, maximumSeconds: 100, jitterFraction: 0, nextUnitInterval: { 0.5 })
        ))
    }

    var body: some View {
        NavigationStack { GatewayConnectionDetailView(profile: profile) }
            .environment(model)
            .tronPresentation()
            .tronSettingsLayout()
            .tronSettingsVisualTheme(accent: .tronEmerald)
            .task { await model.start() }
    }
}

private final class HostedRecoverySocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    init(failures: Int) { self.failures = failures }
    func next() -> any GatewaySocketConnection {
        lock.lock()
        let shouldFail = failures > 0
        failures -= 1
        lock.unlock()
        if shouldFail { return HostedRecoveryFailedSocket() }
        return HostedIntegrationsSocket(gateway: HostedIntegrationsGateway(scenario: "default"))
    }
}

private actor HostedRecoveryFailedSocket: GatewaySocketConnection {
    func send(_ data: Data) async throws {
        throw GatewayFailure(code: "timeout", message: "Scripted transport unavailable", retryable: true, details: nil)
    }
    func receive() async throws -> Data { throw CancellationError() }
    func ping() async throws { throw CancellationError() }
    func close() async {}
}
#endif
