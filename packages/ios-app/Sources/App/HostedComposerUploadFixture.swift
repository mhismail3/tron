#if HOSTED_TEST
import SwiftUI
import TronMobileCore
import UniformTypeIdentifiers

/// The real chat, composer, paste path, draft coordinator and scene lifecycle;
/// only the Gateway is scripted. Upload staging mirrors the Gateway contract:
/// an unclaimed staged upload survives a reconnect to the same Mac, a prompt
/// claims staged IDs, and an unknown ID is `not_found` (#916).
///
/// The third upload attempt is held until the app backgrounds, then fails like
/// a transfer the suspended app lost. Uploads attempted while backgrounded fail
/// the same way. Scenario `lost-staging` also forgets every staged upload while
/// the app is away, as an expired or reset staging area would.
struct HostedComposerUploadFixture: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel
    @State private var ready = false
    @State private var chatOpening = 0
    @State private var counters = "starting"
    private let gateway: ComposerUploadGateway
    private let profile = GatewayProfile(id: "composer-upload", label: "Upload fixture", host: "upload.example.test", port: 9847, machineId: "upload-machine")

    init() {
        let args = ProcessInfo.processInfo.arguments
        let scenario = args.drop(while: { $0 != "-composer-upload-scenario" }).dropFirst().first ?? "reconnect"
        let gateway = ComposerUploadGateway(losesStagingInBackground: scenario == "lost-staging")
        self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(profile, token: "fixture-only-token")
        let root = FileManager.default.temporaryDirectory.appending(path: "composer-upload-fixture-\(UUID().uuidString)")
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in ComposerUploadSocket(gateway: gateway) }),
            profiles: profiles,
            cache: SnapshotCache(root: root.appending(path: "cache")),
            composerUpload: { name, mimeType, data in try await gateway.upload(data) },
            composerDraftStore: ComposerDraftStore(root: root.appending(path: "drafts"))
        ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if ready { ChatView(sessionID: "upload-session").id(chatOpening) }
                // Leaving and reopening the chat revokes and remounts its
                // presentation, the retry the old upload error asked for.
                Button("Reopen chat") { chatOpening += 1 }
                    .font(.caption2).accessibilityIdentifier("fixture.reopen-chat")
                Text(counters).font(.caption2).accessibilityIdentifier("fixture.upload-counts")
                Text("\(model.connectionState)").font(.caption2).accessibilityIdentifier("fixture.upload-connection")
            }
        }
        .environment(model)
        .tronPresentation()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.enteredBackground()
                Task { await gateway.setBackgrounded(true) }
            case .inactive: model.becameInactive()
            case .active:
                Task {
                    await gateway.setBackgrounded(false)
                    model.becameActive()
                }
            @unknown default: break
            }
        }
        .task { for await value in gateway.updates() { counters = value } }
        .task {
            // Four distinct photos on the system pasteboard; the journey pastes
            // them through the composer's own edit-menu Paste action.
            UIPasteboard.general.setItems(ComposerUploadGateway.photos.map { [UTType.png.identifier: $0] })
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-only-token")
                ready = true
            } catch { counters = "fixture-error:\(error.localizedDescription)" }
        }
    }
}

