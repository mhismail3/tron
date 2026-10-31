#if HOSTED_TEST
import SwiftUI
@testable import TronMobileCore
import Observation

/// Hosted MCP, provider layout and connection recovery journeys; no vendor API.
struct HostedIntegrationsFixtureView: View {
    @Environment(\.scenePhase) private var scenePhase
    private let profile = GatewayProfile(id: "integration-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-integrations")
    private let replacementProfile = GatewayProfile(id: "replacement-integration-fixture", label: "Replacement Mac", host: "replacement.example.test", port: 9847, machineId: "fixture-integrations-replacement")
    @State private var model: AppModel
    @State private var gateway: HostedIntegrationsGateway
    @State private var replacementGateway: HostedIntegrationsGateway
    @State private var ready = false
    @State private var error: String?
    @State private var mcpOriginalCounters = "add:0 token:0 retargets:0 released:0"
    @State private var mcpReplacementCounters = "add:0 token:0 retargets:0 released:0"
    @State private var hasReplacedMCPAuthority = false
    @State private var showingOllamaDetails = false
    private let scenario: String
    private let dark: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let scenario = arguments.drop(while: { $0 != "-integrations-scenario" }).dropFirst().first ?? "mcp-held-add"
        self.scenario = scenario
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
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-integrations-fixture")),
            appLog: AppLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "hosted-integrations-app-log-\(UUID().uuidString).jsonl"))))
    }

    var body: some View {
        Group {
            if scenario == "connection-secondary" {
                HostedSecondaryRecoveryFixture()
            } else if scenario.hasPrefix("connection-") {
                HostedConnectionRetryFixture(scenario: scenario)
            } else if ready {
                if scenario == "ollama-detail" {
                    NavigationStack {
                        Button("Details for Ollama") { showingOllamaDetails = true }
                            .tronManagedSheet(isPresented: $showingOllamaDetails, identity: "fixture.ollama-detail") {
                                ProviderConfigurationSheet(
                                    provider: ProviderSummary(
                                        id: "ollama", name: "Ollama", configured: true,
                                        usageSupported: false, localOnly: true, authSource: nil,
                                        credentialType: nil, authMethods: [], modelCount: 1
                                    ), target: .global
                                )
                                .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("-fixture-large-type") ? .accessibility3 : .large)
                            }
                    }
                    .environment(model)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .tronSettingsVisualTheme(accent: .tronCyan)
                    .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("-fixture-large-type") ? .accessibility3 : .large)
                } else {
                    NavigationStack {
                        VStack {
                            MCPServersSettingsView(sessionID: scenario.hasPrefix("mcp-auth-") ? "fixture-auth-session" : nil)
                            Text(mcpOriginalCounters).font(.caption2).accessibilityIdentifier("fixture.mcp-original")
                            Text(mcpReplacementCounters).font(.caption2).accessibilityIdentifier("fixture.mcp-replacement")
                            Text(model.knowledgeDestinationIdentity.profileID ?? "none").font(.caption2).accessibilityIdentifier("fixture.destination")
                        }
                    }
                    .environment(model)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .tronSettingsVisualTheme(accent: .tronCyan)
                }
            } else if let error { Text(error) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .preferredColorScheme(dark ? .dark : .light)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.enteredBackground()
                Task {
                    if (scenario == "mcp-replace-mac" || scenario == "mcp-auth-replaced-authority") && !hasReplacedMCPAuthority {
                        hasReplacedMCPAuthority = true
                        await model.switchGateway(replacementProfile)
                    }
                    await gateway.releaseMCPReply()
                }
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
        .task { for await value in gateway.mcpCounterUpdates() { mcpOriginalCounters = value } }
        .task { for await value in replacementGateway.mcpCounterUpdates() { mcpReplacementCounters = value } }
        .task {
            guard !scenario.hasPrefix("connection-") else { return }
            do { try await model.connectHostedGateway(profile: profile, token: "fixture-token"); ready = true }
            catch { self.error = error.localizedDescription }
        }
    }
}

