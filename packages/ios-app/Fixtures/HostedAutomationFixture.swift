#if HOSTED_TEST
import Foundation
import SwiftUI
import TronMobileCore

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

final class AutomationFixtureProfileStore: GatewayProfileMetadataStoring, GatewayTokenStoring {
    private var document: GatewayProfileDocument?
    private var tokens: [String: String] = [:]
    func load() throws -> GatewayProfileDocument? { document }
    func save(_ document: GatewayProfileDocument) throws { self.document = document }
    func save(_ token: String, profileID: String) throws { tokens[profileID] = token }
    func read(profileID: String) throws -> String? { tokens[profileID] }
    func delete(profileID: String) throws { tokens.removeValue(forKey: profileID) }
}

struct HostedAutomationFixtureView: View {
    private let profile = GatewayProfile(id: "automation-fixture", label: "Studio server", host: "localhost", port: 9847, machineId: "fixture-automation")
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @State private var preferences = AutomationDashboardViewPreferences()
    @State private var automationsPresented = false
    @State private var dateControlsPresented = false
    @State private var dateControlsReady = false
    private let dateControlsSelection: AutomationSummarySelection
    @State private var openedSession: String?
    @State private var activity = PresentationActivityCoordinator()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let base = try! [
            AutomationPresentationFixture.record(),
            AutomationPresentationFixture.record(last: false, notification: true),
            AutomationPresentationFixture.record(activation: "enabled", current: true),
            AutomationPresentationFixture.record(activation: "paused"),
            AutomationPresentationFixture.record(activation: "enabled"),
        ]
        let names = ["Daily workspace review", "Daily reminder", "Project report", "A paused digest", "Zeta enabled check"]
        let large = arguments.contains("-automation-large")
        let records = try! (large ? (0..<400).map { base[$0 % base.count] } : base).enumerated().map { index, record in
            var fields = try JSONValue.encode(record).objectValue!
            if index == 0, arguments.contains("-automation-expiry") {
                fields["activation"] = .string("expired")
                fields["provenance"] = .object(["kind": .string("assistant"), "sessionId": .string("home-fixture"), "sourceId": .string("fixture-call"), "expiresAt": .string("2026-09-20T12:00:00Z")])
                fields["nextOccurrenceAt"] = .null
                fields["lastRun"] = .null
            }
            fields["id"] = .string("automation-\(index)")
            fields["name"] = .string(large ? "\(names[index % names.count]) \(index)" : names[index])
            return try JSONValue.object(fields).decode(GatewayAutomationRecord.self)
        }
        dateControlsSelection = AutomationSummarySelection(profileID: profile.id,
            summary: try! AutomationPresentationFixture.summary(records[0]))
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
            VStack {
                if let openedSession {
                    Text("Opened \(openedSession)").accessibilityIdentifier("automation-fixture-opened-session")
                }
                if let error {
                    Text(error)
                } else if !ready {
                    ProgressView()
                }
                Spacer()
                HStack {
                    Spacer()
                    if ready {
                        DashboardModeMenuButton(
                            onOpenAutomations: { automationsPresented = true },
                            onOpenApps: {},
                            actions: .init(settings: {}, creation: [])
                        )
                        .tronDashboardFloatingCircle(accent: .tronEmerald)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .automationsSheet(
                isPresented: $automationsPresented,
                preferences: $preferences,
                onOpenSession: { profileID, sessionID in
                    automationsPresented = false
                    openedSession = "\(profileID):\(sessionID)"
                }
            )
            .tronManagedSheet(isPresented: $dateControlsPresented, identity: "automation.fixture.date-controls") {
                AutomationFormView(selection: dateControlsSelection, onSaved: {})
                    .background(AutomationDateControlsViewport(onReady: { dateControlsReady = true }))
                    .overlay(alignment: .bottomLeading) {
                        if dateControlsReady {
                            Text("Date controls ready").font(.system(size: 1))
                                .accessibilityIdentifier("automation-date-controls-ready")
                        }
                    }
            }
        }
        .environment(model)
        .environment(\.tronPresentationActivityCoordinator, activity)
        .tronPresentation()
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-automation-dark") ? .dark : .light)
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                ready = true
                dateControlsPresented = ProcessInfo.processInfo.arguments.contains("-automation-date-controls")
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct AutomationDateControlsViewport: UIViewRepresentable {
    let onReady: () -> Void
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        guard context.coordinator.task == nil else { return }
        context.coordinator.task = Task { @MainActor [weak view] in
            do {
                try await Task.sleep(for: .seconds(1))
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    if let window = view?.window,
                       let scroll = Self.scroll(in: window), scroll.contentSize.height > scroll.bounds.height + 600 {
                        let end = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                        scroll.setContentOffset(CGPoint(x: 0, y: min(900, end)), animated: false)
                        onReady()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch { }
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.task?.cancel() }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var task: Task<Void, Never>? }
    private static func scroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height > 400,
           scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap { scroll(in: $0) }.first
    }
}

private actor HostedAutomationSocket: GatewaySocketConnection {
    private let records: [GatewayAutomationRecord]
    private var inbound = [Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-automation","machineName":"Studio server","gatewayChannel":"stable","capabilities":["automations.v2"]}"#.utf8)]
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
            let offset = frame["params"]?.objectValue?["cursor"]?.stringValue.flatMap(Int.init) ?? 0
            let page = records[offset..<min(records.count, offset + 100)]
            let summaries = try page.map { record -> JSONValue in
                var fields = try JSONValue.encode(AutomationPresentationFixture.summary(record)).objectValue!
                fields["updatedAt"] = .string("2026-09-01T08:00:00Z")
                return .object(fields)
            }
            let next: JSONValue = offset + 100 < records.count ? .string(String(offset + 100)) : .null
            result = .object(["catalogRevision": .number(1), "items": .array(summaries), "nextCursor": next])
        case "automation.get":
            guard let record else { throw CancellationError() }
            result = try JSONValue.encode(record)
        case "automation.run.list":
            result = .object(["runs": .array(try record?.lastRun.map { [try JSONValue.encode($0)] } ?? [])])
        case "automation.run.get":
            guard let run = record?.lastRun else { throw CancellationError() }
            result = try JSONValue.encode(run)
        default:
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
