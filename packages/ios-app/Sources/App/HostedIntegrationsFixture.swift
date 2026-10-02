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
    @State private var oauthCounters = "begins:0 completes:0 queries:0 mismatches:0 policyUpdates:0 policyBudget=1000 setupBegins:0 setupCompletes:0 setupBudget=0"
    @State private var mcpOriginalCounters = "add:0 token:0 retargets:0 released:0"
    @State private var mcpReplacementCounters = "add:0 token:0 retargets:0 released:0"
    @State private var hasReplacedMCPAuthority = false
    @State private var replacementGateway: HostedIntegrationsGateway
    private let mcpScenario: String?
    private let parentOAuthScenario: String?
    private let replacementProfile = GatewayProfile(id: "replacement-integration-fixture", label: "Replacement Mac", host: "replacement.example.test", port: 9847, machineId: "fixture-integrations-replacement")
    private let dark: Bool
    private let recoveryScenario: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-integrations-scenario" }).dropFirst().first ?? "default"
        recoveryScenario = scenario.hasPrefix("connection-") ? scenario : nil
        mcpScenario = scenario.hasPrefix("mcp-") ? scenario : nil
        parentOAuthScenario = scenario.hasPrefix("parent-oauth-") ? scenario : nil
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
        if scenario == "mcp-replace-mac" || scenario == "mcp-auth-replaced-authority" { try! profiles.save(replacementProfile, token: "replacement-fixture-token", selecting: false) }
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-integrations-fixture"))))
    }

    private var fixtureDiagnostics: some View {
        Text(oauthCounters).accessibilityIdentifier("fixture.oauth-counters")
        .font(.system(size: 1))
        .opacity(0.01)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        Group {
            if let recoveryScenario {
                HostedConnectionRetryFixture(scenario: recoveryScenario)
            } else if ready {
                if parentOAuthScenario != nil {
                    SessionShellView()
                        .environment(model)
                        .tronPresentation()
                        .tronSettingsLayout()
                        .overlay { fixtureDiagnostics }
                } else {
                    NavigationStack {
                        VStack {
                            if mcpScenario != nil {
                                MCPServersSettingsView(projectCWD: nil, sessionID: mcpScenario?.hasPrefix("mcp-auth-") == true ? "fixture-auth-session" : nil)
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
                }
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
                    if (mcpScenario == "mcp-replace-mac" || mcpScenario == "mcp-auth-replaced-authority") && !hasReplacedMCPAuthority {
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
    private var authStarts = 0
    private var authResumes = 0
    private var authAnswers = 0
    private var authConsumed = false
    private var authPromptID = "fixture-auth-prompt"
    private let authOperationID = "fixture-mcp-auth-operation"
    private func emitAuth(_ name: String, payload: JSONValue) async {
        for socket in sockets { await socket.emitAuth(name, payload: payload) }
    }
    private func emitAuthPrompt() async {
        await emitAuth("auth.prompt", payload: .object([
            "operationId": .string(authOperationID), "promptId": .string(authPromptID),
            "prompt": .object(["type": .string("manual_code"), "message": .string("Fixture authorization challenge"), "placeholder": .string("Fixture code")])]))
    }
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
        let value = "add:\(mcpAddCount) token:\(mcpTokenCount) retargets:\(mcpRetargets) released:\(mcpReleased) authStarts:\(authStarts) authResumes:\(authResumes) answers:\(authAnswers)"
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
    private var policyUpdates = 0
    private var setupBegins = 0
    private var setupCompletes = 0
    private var lastPolicyBudget = 1_000
    private var lastPolicyEnabled = true
    private var lastSetupBudget = 0
    private var setupInstanceID = ""
    private var setupDefinitionID = ""
    private var oauthInstanceID = ""
    private let oauthOperationID = "fixture-oauth-operation"
    private var oauthBeginAccepted = false
    private var oauthSetupCompleted = false
    private var oauthClientIDProvided = false
    private var oauthRedirectURIProvided = false
    private var oauthPolicyEnabled = false
    private var oauthPaidAccessApproved = false
    private var oauthPaidBudgetCents = 0
    private var oauthRecurringApproved = false
    private var oauthReply: CheckedContinuation<Void, Never>?
    private func publishCounters() {
        let value = "begins:\(oauthBegins) completes:\(oauthCompletes) queries:\(receiptQueries) mismatches:\(queryMismatches) client=\(oauthClientIDProvided) redirect=\(oauthRedirectURIProvided) policy:enabled=\(oauthPolicyEnabled) paid=\(oauthPaidAccessApproved) budget=\(oauthPaidBudgetCents) recurring=\(oauthRecurringApproved) policyUpdates:\(policyUpdates) policyBudget=\(lastPolicyBudget) policyEnabled=\(lastPolicyEnabled) setupBegins:\(setupBegins) setupCompletes:\(setupCompletes) setupBudget=\(lastSetupBudget)"
        counterContinuations.forEach { $0.yield(value) }
    }
    func releaseOAuthReply() { oauthReply?.resume(); oauthReply = nil }
    init(scenario: String) { self.scenario = scenario }
    func attach(_ socket: HostedIntegrationsSocket) { sockets.append(socket) }

    func handle(method: String, params: [String: JSONValue]) async -> (JSONValue?, JSONValue?) {
        if method == "mcp.list" {
            let servers: [JSONValue] = scenario.hasPrefix("mcp-auth-") ? [.object([
                "name": .string("fixture-auth-server"), "scope": .string("global"), "enabled": .bool(true),
                "exposure": .string("direct"), "transport": .string("https://mcp.example.test"),
                "state": .string("needs-auth"), "tools": .array([])])] : []
            return (.object(["servers": .array(servers), "errors": .number(0)]), nil)
        }
        if method == "mcp.auth.start" {
            authStarts += 1; authConsumed = false; publishMCPCounters()
            await emitAuthPrompt()
            return (.object(["operationId": .string(authOperationID)]), nil)
        }
        if method == "auth.resume" {
            authResumes += 1; publishMCPCounters()
            if scenario == "mcp-auth-expired" {
                return (nil, .object(["code": .string("not_found"), "message": .string("Fixture authorization expired"), "retryable": .bool(false)]))
            }
            if authConsumed {
                await emitAuth("auth.completed", payload: .object(["operationId": .string(authOperationID), "success": .bool(true)]))
                return (.object(["state": .string("completed"), "operationId": .string(authOperationID), "providerId": .string("mcp")]), nil)
            }
            if scenario == "mcp-auth-replaced-prompt" { authPromptID = "fixture-auth-replacement-prompt" }
            await emitAuthPrompt()
            return (.object(["state": .string("active"), "operationId": .string(authOperationID), "providerId": .string("mcp")]), nil)
        }
        if method == "auth.respond" {
            authAnswers += 1; publishMCPCounters()
            let accepted = !authConsumed && params["operationId"]?.stringValue == authOperationID
                && params["promptId"]?.stringValue == authPromptID && params["value"]?.stringValue == "fixture-only-code"
            if accepted { authConsumed = true }
            return (.object(["answered": .bool(accepted)]), nil)
        }
        if method == "mcp.auth.cancel" { authConsumed = true; return (.object(["cancelled": .bool(true)]), nil) }
        if method == "provider.list" { return (.object(["providers": .array([])]), nil) }
        if method == "model.list" { return (.object(["models": .array([])]), nil) }
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
        if method == "connections.policy.update" {
            policyUpdates += 1
            let policy = params["policy"] ?? .object([:])
            lastPolicyBudget = paidBudget(policy)
            if case .object(let fields) = policy, case .bool(let enabled)? = fields["enabled"] { lastPolicyEnabled = enabled }
            publishCounters()
            var fields = instance(params["instanceId"]?.stringValue ?? "x-1", "knowledge.x", "knowledge-connector", "x-account", "ready", "@luna").objectValue ?? [:]
            fields["policy"] = policy
            fields["setupRevision"] = .number(2)
            return (.object(fields), nil)
        }
        if method == "connections.setup.begin" {
            setupBegins += 1
            setupInstanceID = params["instanceId"]?.stringValue ?? "fixture-setup"
            setupDefinitionID = params["definitionId"]?.stringValue ?? "knowledge.raindrop"
            publishCounters()
            return (.object(["operationId": .string("fixture-setup-operation"), "instanceId": .string(setupInstanceID),
                "definitionId": .string(setupDefinitionID), "method": params["method"] ?? .string("token"), "status": .string("pending")]), nil)
        }
        if method == "connections.setup.complete" {
            setupCompletes += 1
            let policy = params["policy"] ?? .object([:])
            lastSetupBudget = paidBudget(policy)
            publishCounters()
            var fields = instance(setupInstanceID, setupDefinitionID, "knowledge-connector", params["providerAccountId"]?.stringValue ?? "fixture-account", "ready", "Fixture account").objectValue ?? [:]
            fields["policy"] = policy
            return (.object(fields), nil)
        }
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
            oauthBegins += 1; commands[command] = method
            if oauthBegins == 1 {
                oauthBeginAccepted = true
                oauthInstanceID = params["instanceId"]?.stringValue ?? "fixture"
                oauthClientIDProvided = !(params["clientId"]?.stringValue ?? "").isEmpty
                oauthRedirectURIProvided = !(params["redirectUri"]?.stringValue ?? "").isEmpty
                let policy = params["policy"]?.objectValue ?? [:]
                if case .bool(let enabled)? = policy["enabled"] { oauthPolicyEnabled = enabled }
                if case .bool(let approved)? = policy["paidAccessApproved"] { oauthPaidAccessApproved = approved }
                if case .number(let budget)? = policy["paidBudgetCents"] { oauthPaidBudgetCents = Int(budget) }
                if case .bool(let approved)? = policy["recurringApproved"] { oauthRecurringApproved = approved }
            }
            let result: JSONValue = .object(["operationId": .string(oauthOperationID),
                "instanceId": params["instanceId"] ?? .string("fixture"),
                "authorizationUrl": .string("https://twitter.com/i/oauth2/authorize?state=fixture"),
                "state": .string("fixture")])
            if scenario != "oauth-missing" { receipts[command] = result }
            publishCounters()
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
            if !oauthSetupCompleted && scenario != "oauth-expired" {
                oauthSetupCompleted = true
            }
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

    private func paidBudget(_ policy: JSONValue) -> Int {
        guard case .object(let values) = policy, case .number(let budget)? = values["paidBudgetCents"] else { return 0 }
        return Int(budget)
    }

    private func snapshot() -> JSONValue {
        let definitions: [JSONValue] = [definition("knowledge.raindrop", "Raindrop", [capability("read", "Read bookmarks")]),
                                        definition("knowledge.x", "X", [capability("read", "Read bookmarks")])]
        var instances: [JSONValue] = [instance("raindrop-1", "knowledge.raindrop", "knowledge-connector", "raindrop-account", "ready", "Mira", collections: [.object(["collectionId": .string("63441068"), "role": .string("research")])]),
                                      instance("raindrop-2", "knowledge.raindrop", "knowledge-connector", "raindrop-second", "setup-required", nil),
                                      instance("x-1", "knowledge.x", "knowledge-connector", "x-account", "ready", "@luna")]
        if oauthSetupCompleted {
            instances.append(instance(oauthInstanceID, "knowledge.x", "knowledge-connector", "fixture-x-account", "ready", "Connected test X"))
        }
        let capabilities = instances.compactMap { item -> JSONValue? in
            guard let id = item.objectValue?["id"]?.stringValue, let definitionId = item.objectValue?["definitionId"]?.stringValue else { return nil }
            let health = item.objectValue?["health"]?.stringValue
            return .object(["id": .string("read"), "availability": .string(health == "setup-required" ? "requires-setup" : "available"),
                            "effects": .array([.string("read")]), "definitionId": .string(definitionId), "connectionId": .string(id),
                            "provenance": .object(["owner": .string("connection"), "definitionId": .string(definitionId), "connectionId": .string(id)])])
        }
        let setupInstances = oauthSetupCompleted
            ? instances.filter { $0.objectValue?["id"]?.stringValue != oauthInstanceID }
            : instances
        var operations: [JSONValue] = setupInstances.map { item in
            .object(["operationId": .string("setup-\(item.objectValue?["id"]?.stringValue ?? "")"),
                     "instanceId": item.objectValue?["id"] ?? .string(""), "definitionId": item.objectValue?["definitionId"] ?? .string(""),
                     "method": .string(item.objectValue?["definitionId"]?.stringValue == "knowledge.x" ? "oauth" : "token"),
                     "status": .string("completed"), "createdAt": .string("2026-09-30T00:00:00Z"), "updatedAt": .string("2026-09-30T00:00:00Z")])
        }
        if oauthBeginAccepted {
            operations.append(.object(["operationId": .string(oauthOperationID), "instanceId": .string(oauthInstanceID),
                "definitionId": .string("knowledge.x"), "method": .string("oauth"),
                "status": .string(oauthSetupCompleted ? "completed" : "pending"),
                "createdAt": .string("2026-09-30T00:00:00Z"), "updatedAt": .string("2026-09-30T00:00:00Z")]))
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
    func emitAuth(_ name: String, payload: JSONValue) {
        guard !closed, let data = try? JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("event"), "topic": .string(name), "payload": payload])) else { return }
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