actor HostedIntegrationsGateway {
    private let scenario: String
    private var sockets: [HostedIntegrationsSocket] = []
    private var receipts: [String: JSONValue] = [:]
    private var commands: [String: String] = [:]
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
    init(scenario: String) { self.scenario = scenario }
    func attach(_ socket: HostedIntegrationsSocket) { sockets.append(socket) }

    func handle(method: String, params: [String: JSONValue]) async -> (JSONValue?, JSONValue?) {
        if method == "session.list" {
            return (.object(["sessions": .array([]), "listRevision": .number(1), "projectionToken": .string("fixture-catalog"), "archivedCount": .number(0)]), nil)
        }
        if method == "session.open" {
            let sessionID = params["sessionId"]?.stringValue ?? "integration-fixture-chat"
            let snapshot = SessionSnapshot(
                sessionId: sessionID, runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
                phase: .idle, name: "Integration fixture chat", cwd: "/fixture", parentSessionId: nil, model: nil,
                thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
                stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                    tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
                queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: nil,
                transcriptTotal: nil, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
                extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "fixture-host", revision: 1,
                    capabilities: [], diagnostics: [], semanticState: .init(statuses: [:], working: .init(message: nil, visible: false),
                    hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                    surfaces: [], pendingInteractions: []), diagnostics: [])
            return (.object(["session": try! JSONValue.encode(snapshot), "syncToken": .string("fixture-sync"),
                "subscriptionToken": .string("fixture-subscription"), "completionRevision": .number(0)]), nil)
        }
        if method == "session.sync" { return (.object(["synchronized": .bool(true)]), nil) }
        if method == "session.close" { return (.object(["closed": .bool(true)]), nil) }
        if method == "session.commands" { return (.object(["commands": .array([])]), nil) }
        if method == "session.attention.read" { return (.object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)]), nil) }
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
        if method == "command.status", let command = params["commandId"]?.stringValue {
            if let value = receipts[command] { return (.object(["status": .string("completed"), "result": value]), nil) }
            return (.object(["status": .string("missing")]), nil)
        }
        return (nil, .object(["code": .string("unsupported"), "message": .string("Not used by this fixture"), "retryable": .bool(false)]))
    }
}

actor HostedIntegrationsSocket: GatewaySocketConnection {
    private let gateway: HostedIntegrationsGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: HostedIntegrationsGateway, machineID: String = "fixture-integrations", machineGroupID: String? = nil) {
        self.gateway = gateway
        inbound = [try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"), "gatewayVersion": .string("fixture"), "piVersion": .string("fixture"),
            "protocolVersion": .number(8), "minProtocolVersion": .number(8), "machineId": .string(machineID),
            "machineName": .string("Studio server"), "machineGroupID": .string(machineGroupID ?? machineID), "gatewayChannel": .string("stable"), "capabilities": .array([.string("connections.v1")])]))]
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
    func loseNetworkConnection() {
        closed = true
        let pending = receivers
        receivers.removeAll()
        pending.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }
    private func deliver(_ data: Data) { if receivers.isEmpty { inbound.append(data) } else { receivers.removeFirst().resume(returning: data) } }
}

/// Real Mac details, with only the transport and recovery clock scripted.
private struct HostedConnectionRetryFixture: View {
    private let profile = GatewayProfile(id: "recovery-fixture", label: "Recovery server", host: "localhost", port: 9847, machineId: "fixture-integrations")
    @State private var model: AppModel
    private let factory: HostedRecoverySocketFactory
    @State private var failedSockets = 0

