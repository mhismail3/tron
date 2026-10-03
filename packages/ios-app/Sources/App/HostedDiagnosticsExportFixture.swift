#if HOSTED_TEST
import SwiftUI
@testable import TronMobileCore

extension EnvironmentValues {
    @Entry var hostedDiagnosticsPreparation: (@MainActor @Sendable () async -> Void)? = nil
    @Entry var hostedDiagnosticsCapture: (@MainActor @Sendable (URL) async -> Void)? = nil
}

/// Real Logs, preparation, export and native share consumers. Only synthetic
/// transports and an explicitly test-only preparation suspension are supplied.
struct HostedDiagnosticsExportFixture: View {
    @Environment(\.scenePhase) private var phase
    @State private var model: AppModel
    @State private var ready = false
    @State private var originalCounts = ""
    @State private var replacementCounts = ""
    @State private var preparation = ""
    @State private var artifactEvidence = ""
    private let originalGateway: DiagnosticsExportFixtureGateway
    private let replacementGateway: DiagnosticsExportFixtureGateway
    private let gate: DiagnosticsExportPreparationGate
    private let store: AutomationFixtureProfileStore
    private let root: URL
    private let scenario: String
    private let original = GatewayProfile(id: "export-original", label: "Original fixture", host: "original.example.test", port: 9847, machineId: "export-original-machine")
    private let replacement = GatewayProfile(id: "export-replacement", label: "Replacement fixture", host: "replacement.example.test", port: 9847, machineId: "export-replacement-machine")

