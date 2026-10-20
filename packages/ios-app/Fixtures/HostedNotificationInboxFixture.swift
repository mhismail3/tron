#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// The real Settings sheet, bell, inbox coordinator, `GatewayClient` and event
/// intake; only the selected Gateway is scripted. Its inbox mirrors the
/// Gateway contract (`notification.inbox.list/read/readAll` and a coalesced
/// `notification.inbox.changed` after every commit). A second paired Mac is
/// unreachable, so its dashboard connection stays offline (#938).
///
/// The UI test changes the Gateway's inbox while the sheet is open by posting
/// Darwin notifications: `deliver` admits a new unread alert and `read-newest`
/// marks the newest unread row read, as another device would.
/// Scenario `empty` starts with no notifications.
struct HostedNotificationInboxFixture: View {
    static let deliverNotification = "com.tron.hosted.notification-inbox.deliver"
    static let readNewestNotification = "com.tron.hosted.notification-inbox.read-newest"

    @State private var model: AppModel
    @State private var ready = false
    @State private var status = "starting"
    private let gateway: NotificationInboxGateway
    private let profile = GatewayProfile(id: "inbox-studio", label: "Studio Mac", host: "studio.example.test", port: 9847, machineId: "inbox-studio-machine")

    init() {
        let args = ProcessInfo.processInfo.arguments
        let scenario = args.drop(while: { $0 != "-notification-inbox-scenario" }).dropFirst().first ?? "mixed"
        let gateway = NotificationInboxGateway(seeded: scenario != "empty")
        self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-only-token")
        // `.invalid` never resolves, so this Mac's dashboard connection is offline.
        try! profiles.save(
            GatewayProfile(id: "inbox-laptop", label: "MacBook", host: "macbook.invalid", port: 9847, machineId: "inbox-laptop-machine"),
            token: "fixture-only-token",
            selecting: false
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "notification-inbox-fixture-\(UUID().uuidString)")
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in NotificationInboxSocket(gateway: gateway) }),
            profiles: profiles,
            cache: SnapshotCache(root: root.appending(path: "cache"))
        ))
    }

    var body: some View {
        Group {
            if ready {
                SettingsView()
            } else {
                Text(status).accessibilityIdentifier("fixture.inbox-status")
            }
        }
        .environment(model)
        .tronPresentation()
        .tronSettingsLayout()
        .task {
            DarwinTrigger.observe(Self.deliverNotification) { Task { await gateway.deliver() } }
            DarwinTrigger.observe(Self.readNewestNotification) { Task { await gateway.readNewestUnread() } }
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-only-token")
                // The hosted connect skips the connected callback's catalog read;
                // rows are titled from this catalog.
                _ = await model.refreshSessions()
                ready = true
            } catch { status = "fixture-error:\(error.localizedDescription)" }
        }
    }
}

/// A process-wide Darwin notification is the only channel the UI test runner
/// shares with the app; each observer lives for the fixture process. Shared by
/// the hosted fixtures whose controls a presented sheet would cover.
enum DarwinTrigger {
    private final class Box { let action: () -> Void; init(_ action: @escaping () -> Void) { self.action = action } }

    static func observe(_ name: String, action: @escaping @MainActor () -> Void) {
        let box = Unmanaged.passRetained(Box { DispatchQueue.main.async { MainActor.assumeIsolated(action) } })
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            box.toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().action()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }
}