    init(scenario: String) {
        let failures = scenario == "connection-retry" ? 1 : 2
        let factory = HostedRecoverySocketFactory(failures: failures, dropsEstablishedConnection: scenario == "connection-loss-unreachable", openedFailures: scenario == "connection-opened-failure")
        self.factory = factory
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
        NavigationStack {
            GatewayConnectionDetailView(profile: profile)
                .overlay(alignment: .bottom) {
                    Text("failed sockets \(failedSockets)").accessibilityIdentifier("failed-socket-count")
                }
        }
            .environment(model)
            .tronPresentation()
            .tronSettingsLayout()
            .tronSettingsVisualTheme(accent: .tronEmerald)
            .task {
                await model.start()
                for _ in 0..<200 {
                    failedSockets = factory.failedSocketCount
                    if failedSockets >= 2 { break }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
    }
}

private final class HostedRecoverySocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private var producedFailures = 0
    var failedSocketCount: Int { lock.withLock { producedFailures } }
    private var dropsEstablishedConnection: Bool
    private let openedFailures: Bool
    init(failures: Int, dropsEstablishedConnection: Bool = false, openedFailures: Bool = false) {
        self.failures = failures
        self.dropsEstablishedConnection = dropsEstablishedConnection
        self.openedFailures = openedFailures
    }
    func next() -> any GatewaySocketConnection {
        lock.lock()
        let shouldDropEstablishedConnection = dropsEstablishedConnection
        let shouldFail = failures > 0 && !shouldDropEstablishedConnection
        if shouldFail { failures -= 1; producedFailures += 1 }
        dropsEstablishedConnection = false
        lock.unlock()
        if shouldFail {
            if openedFailures { return HostedOpenedFailureSocket() }
            return HostedRecoveryFailedSocket()
        }
        let socket = HostedIntegrationsSocket(gateway: HostedIntegrationsGateway(scenario: "default"))
        if shouldDropEstablishedConnection {
            Task {
                try? await Task.sleep(for: .seconds(3))
                await socket.loseNetworkConnection()
            }
        }
        return socket
    }
}

private actor HostedOpenedFailureSocket: GatewaySocketConnection {
    func send(_ data: Data) async throws { throw URLError(.networkConnectionLost) }
    func receive() async throws -> Data { throw URLError(.networkConnectionLost) }
    func ping() async throws { throw URLError(.networkConnectionLost) }
    func close() async {}
    func metadata() async -> GatewaySocketMetadata {
        GatewaySocketMetadata(closeCode: nil, httpStatusCode: 101, transportOpenMilliseconds: 1)
    }
}

/// A byte transport that never opens or yields handshake bytes. The production
/// GatewayClient's transport-open deadline, not a fixture error, ends the attempt.
private actor HostedRecoveryFailedSocket: GatewaySocketConnection {
    private var receiver: CheckedContinuation<Data, Error>?
    private var sender: CheckedContinuation<Void, Error>?
    private var closed = false
    func send(_ data: Data) async throws {
        if closed { throw CancellationError() }
        try await withCheckedThrowingContinuation { sender = $0 }
    }
    func receive() async throws -> Data {
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func ping() async throws {}
    func close() async {
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
        sender?.resume(throwing: CancellationError())
        sender = nil
    }
}

/// Drives the real pool and byte-level client through the scene's retirement boundary.
/// Only elapsed time and the remote socket are controlled; status comes from the pool.
private struct HostedSecondaryRecoveryFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = HostedSecondaryRecoveryOwner()
    var body: some View {
        VStack {
            Text(owner.state).accessibilityIdentifier("secondary-state")
            Text(owner.delay).accessibilityIdentifier("secondary-delay")
            Text(owner.waitHistory).accessibilityIdentifier("secondary-waits")
            Text(owner.lastConnected).accessibilityIdentifier("secondary-last-connected")
            Text(owner.primary).accessibilityIdentifier("primary-state")
            Button("Lose secondary") { owner.lose() }
            Button("Restore secondary") { owner.transport.setOnline(true) }
            Button("Retry secondary") { owner.retry() }
        }
        .task { await owner.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { owner.pool.retire() }
            if phase == .active, owner.started { owner.reconcile() }
        }
    }
}

@MainActor @Observable
private final class HostedSecondaryRecoveryOwner: DashboardGatewayConnectionPoolDelegate {
    let secondary = GatewayProfile(id: "secondary", label: "Secondary", host: "secondary.example.test", port: 9847, machineId: "secondary-machine", machineGroupID: "secondary-group")
    let selected = GatewayProfile(id: "primary", label: "Primary", host: "primary.example.test", port: 9847, machineId: "primary-machine", machineGroupID: "primary-group")
    let transport = HostedSecondaryTransport()
    var state = "not started"
    var delay = "no wait"
    var waitHistory = ""
    var lastConnected = "never connected"
    var primary = "not connected"
    var started = false
    @ObservationIgnored private var primaryClient: GatewayClient?
    @ObservationIgnored lazy var pool = DashboardGatewayConnectionPool(clientFactory: { [transport] in
        GatewayClient(socketFactory: GatewaySocketFactory { _ in transport.next() })
    }, clock: MonotonicClock(now: { ContinuousClock().now }, sleep: { [weak self] duration in
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds >= 2 {
            await MainActor.run {
                self?.delay = "wait \(seconds)"
                if let self, self.waitHistory.count < 500 { self.waitHistory += "\(seconds)," }
            }
        }
        try await Task.sleep(for: .seconds(seconds / 100))
    }, gridOrigin: ContinuousClock().now))

