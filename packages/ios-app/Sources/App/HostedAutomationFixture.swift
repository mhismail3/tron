#if HOSTED_TEST
import Foundation
import SwiftUI

enum AutomationPresentationFixture {
    static let updatedAt = "2026-09-20T10:30:00Z"
    static let startedAt = "2026-09-19T09:00:04Z"
    static let terminalAt = "2026-09-19T09:02:00Z"

    static func record(
        activation: String = "draft", current: Bool = false, last: Bool = true,
        workspace: Bool = false, notification: Bool = false
    ) throws -> GatewayAutomationRecord {
        let trigger: JSONValue = .object([
            "kind": .string("interval"), "everySeconds": .number(86_400),
            "anchorAt": .string("2026-09-01T09:00:00Z"),
        ])
        let action: JSONValue = notification
            ? .object(["kind": .string("notification"), "message": .string("Review the weekly report.")])
            : .object(["kind": .string("sessionPrompt"), "text": .string("Review the workspace and summarize changes since the previous run. Do not modify files.")])
        let target: JSONValue = workspace
            ? .object(["kind": .string("workspace"), "cwd": .string("/workspace/project"), "sessionPolicy": .string("newPerRun")])
            : .object(["kind": .string("existingSession"), "sessionId": .string("session-review")])
        func run(_ state: String, start: String) -> JSONValue {
            .object([
                "runId": .string("run-\(state)"), "occurrenceId": .string("occurrence-\(state)"),
                "automationRevision": .number(2), "scheduledFor": .string("2026-09-19T09:00:00Z"),
                "triggerSnapshot": trigger, "actionSnapshot": action, "state": .string(state),
                "createdAt": .string("2026-09-19T09:00:00Z"), "startedAt": .string(start),
                "terminalAt": state == "succeeded" ? .string(terminalAt) : .null,
                "preAdmissionAttemptCount": .number(0), "targetSnapshot": target,
                "executionSessionId": .string("session-review"),
            ])
        }
        return try JSONValue.object([
            "schemaVersion": .number(2), "id": .string("automation-review"),
            "revision": .number(2), "stateRevision": .number(3),
            "name": .string("Daily workspace review"), "activation": .string(activation),
            "createdAt": .string("2026-09-01T08:00:00Z"), "updatedAt": .string(updatedAt),
            "provenance": .object(["kind": .string("local")]),
            "target": target, "trigger": trigger, "action": action,
            "misfirePolicy": .string("latest"), "overlapPolicy": .string("skip"),
            "executionDeadlineSeconds": .number(3_600),
            "nextOccurrenceAt": .string("2026-09-21T09:00:00Z"),
            "currentRun": current ? run("running", start: "2026-09-20T09:00:02Z") : .null,
            "lastRun": last ? run("succeeded", start: startedAt) : .null,
            "consecutiveFailureCount": .number(activation == "blocked" ? 2 : 0),
            "blockedReason": activation == "blocked" ? .string("outcome-unknown") : .null,
            "history": .array([]),
        ]).decode(GatewayAutomationRecord.self)
    }

    static func summary(_ record: GatewayAutomationRecord) throws -> GatewayAutomationSummary {
        var fields = try JSONValue.encode(record).objectValue!
        fields["actionKind"] = .string(record.action.kind)
        return try JSONValue.object(fields).decode(GatewayAutomationSummary.self)
    }
}

/// The real profile owner with test-only in-memory stores: no credentials or
/// profile metadata are written by the hosted Automation detail regression.
final class AutomationFixtureProfileStore: GatewayProfileMetadataStoring, GatewayTokenStoring {
    private var document: GatewayProfileDocument?
    private var tokens: [String: String] = [:]
    func load() throws -> GatewayProfileDocument? { document }
    func save(_ document: GatewayProfileDocument) throws { self.document = document }
    func save(_ token: String, profileID: String) throws { tokens[profileID] = token }
    func read(profileID: String) throws -> String? { tokens[profileID] }
    func delete(profileID: String) throws { tokens.removeValue(forKey: profileID) }
}