private actor ComposerUploadGateway {
    @MainActor static let photos: [Data] = [UIColor.red, .green, .blue, .orange].map { color in
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }.pngData()!
    }

    private let losesStagingInBackground: Bool
    private var backgrounded = false
    private var backgroundTransitions = 0
    private var attempts = 0
    /// Successful staging per photo index, and staging that happened after the
    /// photo was already staged once (the #916 regression).
    private var stagedCount: [Int: Int] = [:]
    private var restaged = 0
    private var staged: [String: Int] = [:]
    private var held: CheckedContinuation<Void, Never>?
    private var heldCount = 0
    private var prompts: [Int] = []
    private var rejectedPrompts = 0
    private var cameraUploads = 0
    private var continuations: [AsyncStream<String>.Continuation] = []

    init(losesStagingInBackground: Bool) { self.losesStagingInBackground = losesStagingInBackground }

    nonisolated func updates() -> AsyncStream<String> {
        AsyncStream { continuation in Task { await self.add(continuation) } }
    }
    private func add(_ continuation: AsyncStream<String>.Continuation) { continuations.append(continuation); publish() }
    private func publish() {
        let perPhoto = (0..<4).map { "\(stagedCount[$0, default: 0])" }.joined(separator: ",")
        let value = "attempts:\(attempts) staged:\(perPhoto) restaged:\(restaged) held:\(heldCount) "
            + "backgrounds:\(backgroundTransitions) prompts:\(prompts.map(String.init).joined(separator: ",")) rejected:\(rejectedPrompts) camera:\(cameraUploads)"
        continuations.forEach { $0.yield(value) }
    }

    func setBackgrounded(_ value: Bool) {
        guard backgrounded != value else { return }
        backgrounded = value
        if value {
            backgroundTransitions += 1
            if losesStagingInBackground { staged.removeAll() }
            held?.resume(); held = nil
        }
        publish()
    }

    func upload(_ data: Data) async throws -> String {
        let photos = await MainActor.run { Self.photos }
        // A camera capture (JPEG) from the hosted camera journey (#937).
        if data.starts(with: [0xFF, 0xD8]) {
            cameraUploads += 1
            publish()
            return UUID().uuidString.lowercased()
        }
        guard let index = photos.firstIndex(of: data) else { throw URLError(.badServerResponse) }
        attempts += 1
        publish()
        if backgrounded { throw URLError(.networkConnectionLost) }
        if attempts == 3, backgroundTransitions == 0 {
            heldCount += 1
            publish()
            await withCheckedContinuation { held = $0 }
            throw URLError(.networkConnectionLost)
        }
        if backgrounded { throw URLError(.networkConnectionLost) }
        let id = UUID().uuidString.lowercased()
        if stagedCount[index, default: 0] > 0 && !losesStagingInBackground { restaged += 1 }
        stagedCount[index, default: 0] += 1
        staged[id] = index
        publish()
        return id
    }

    func handle(_ method: String, params: [String: JSONValue]) -> Result<JSONValue, GatewayFailure>? {
        switch method {
        case "session.open":
            let session = params["sessionId"]?.stringValue ?? "upload-session"
            return .success(.object(["session": try! JSONValue.encode(Self.snapshot(session)), "syncToken": .string("fixture-sync"), "subscriptionToken": .string("fixture-subscription"), "completionRevision": .number(0)]))
        case "session.sync": return .success(.object(["synchronized": .bool(true)]))
        case "session.close": return .success(.object(["closed": .bool(true)]))
        case "session.commands": return .success(.object(["commands": .array([])]))
        case "session.attention.read": return .success(.object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)]))
        case "session.list": return .success(.object(["sessions": .array([])]))
        case "session.prompt":
            let ids = params["uploadIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            // Gateway materialization: every ID must name an unclaimed staged upload.
            guard ids.allSatisfy({ staged[$0] != nil }) else {
                rejectedPrompts += 1
                publish()
                return .failure(GatewayFailure(code: "not_found", message: "Upload was not found", retryable: false, details: nil))
            }
            let photos = Set(ids.compactMap { staged[$0] })
            ids.forEach { staged[$0] = nil }
            prompts.append(photos.count)
            publish()
            return .success(.object(["operationId": .string("upload-operation-\(prompts.count)")]))
        default: return nil
        }
    }

    private static func snapshot(_ sessionID: String) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: sessionID, runtimeGeneration: "upload-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: "Upload fixture", cwd: "/fixture", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: 0,
            transcriptTotal: 0, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "upload-host", revision: 1, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""), surfaces: [], pendingInteractions: []), diagnostics: [])
    }
}

private actor ComposerUploadSocket: GatewaySocketConnection {
    private let gateway: ComposerUploadGateway
    private var inbound: [Data]
    private var receiver: CheckedContinuation<Data, Error>?
    private var closed = false
    init(gateway: ComposerUploadGateway) {
        self.gateway = gateway
        inbound = [Data("{\"type\":\"hello\",\"gatewayVersion\":\"fixture\",\"piVersion\":\"fixture\",\"protocolVersion\":8,\"minProtocolVersion\":8,\"machineId\":\"upload-machine\",\"machineName\":\"Fixture\",\"gatewayChannel\":\"stable\",\"capabilities\":[\"sessions.v1\"]}".utf8)]
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