    func start() async {
        guard !started else { return }
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in
            HostedIntegrationsSocket(gateway: HostedIntegrationsGateway(scenario: "default"), machineID: "primary-machine", machineGroupID: "primary-group")
        })
        primaryClient = client
        do {
            let identity = try await client.connectForLifecycle(profile: selected, token: "fixture-token")
            try await client.activateEvents(connectionID: identity.id)
            primary = "primary connected \(identity.id)"
            pool.delegate = self
            started = true
            reconcile()
        } catch { primary = "primary failed \(error)" }
    }
    func reconcile() {
        waitHistory = ""
        pool.reconcile(profiles: [selected, secondary], selectedProfileID: selected.id, token: { _ in "fixture-token" })
    }
    func retry() {
        waitHistory = ""
        pool.retry(profileID: secondary.id)
    }
    func lose() {
        waitHistory = ""
        transport.setOnline(false)
        Task { await transport.lose() }
    }
    func dashboardPoolDidUpdate(profileID: String, sessions: [SessionSummary], state: DashboardServerConnectionState, stopReason: String?) {
        self.state = String(describing: state)
        lastConnected = pool.lastConnectedAt(for: secondary.id).map { "last connected \($0.timeIntervalSince1970)" } ?? "never connected"
        Task {
            if await primaryClient?.activeConnectionID() == nil { primary = "primary disconnected" }
        }
    }
    func dashboardPoolNotificationInboxChanged(profileID: String, change: NotificationInboxChanged?) {}
    func dashboardPoolDidUpdateArchivedCount(profileID: String, count: Int?) {}
    func dashboardPoolDidPublishAuthoritativeCatalog(profileID: String) {}
}

private final class HostedSecondaryTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true
    private var socket: HostedIntegrationsSocket?
    func setOnline(_ value: Bool) { lock.withLock { online = value } }
    func next() -> any GatewaySocketConnection {
        lock.withLock {
            guard online else { return HostedSecondaryUnavailableSocket() }
            let socket = HostedIntegrationsSocket(gateway: HostedIntegrationsGateway(scenario: "default"), machineID: "secondary-machine", machineGroupID: "secondary-group")
            self.socket = socket
            return socket
        }
    }
    func lose() async {
        let socket = lock.withLock { self.socket }
        await socket?.loseNetworkConnection()
    }
}
private actor HostedSecondaryUnavailableSocket: GatewaySocketConnection {
    func send(_ data: Data) async throws { throw URLError(.cannotConnectToHost) }
    func receive() async throws -> Data { throw URLError(.cannotConnectToHost) }
    func ping() async throws { throw URLError(.cannotConnectToHost) }
    func close() async {}
}
#endif