/// Native UI tests exercise the real inventory, detail reads, tables and run
/// routing without opening a canonical session or sending a mutation.
struct HostedAutomationFixtureView: View {
    private let profile = GatewayProfile(id: "automation-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-automation")
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var preferences = AutomationDashboardViewPreferences(mode: .all)
    @State private var activity = PresentationActivityCoordinator()

    init() {
        let records = try! [
            AutomationPresentationFixture.record(),
            AutomationPresentationFixture.record(last: false, notification: true),
            AutomationPresentationFixture.record(activation: "enabled", current: true),
        ].enumerated().map { index, record in
            var fields = try JSONValue.encode(record).objectValue!
            fields["id"] = .string("automation-\(index)")
            fields["name"] = .string(["Daily workspace review", "Daily reminder", "Project report"][index])
            return try JSONValue.object(fields).decode(GatewayAutomationRecord.self)
        }
        let socket = HostedAutomationSocket(records: records)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in socket })
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-token")
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "hosted-automation-fixture"))))
    }

    var body: some View {
        TronPresentationSurface(id: "hosted-automation-fixture") {
            if ready {
                AutomationsDashboardView(viewPreferences: $preferences,
                    onSelectDashboard: { _ in }, onOpenSettings: {}, onOpenSession: { _, _ in })
            } else if let error {
                Text(error)
            } else {
                ProgressView()
            }
        }
        .environment(model)
        .environment(\.tronPresentationActivityCoordinator, activity)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                ready = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

private actor HostedAutomationSocket: GatewaySocketConnection {
    private let records: [GatewayAutomationRecord]
    private var inbound = [Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":5,"minProtocolVersion":5,"machineId":"fixture-automation","machineName":"Studio server","gatewayChannel":"stable","capabilities":["automations.v2"]}"#.utf8)]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    init(records: [GatewayAutomationRecord]) { self.records = records }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue else { return }
        let automationID = frame["params"]?.objectValue?["automationId"]?.stringValue
        let record = records.first { $0.id == automationID }
        let result: JSONValue
        switch frame["method"]?.stringValue {
        case "automation.status":
            result = .object(["ready": .bool(true), "degraded": .bool(false), "automationCount": .number(Double(records.count)), "aggregateBytes": .number(1_024), "malformedRecordCount": .number(0), "catalogRevision": .number(1)])
        case "automation.list":
            let summaries = try records.map { record -> JSONValue in
                var fields = try JSONValue.encode(AutomationPresentationFixture.summary(record)).objectValue!
                // The record read has a newer update timestamp than inventory.
                fields["updatedAt"] = .string("2026-09-01T08:00:00Z")
                return .object(fields)
            }
            result = .object(["catalogRevision": .number(1), "items": .array(summaries), "nextCursor": .null])
        case "automation.get":
            guard let record else { throw CancellationError() }
            result = try JSONValue.encode(record)
        case "automation.run.list":
            result = .object(["runs": .array(try record?.lastRun.map { [try JSONValue.encode($0)] } ?? [])])
        case "automation.run.get":
            guard let run = record?.lastRun else { throw CancellationError() }
            result = try JSONValue.encode(run)
        default:
            // This fixture intentionally never accepts automation mutations.
            enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(false),
                "error": .object(["code": .string("unsupported"), "message": .string("Read-only fixture"), "retryable": .bool(false)]),
            ])))
            return
        }
        enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result,
        ])))
    }

    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receivers.append($0) }
    }
    func close() async {
        closed = true
        let pending = receivers
        receivers.removeAll()
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
    private func enqueue(_ data: Data) {
        if receivers.isEmpty { inbound.append(data) }
        else { receivers.removeFirst().resume(returning: data) }
    }
}
#endif