    init() {
        scenario = ProcessInfo.processInfo.arguments.drop(while: { $0 != "-diagnostics-export-scenario" }).dropFirst().first ?? "held"
        let first = DiagnosticsExportFixtureGateway(name: "original", fails: scenario == "failure" || scenario == "held-failure", holdsLogs: scenario == "logs-held")
        let second = DiagnosticsExportFixtureGateway(name: "replacement", fails: false)
        originalGateway = first; replacementGateway = second
        gate = DiagnosticsExportPreparationGate(held: scenario == "held" || scenario == "held-failure")
        let memory = AutomationFixtureProfileStore(); store = memory
        let profiles = GatewayProfileStore(metadata: memory, tokens: memory)
        try! profiles.save(original, token: "fixture-only-token")
        let client = GatewayClient(socketFactory: GatewaySocketFactory { request in
            let replacesAuthority = request.url?.host == "replacement.example.test"
            return DiagnosticsExportFixtureSocket(gateway: replacesAuthority ? second : first,
                name: replacesAuthority ? "replacement" : "original")
        })
        root = FileManager.default.temporaryDirectory.appending(path: "diagnostics-export-fixture-\(UUID().uuidString)")
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: root.appending(path: "cache")),
            exportArtifacts: SessionExportArtifactStore(root: root.appending(path: "artifacts"), maximumBytes: 524_288, maximumTotalBytes: 1_048_576, maximumArtifacts: 2),
            appLog: AppLog(fileURL: root.appending(path: "app.jsonl"))))
    }

    var body: some View {
        TronPresentationSurface(id: "fixture.diagnostics-export") {
            VStack(spacing: 0) {
                if ready {
                    NavigationStack { GatewayLogsSettingsView() }.tronSettingsLayout()
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                VStack(spacing: 3) {
                    Text(originalCounts).accessibilityIdentifier("fixture.export-original")
                    Text(replacementCounts).accessibilityIdentifier("fixture.export-replacement")
                    Text(preparation).accessibilityIdentifier("fixture.export-preparation")
                    Text("selected:\(model.profiles.selected?.id ?? "none") ready:\(model.diagnosticsAreReady) generation:\(model.knowledgeDestinationIdentity.lifecycleGeneration) connection:\(model.diagnosticConnectionID ?? -1)")
                        .accessibilityIdentifier("fixture.export-connection")
                    Text(model.noticeCenter.notices.map(\.title).joined(separator: " | "))
                        .accessibilityIdentifier("fixture.export-notices")
                    Text(artifactEvidence).accessibilityIdentifier("fixture.export-artifacts")
                    HStack {
                        Button("Replace Mac") {
                            Task {
                                try! model.profiles.save(replacement, token: "fixture-only-successor-token", selecting: false)
                                // Auxiliary source reads must not open real sockets. The
                                // fake original token is retired with its authority.
                                try! store.delete(profileID: original.id)
                                await model.switchGateway(replacement)
                            }
                        }.accessibilityIdentifier("fixture.replace-export-profile")
                        Button("Release preparation") { Task { await gate.release() } }
                            .accessibilityIdentifier("fixture.release-export-preparation")
                        Button("Inspect artifacts") { inspectArtifacts() }
                            .accessibilityIdentifier("fixture.inspect-export-artifacts")
                        Button("Return original") {
                            Task {
                                try! model.profiles.save(original, token: "fixture-only-token", selecting: false)
                                try! store.delete(profileID: replacement.id)
                                await model.switchGateway(original)
                            }
                        }.accessibilityIdentifier("fixture.return-export-profile")
                    }.buttonStyle(.bordered)
                }.font(.caption2).padding(6)
            }
        }
        .environment(model)
        .environment(\.hostedDiagnosticsPreparation, { await gate.prepare() })
        .environment(\.hostedDiagnosticsCapture, { url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let header = text.split(separator: "\n").first
                .flatMap { try? JSONDecoder().decode(AppLogRecord.self, from: Data($0.utf8)) }
            let fields = Dictionary(uniqueKeysWithValues: (header?.message.split(separator: " ") ?? []).compactMap { item -> (String, String)? in
                let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                return pair.count == 2 ? (pair[0], pair[1]) : nil
            })
            let rows = text.split(separator: "\n").dropFirst().compactMap {
                try? JSONDecoder().decode(AppLogRecord.self, from: Data($0.utf8))
            }
            let dates = rows.compactMap { GatewayTimestamp.parse($0.timestamp) }.sorted()
            let actualFrom = dates.first.map(GatewayTimestamp.preciseString(from:)) ?? "none"
            let actualThrough = dates.last.map(GatewayTimestamp.preciseString(from:)) ?? "none"
            let windowMatches = fields["exportedWindowFrom"] == actualFrom && fields["exportedWindowThrough"] == actualThrough
            artifactEvidence = "local:\(text.contains("captureKind=iphone-local") && text.contains("source=local-only")) selected:\(fields["selectedRecords"] ?? "unknown") dropped:\(fields["droppedRecords"] ?? "unknown") rows:\(rows.count) windowMatches:\(windowMatches) bytes:\(text.utf8.count)"
        })
        .tronPresentation().preferredColorScheme(.dark)
        .task {
            await model.appLog.recordCausal(name: "fixture.local.record", details: "synthetic-local-evidence")
            if scenario == "overflow" {
                for index in 0..<1_200 {
                    await model.appLog.recordCausal(
                        name: "fixture.overflow.\(index)",
                        details: String(repeating: "\n", count: 420)
                    )
                }
            }
            if scenario != "offline" { await model.start() }
            ready = true
        }
        .task { for await value in originalGateway.updates() { originalCounts = value } }
        .task { for await value in replacementGateway.updates() { replacementCounts = value } }
        .task { for await value in gate.updates() { preparation = value } }
        .task {
            guard scenario == "held-failure" else { return }
            while !Task.isCancelled {
                let warnings = await model.appLog.snapshot().filter { $0.event == "diagnostics.upload-failed" }
                guard !warnings.isEmpty else {
                    try? await Task.sleep(for: .milliseconds(25))
                    continue
                }
                try? await Task.sleep(for: .milliseconds(500))
                let directory = root.appending(path: "artifacts")
                let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .filter { $0.pathExtension == "jsonl" }
                artifactEvidence += " fallback-settled files:\(files.count)"
                return
            }
        }
        .onChange(of: phase) { _, value in
            switch value {
            case .background: model.enteredBackground()
            case .inactive: model.becameInactive()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
    }

    private func inspectArtifacts() {
        let directory = root.appending(path: "artifacts")
        let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
        let captures = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let local = captures.contains { $0.contains("captureKind=iphone-local") && $0.contains("source=local-only") }
        Task {
            let warnings = await model.appLog.snapshot().filter { $0.event == "diagnostics.upload-failed" && $0.level == "warning" }.count
            artifactEvidence = "files:\(files.count) local:\(local) warnings:\(warnings)"
        }
    }
}

private actor DiagnosticsExportPreparationGate {
    private let held: Bool
    private var waiting: CheckedContinuation<Void, Never>?
    private var streams: [AsyncStream<String>.Continuation] = []
    init(held: Bool) { self.held = held }
    nonisolated func updates() -> AsyncStream<String> { AsyncStream { c in Task { await self.add(c) } } }
    private func add(_ c: AsyncStream<String>.Continuation) { streams.append(c); c.yield("waiting:0 released:0") }
    func prepare() async {
        guard held else { return }
        await withCheckedContinuation { waiting = $0; streams.forEach { $0.yield("waiting:1 released:0") } }
    }
    func release() {
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume()
        streams.forEach { $0.yield("waiting:0 released:1") }
    }
}

private actor DiagnosticsExportFixtureGateway {
    private let name: String
    private let fails: Bool
    private let holdsLogs: Bool
    private var logs = 0
    private var logWaiter: CheckedContinuation<Void, Never>?
    private var exports = 0, repeats = 0
    private var commands: Set<String> = []
    private var originalEvidence = false
    private var streams: [AsyncStream<String>.Continuation] = []
    init(name: String, fails: Bool, holdsLogs: Bool = false) { self.name = name; self.fails = fails; self.holdsLogs = holdsLogs }
    nonisolated func updates() -> AsyncStream<String> { AsyncStream { c in Task { await self.add(c) } } }
    private func add(_ c: AsyncStream<String>.Continuation) { streams.append(c); publish() }
    private func publish() {
        streams.forEach { $0.yield("logs:\(logs) exports:\(exports) commands:\(commands.count) repeats:\(repeats) originalEvidence:\(originalEvidence)") }
    }
    func handle(_ method: String, params: [String: JSONValue]) async -> (result: JSONValue?, error: JSONValue?) {
        switch method {
        case "system.logs":
            logs += 1
            publish()
            if holdsLogs { await withCheckedContinuation { logWaiter = $0 } }
            return (.object(["records": .array([.object(["timestamp": .string(ISO8601DateFormatter().string(from: .now)), "level": .string("info"), "event": .string("fixture.\(name).record"), "message": .string("synthetic-\(name)-evidence")])])]), nil)
        case "system.logs.export":
            exports += 1
            let commandID = params["commandId"]?.stringValue ?? "missing"
            if !commands.insert(commandID).inserted { repeats += 1 }
            originalEvidence = params["content"]?.stringValue?.contains("fixture.original.record") == true
            publish()
            if fails { return (nil, .object(["code": .string("fixture_failed"), "message": .string("Synthetic export rejected"), "retryable": .bool(false)])) }
            return (.object(["path": .string("/fixture/\(name)/diagnostics.jsonl"), "exportedAt": .string("2026-10-02T18:00:00Z")]), nil)
        case "session.list", "session.listUpdated": return (.object(["sessions": .array([])]), nil)
        case "system.metadata": return (.object([:]), nil)
        case "attention.list": return (.object(["items": .array([])]), nil)
        default: return (nil, nil)
        }
    }
}

private actor DiagnosticsExportFixtureSocket: GatewaySocketConnection {
    private let gateway: DiagnosticsExportFixtureGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: DiagnosticsExportFixtureGateway, name: String) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":6,\"minProtocolVersion\":6,\"machineId\":\"export-\(name)-machine\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\",\"diagnostic-export.v1\"]}".utf8)]
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
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
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