private actor NotificationInboxGateway {
    private struct Row {
        let id: String
        let kind: NotificationInboxKind
        let createdAt: Date
        var readAt: Date?
        let title: String
        let message: String
        let sessionId: String
    }

    private static let sessions: [(id: String, name: String)] = [
        ("inbox-session-release", "Release checklist"),
        ("inbox-session-refactor", "Refactor inbox rows"),
        ("inbox-session-docs", "Docs sweep"),
    ]

    private var rows: [Row] = []
    private var revision = 1
    private var delivered = 0
    private var sockets: [NotificationInboxSocket] = []

    init(seeded: Bool) {
        guard seeded else { return }
        let now = Date()
        rows = [
            Row(id: "inbox-row-ask", kind: .ask, createdAt: now.addingTimeInterval(-90), title: "Input needed",
                message: "Tron needs your input. Open Tron to respond.", sessionId: "inbox-session-release"),
            Row(id: "inbox-row-finished", kind: .agentFinished, createdAt: now.addingTimeInterval(-60 * 14),
                title: "Refactor inbox rows", message: "Finished: the row list now follows the shared settings row.",
                sessionId: "inbox-session-refactor"),
            Row(id: "inbox-row-home", kind: .agentFinished, createdAt: now.addingTimeInterval(-60 * 52), readAt: now,
                title: "Home", message: "Your morning summary is ready.", sessionId: "inbox-home-session"),
            Row(id: "inbox-row-waiting", kind: .waiting, createdAt: now.addingTimeInterval(-60 * 60 * 3), readAt: now,
                title: "Docs sweep", message: "Still waiting on 2 background tasks.", sessionId: "inbox-session-docs"),
            Row(id: "inbox-row-alert", kind: .explicit, createdAt: now.addingTimeInterval(-60 * 60 * 26), readAt: now,
                title: "Release checklist", message: "Build 412 passed every journey and is ready to ship.",
                sessionId: "inbox-session-release"),
        ]
    }

    func attach(_ socket: NotificationInboxSocket) { sockets.append(socket) }

    func deliver() async {
        delivered += 1
        rows.append(Row(
            id: "inbox-row-live-\(delivered)", kind: .ask, createdAt: Date(), title: "Input needed",
            message: "Live alert \(delivered): Tron needs your input.", sessionId: "inbox-session-docs"
        ))
        await commit()
    }

    func readNewestUnread() async {
        guard let index = ordered.firstIndex(where: { $0.readAt == nil }),
              let rowIndex = rows.firstIndex(where: { $0.id == ordered[index].id }) else { return }
        rows[rowIndex].readAt = Date()
        await commit()
    }

    private var ordered: [Row] {
        rows.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    private var unreadCount: Int { rows.filter { $0.readAt == nil }.count }

    private func commit() async {
        revision += 1
        let payload: JSONValue = .object(["revision": .string("rev-\(revision)"), "unreadCount": .number(Double(unreadCount))])
        for socket in sockets { await socket.emit("notification.inbox.changed", payload: payload) }
    }

    private func wire(_ row: Row) -> JSONValue {
        let created = GatewayTimestamp.string(from: row.createdAt)
        return .object([
            "version": .number(1), "id": .string(row.id), "kind": .string(row.kind.rawValue),
            "createdAt": .string(created),
            "updatedAt": .string(row.readAt.map { GatewayTimestamp.string(from: max($0, row.createdAt)) } ?? created),
            "title": .string(row.title), "message": .string(row.message), "sessionId": .string(row.sessionId),
            "isUnread": .bool(row.readAt == nil), "outcome": .string("accepted_by_apns"),
        ])
    }

    private func position(_ row: Row) -> NotificationInboxPosition {
        NotificationInboxPosition(milliseconds: Int((row.createdAt.timeIntervalSince1970 * 1_000).rounded()), id: row.id)
    }

    func handle(_ method: String, params: [String: JSONValue]) async -> Result<JSONValue, GatewayFailure>? {
        switch method {
        case "notification.inbox.list":
            let unreadOnly = params["filter"]?.stringValue == "unread"
            let page = ordered.filter { !unreadOnly || $0.readAt == nil }
            return .success(.object([
                "notifications": .array(page.map(wire)), "revision": .string("rev-\(revision)"),
                "unreadCount": .number(Double(unreadCount)),
            ]))
        case "notification.inbox.read":
            guard let id = params["id"]?.stringValue, let index = rows.firstIndex(where: { $0.id == id }) else {
                return .success(.object(["changed": .bool(false)]))
            }
            let changed = rows[index].readAt == nil
            if changed { rows[index].readAt = Date() }
            if changed { await commit() }
            return .success(.object(["changed": .bool(changed), "id": .string(id)]))
        case "notification.inbox.readAll":
            guard let through = params["through"]?.stringValue.flatMap(NotificationInboxPosition.init(cursor:)) else {
                return .failure(GatewayFailure(code: "invalid_request", message: "Invalid cut", retryable: false, details: nil))
            }
            var changed = 0
            for index in rows.indices where rows[index].readAt == nil && position(rows[index]) >= through {
                rows[index].readAt = Date()
                changed += 1
            }
            if changed > 0 { await commit() }
            return .success(.object(["changed": .number(Double(changed))]))
        case "session.list":
            let now = GatewayTimestamp.string(from: Date())
            let summaries = Self.sessions.map {
                SessionSummary(id: $0.id, name: $0.name, cwd: "/workspace/tron", parentSessionId: nil,
                               createdAt: now, updatedAt: now, messageCount: 4, firstMessage: $0.name, phase: .idle,
                               summaryRevision: 1)
            }
            return .success(.object(["sessions": try! JSONValue.encode(summaries), "nextCursor": .null,
                "listRevision": .number(1), "projectionToken": .string("inbox-fixture:1"), "archivedCount": .number(0)]))
        default:
            return nil
        }
    }
}

private actor NotificationInboxSocket: GatewaySocketConnection {
    private let gateway: NotificationInboxGateway
    private var inbound: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false

    init(gateway: NotificationInboxGateway) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"inbox-studio-machine\",\"machineName\":\"Studio Mac\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
        Task { await gateway.attach(self) }
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let request = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard let id = request["id"]?.stringValue, let method = request["method"]?.stringValue else { return }
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id)]
        switch await gateway.handle(method, params: request["params"]?.objectValue ?? [:]) {
        case .success(let result)?:
            response["ok"] = .bool(true); response["result"] = result
        case .failure(let failure)?:
            response["ok"] = .bool(false)
            response["error"] = .object(["code": .string(failure.code), "message": .string(failure.message), "retryable": .bool(failure.retryable)])
        case nil:
            response["ok"] = .bool(false)
            response["error"] = .object(["code": .string("fixture_unsupported"), "message": .string("Optional fixture read"), "retryable": .bool(false)])
        }
        deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
    }

    func emit(_ topic: String, payload: JSONValue) {
        guard !closed, let data = try? JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("event"), "topic": .string(topic), "payload": payload])) else { return }
        deliver(data)
    }

    func ping() async throws { if closed { throw CancellationError() } }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async { closed = true; receiver?.resume(throwing: CancellationError()); receiver = nil }
    private func deliver(_ data: Data) { if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { inbound.append(data) } }
}
#endif
