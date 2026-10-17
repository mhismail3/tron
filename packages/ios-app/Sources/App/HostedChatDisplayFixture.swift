#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Real chat and media loader for out-of-process menu/status-bar gestures.
@MainActor
struct HostedChatDisplayFixture: View {
    static let imageTranscriptData = Data(#"""
        [
          {"id":"image-request","parentId":null,"presentationId":"image-request","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"image-call-content","ordinal":0,"type":"toolCall","toolCallId":"image-call","name":"display","arguments":{"presentation":{"surface":"inline"}}}]},
          {"id":"image-result","parentId":"image-request","presentationId":"image-result","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"image-result-text","ordinal":0,"type":"text","text":"Displayed Orientation Image."}],"toolCallId":"image-call","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"orientation-image","revision":1,"title":"Orientation Image","altText":"Red above blue, with the close badge at top right.","kind":"image","presentation":{"requestedSurface":"inline","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Orientation Image","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc40","name":"orientation.png","mimeType":"image/png","size":1024,"kind":"image"}}}
        ]
        """#.utf8)
    /// Finalized parallel groups: four sheet photos and a PDF, then a mixed run whose
    /// generic calls keep their grouped chip around a row of display thumbnails.
    static let groupedDisplayTranscriptData = Data(#"""
        [
          {"id":"displays-request","parentId":null,"presentationId":"displays-request","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"shot-1-content","ordinal":0,"type":"toolCall","toolCallId":"shot-1","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"display-group","groupIndex":0,"groupCount":5,"groupFinalized":true},{"id":"shot-2-content","ordinal":1,"type":"toolCall","toolCallId":"shot-2","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"display-group","groupIndex":1,"groupCount":5,"groupFinalized":true},{"id":"shot-3-content","ordinal":2,"type":"toolCall","toolCallId":"shot-3","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"display-group","groupIndex":2,"groupCount":5,"groupFinalized":true},{"id":"shot-4-content","ordinal":3,"type":"toolCall","toolCallId":"shot-4","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"display-group","groupIndex":3,"groupCount":5,"groupFinalized":true},{"id":"shot-5-content","ordinal":4,"type":"toolCall","toolCallId":"shot-5","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"display-group","groupIndex":4,"groupCount":5,"groupFinalized":true}]},
          {"id":"shot-1-result","parentId":"displays-request","presentationId":"shot-1-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"shot-1-result-text","ordinal":0,"type":"text","text":"Displayed Failure after swap."}],"toolCallId":"shot-1","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-shot-1","revision":1,"title":"Failure after swap","altText":"Swap failure state","kind":"image","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Failure after swap","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc51","name":"display-shot-1.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"shot-2-result","parentId":"displays-request","presentationId":"shot-2-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"shot-2-result-text","ordinal":0,"type":"text","text":"Displayed Progress sheet: live, then succeeded."}],"toolCallId":"shot-2","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-shot-2","revision":1,"title":"Progress sheet: live, then succeeded","altText":"Progress sheet","kind":"image","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Progress sheet: live, then succeeded","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc52","name":"display-shot-2.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"shot-3-result","parentId":"displays-request","presentationId":"shot-3-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"shot-3-result-text","ordinal":0,"type":"text","text":"Displayed Replace Mac App row (running)."}],"toolCallId":"shot-3","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-shot-3","revision":1,"title":"Replace Mac App row (running)","altText":"Replace row","kind":"image","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Replace Mac App row (running)","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc53","name":"display-shot-3.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"shot-4-result","parentId":"displays-request","presentationId":"shot-4-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"shot-4-result-text","ordinal":0,"type":"text","text":"Displayed Settings after replace."}],"toolCallId":"shot-4","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-shot-4","revision":1,"title":"Settings after replace","altText":"Settings row","kind":"image","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Settings after replace","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc54","name":"display-shot-4.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"shot-5-result","parentId":"displays-request","presentationId":"shot-5-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"shot-5-result-text","ordinal":0,"type":"text","text":"Displayed Release notes."}],"toolCallId":"shot-5","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-shot-5","revision":1,"title":"Release notes","altText":"Release notes document","kind":"pdf","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline"],"fallbackText":"Release notes","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc57","name":"release-notes.pdf","mimeType":"application/pdf","size":1024,"kind":"pdf"}}},
          {"id":"summary","parentId":null,"presentationId":"summary","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"summary-text","ordinal":0,"type":"text","text":"Mixed run below: a read, two displays, then a shell command."}]},
          {"id":"mixed-request","parentId":null,"presentationId":"mixed-request","timestamp":"2026-01-01T00:00:04Z","kind":"message","role":"assistant","content":[{"id":"mix-read-content","ordinal":0,"type":"toolCall","toolCallId":"mix-read","name":"read","arguments":{"path":"README.md"},"groupId":"mixed-group","groupIndex":0,"groupCount":4,"groupFinalized":true},{"id":"mix-shot-1-content","ordinal":1,"type":"toolCall","toolCallId":"mix-shot-1","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"mixed-group","groupIndex":1,"groupCount":4,"groupFinalized":true},{"id":"mix-shot-2-content","ordinal":2,"type":"toolCall","toolCallId":"mix-shot-2","name":"display","arguments":{"presentation":{"surface":"sheet"}},"groupId":"mixed-group","groupIndex":2,"groupCount":4,"groupFinalized":true},{"id":"mix-bash-content","ordinal":3,"type":"toolCall","toolCallId":"mix-bash","name":"bash","arguments":{"command":"ls"},"groupId":"mixed-group","groupIndex":3,"groupCount":4,"groupFinalized":true}]},
          {"id":"mix-read-result","parentId":"mixed-request","presentationId":"mix-read-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"mix-read-result-text","ordinal":0,"type":"text","text":"ok"}],"toolCallId":"mix-read","toolName":"read","isError":false},
          {"id":"mix-shot-1-result","parentId":"mixed-request","presentationId":"mix-shot-1-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"mix-shot-1-result-text","ordinal":0,"type":"text","text":"Displayed Mixed photo one."}],"toolCallId":"mix-shot-1","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-mix-shot-1","revision":1,"title":"Mixed photo one","altText":"Mixed one","kind":"image","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Mixed photo one","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc55","name":"display-mix-shot-1.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"mix-shot-2-result","parentId":"mixed-request","presentationId":"mix-shot-2-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"mix-shot-2-result-text","ordinal":0,"type":"text","text":"Displayed Mixed photo two."}],"toolCallId":"mix-shot-2","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-mix-shot-2","revision":1,"title":"Mixed photo two","altText":"Mixed two","kind":"image","presentation":{"requestedSurface":"sheet","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Mixed photo two","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc56","name":"display-mix-shot-2.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"mix-bash-result","parentId":"mixed-request","presentationId":"mix-bash-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"mix-bash-result-text","ordinal":0,"type":"text","text":"ok"}],"toolCallId":"mix-bash","toolName":"bash","isError":false}
        ]
        """#.utf8)
    /// A finalized parallel group of inline image displays, the shape an agent
    /// produces when it shows several screenshots at once. Each completed
    /// inline image keeps its collapse disclosure inside the grouped row.
    static let inlineGroupTitles = [
        "Home dashboard after the fix", "Usage sheet with rounded rows",
        "Settings: This iPhone switch", "Worker list scrolled to the end",
    ]

    static func inlineGroupCall() -> [String: Any] {
        let calls: [[String: Any]] = inlineGroupTitles.indices.map { index in
            ["id": "inline-\(index)-content", "ordinal": index, "type": "toolCall", "toolCallId": "inline-\(index)",
             "name": "display", "arguments": ["presentation": ["surface": "inline"]],
             "groupId": "inline-group", "groupIndex": index, "groupCount": inlineGroupTitles.count, "groupFinalized": true]
        }
        return ["id": "inline-request", "parentId": NSNull(), "presentationId": "inline-request",
                "timestamp": "2026-01-01T00:00:05Z", "kind": "message", "role": "assistant", "content": calls]
    }

    static func inlineGroupResults() -> [[String: Any]] {
        inlineGroupTitles.enumerated().map { index, title in
            ["id": "inline-\(index)-result", "parentId": "inline-request", "presentationId": "inline-\(index)-result",
             "timestamp": "2026-01-01T00:00:06Z", "kind": "message", "role": "toolResult",
             "content": [["id": "inline-\(index)-result-text", "ordinal": 0, "type": "text", "text": "Displayed \(title)."]],
             "toolCallId": "inline-\(index)", "toolName": "display", "isError": false,
             "display": ["schema": "tron.display.v1", "displayId": "display-inline-\(index)", "revision": 1, "title": title,
                         "altText": "Inline \(index + 1)", "kind": "image",
                         "presentation": ["requestedSurface": "inline", "inlineTapAction": "sheet"],
                         "eligibleSurfaces": ["sheet", "inline", "floating"], "fallbackText": title,
                         "artifact": ["id": "6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc6\(index)", "name": "inline-\(index).png",
                                      "mimeType": "image/png", "size": 1024, "kind": "image"]]]
        }
    }

    private static func items(_ objects: [[String: Any]]) -> [TranscriptItem] {
        try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: objects))
    }

    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    private let profile: GatewayProfile
    private let snapshot: SessionSnapshot
    private let socket: HostedChatDisplaySocket
    private let probe = ChatHostedProbe()
    /// `-chat-display-inline-group` reopens a chat whose grouped inline displays
    /// are already in history; `-chat-display-inline-group-live` opens the chat
    /// without them and delivers the call, then its results, as live
    /// `session.snapshot` events on the same mounted transcript.
    private static var inlineGroupLive: Bool { ProcessInfo.processInfo.arguments.contains("-chat-display-inline-group-live") }
    private static var inlineGroup: Bool {
        inlineGroupLive || ProcessInfo.processInfo.arguments.contains("-chat-display-inline-group")
    }

    init() {
        let defaults = UserDefaults(suiteName: "chat-display-fixture")!
        defaults.removePersistentDomain(forName: "chat-display-fixture")
        profile = GatewayProfile(id: "display-fixture", label: "Fixture", host: "gateway.test", port: 9847,
            machineId: "fixture-machine", deviceId: "fixture-device")
        defaults.set(try! JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let socket = HostedChatDisplaySocket()
        self.socket = socket
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 160, height: 80))
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 80, width: 160, height: 80))
        }.pngData()!
        _model = State(initialValue: AppModel(
            client: GatewayClient(socketFactory: GatewaySocketFactory { _ in socket }),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "chat-display-fixture")),
            chatMediaFetch: { _ in ChatMediaPayload(data: image, mimeType: "image/png") }
        ))
        var snapshot = SessionSnapshot(
            sessionId: "display-fixture", runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: "Display fixture", cwd: "/workspace", parentSessionId: nil, model: nil,
            thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
            stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                               tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
            queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: nil,
            transcriptTotal: nil, streaming: nil, leafEntryId: nil, operation: nil, retry: nil, toolExecutions: [],
            extensionPresentation: ExtensionPresentationState(
                version: 3, hostEpoch: "fixture-host", revision: 1, capabilities: [], diagnostics: [],
                semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil,
                                     widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                surfaces: [], pendingInteractions: []
            ), diagnostics: []
        )

        let history = (0..<30).map { index in
            ["id": "history-\(index)", "presentationId": "history-\(index)", "timestamp": "2026-01-01T00:00:00Z",
             "kind": "message", "role": "assistant", "content": [["id": "text-\(index)", "ordinal": 0,
             "type": "text", "text": index == 0 ? "Oldest loaded history" : "History row \(index). A bounded fixture paragraph for the reader."]]] as [String: Any]
        }
        snapshot.transcript = try! JSONDecoder.gateway.decode([TranscriptItem].self, from: JSONSerialization.data(withJSONObject: history))
        if Self.inlineGroup {
            if !Self.inlineGroupLive { snapshot.transcript += Self.items([Self.inlineGroupCall()] + Self.inlineGroupResults()) }
        } else {
            let fixtureTranscript = ProcessInfo.processInfo.arguments.contains("-chat-display-grouped")
                ? Self.groupedDisplayTranscriptData : Self.imageTranscriptData
            snapshot.transcript += try! JSONDecoder.gateway.decode([TranscriptItem].self, from: fixtureTranscript)
        }
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = snapshot.transcript.count
        self.snapshot = snapshot
    }

    var body: some View {
        NavigationStack {
            if ready {
                ChatView(sessionID: snapshot.sessionId, hostedProbe: probe)
            } else if let error { Text(error) }
        }
        .environment(model)
        .preferredColorScheme(.dark)
        .tronPresentation()
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.invalidateHostedPendingPresentation()
                model.installHostedSubscribedSnapshot(snapshot)
                probe.fixtureOpenPresentation = {
                    guard let target = model.presentationTarget(for: snapshot.sessionId) else { throw CancellationError() }
                    return target.generation
                }
                ready = true
                if Self.inlineGroupLive { try await deliverInlineGroupLive() }
            } catch { self.error = String(describing: error) }
        }
    }

    /// The call arrives first (its displays still preparing), then every result,
    /// each as the Gateway's live snapshot event for the open session.
    private func deliverInlineGroupLive() async throws {
        var live = snapshot
        for appended in [[Self.inlineGroupCall()], Self.inlineGroupResults()] {
            try await Task.sleep(for: .seconds(1))
            live.transcript += Self.items(appended)
            live.transcriptTotal = live.transcript.count
            live.revision += 1
            live.eventSequence += 1
            await socket.deliver(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("event"), "topic": .string("session.snapshot"), "sessionId": .string(live.sessionId),
                "payload": try JSONValue.encode(live)])))
        }
    }
}

/// Retains the actual mounted Manage Home action to exercise a callback after route replacement.
@MainActor
final class HostedHomeActionProbe {
    var pause: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var hostedHomeActionProbe: HostedHomeActionProbe? = nil
}

@MainActor
struct HostedHomeDashboardFixture: View {
    @State private var model: AppModel
    @State private var ready = false
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var homeStatusCount = 0
    @State private var taskListReads = 0
    @State private var taskStatusReads = 0
    @State private var sheetReadPeak = 0
    @State private var homeReads = ""
    @State private var reconnectRequested = false
    @State private var configuredModel = "none"
    @State private var controlCount = 0
    @State private var abortCount = 0
    @State private var staleActionFinished = false
    @State private var promptRoute = "none"
    @State private var openedSession = "none"
    @State private var settingsDecisionState = "none"
    @State private var newWorkerAdded = false
    @State private var firstRevealAt: Date?
    private let actionProbe = HostedHomeActionProbe()
    private let arguments = ProcessInfo.processInfo.arguments
    private let profile = GatewayProfile(id: "home-shell-fixture", label: "Home fixture", host: "localhost", port: 9847, machineId: "home-shell-fixture")
    private let gateway: HostedHomeShellGateway
    private let homeActivity = PresentationActivityCoordinator()

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let capabilityEnabled = !arguments.contains("-home-capability-absent")
        let initialState = arguments.first(where: { $0.hasPrefix("-home-shell-") })?.replacingOccurrences(of: "-home-shell-", with: "") ?? "undesignated"
        let gateway = HostedHomeShellGateway(capabilityEnabled: capabilityEnabled, initialState: initialState,
            phase: arguments.first(where: { $0.hasPrefix("-home-phase-") })?.replacingOccurrences(of: "-home-phase-", with: ""),
            unresolved: arguments.contains("-home-control-unresolved"),
            delayed: arguments.contains("-home-control-delayed"),
            browserState: arguments.first(where: { $0.hasPrefix("-home-browser-") })?.replacingOccurrences(of: "-home-browser-", with: ""),
            emptyContext: arguments.contains("-home-context-empty"),
            sheetState: arguments.first(where: { $0.hasPrefix("-home-sheet-") })?.replacingOccurrences(of: "-home-sheet-", with: ""),
            settingsApprovals: arguments.contains("-home-settings-approvals"),
            terminalEnabled: !arguments.contains("-home-terminal-unsupported"))
        self.gateway = gateway
        let store = AutomationFixtureProfileStore()
        let profiles = GatewayProfileStore(metadata: store, tokens: store)
        try! profiles.save(GatewayProfile(id: "home-shell-fixture", label: "Home fixture", host: "localhost", port: 9847, machineId: "home-shell-fixture"), token: "fixture-token")
        try! profiles.save(GatewayProfile(id: "competing-profile", label: "Other Mac", host: "other.example.test", port: 9847, machineId: "other-machine"), token: "other-fixture-token", selecting: false)
        let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in HostedHomeShellSocket(gateway: gateway) })
        _model = State(initialValue: AppModel(client: client, profiles: profiles,
            cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: "home-shell-fixture"))))
    }

    var body: some View {
        Group {
            if ready {
                SessionShellView()
                    .environment(model)
                    .environment(\.hostedHomeActionProbe, actionProbe)
                    .environment(\.tronPresentationActivityCoordinator, homeActivity)
                    .background {
                        InAppNoticeWindowInstaller(model: model, colorScheme: .light, presentationActivity: homeActivity)
                            .frame(width: 0, height: 0).allowsHitTesting(false)
                    }
                    .tronPresentation()
                    .tronSettingsLayout()
                    .overlay(alignment: .top) {
                        VStack {
                            if staleActionFinished {
                                Text("Stale action finished").accessibilityIdentifier("fixture.stale-action-finished")
                            }
                            Text(model.homeMutations.isRunning(profileID: profile.id) ? "running" : model.homeMutations.ownsUnresolvedCommand(profileID: profile.id) ? "unresolved" : "idle")
                                .accessibilityIdentifier("fixture.home-command-state")
                            Text("control-count:\(controlCount)").accessibilityIdentifier("fixture.home-control-count")
                            Text("settings-decisions:\(settingsDecisionState)").accessibilityIdentifier("fixture.settings-decisions")
                            Text("prompt-route:\(promptRoute)").accessibilityIdentifier("fixture.home-prompt-route")
                            Text("opened-session:\(openedSession)").accessibilityIdentifier("fixture.home-opened-session")
                            Text(configuredModel).accessibilityIdentifier("fixture.home-configured-model")
                            Text("abort-count:\(abortCount)").accessibilityIdentifier("fixture.home-abort-count")
                            Text("home-status-count:\(homeStatusCount)")
                                .accessibilityIdentifier("fixture.home-status-count")
                            Text("task-list-reads:\(taskListReads)")
                                .accessibilityIdentifier("fixture.home-task-list-reads")
                            Text("sheet-read-peak:\(sheetReadPeak)")
                                .accessibilityIdentifier("fixture.home-sheet-read-peak")
                            Text("home-reads:\(homeReads)").accessibilityIdentifier("fixture.home-read-counts")
                            Text(TronDashboardRevealProbe.shared.summary).accessibilityIdentifier("fixture.dashboard-reveals")
                            Text(HomeUsageLayoutProbe.shared.summary).accessibilityIdentifier("fixture.home-usage-layout")
                            Text("home-diagnostics connected=\(model.connectionState) home-capable=\(model.homeStatus.capabilityEnabled) capabilities=\(String(describing: model.gatewayInfo?.capabilities)) home-phase=\(String(describing: model.homeStatus.status?.phase)) selected-profile=\(String(describing: model.profiles.selected?.id))")
                                .accessibilityIdentifier("fixture.home-diagnostics")
                        }
                        .font(.system(size: 1)).opacity(0.01)
                    }
                    .overlay(alignment: .center) {
                        if arguments.contains("-home-stale-route") {
                            Button("Invoke stale Home action") {
                                let callback = actionProbe.pause
                                Task { @MainActor in
                                    do {
                                        let other = GatewayProfile(id: "competing-profile", label: "Other Mac", host: "other.example.test", port: 9847, machineId: profile.machineId)
                                        try model.profiles.save(other, token: "other-fixture-token")
                                        try await model.connectHostedGateway(profile: other, token: "other-fixture-token")
                                        callback?()
                                        // Allow the menu's task and fixture count observer to settle.
                                        try await Task.sleep(for: .seconds(1))
                                        staleActionFinished = true
                                    } catch { self.error = error.localizedDescription }
                                }
                            }
                            .accessibilityIdentifier("fixture.invoke-stale-home-action")
                        }
                    }
            } else if let error {
                Text(error)
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(arguments.contains("-home-dark") ? .dark : .light)
        .dynamicTypeSize(arguments.contains("-home-accessibility-type") ? .accessibility3 : .large)
        // Forward scene transitions as production does: background retires the
        // connection that a mounted Home sheet's identity names, and foreground reconnects.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive: model.becameInactive()
            case .background: model.enteredBackground()
            case .active: model.becameActive()
            @unknown default: break
            }
        }
        .task {
            do {
                try await model.connectHostedGateway(profile: profile, token: "fixture-token")
                model.sessions = [SessionSummary(id: "ordinary-session", name: "Ordinary session", cwd: "/workspace",
                    parentSessionId: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
                    messageCount: 0, firstMessage: "Ordinary session", phase: .idle, summaryRevision: 1,
                    gatewayProfileID: profile.id, gatewayProfileLabel: profile.label)]
                    + (arguments.contains("-home-sheet-dashboard-workers")
                        ? HostedHomeDashboardWorkers.sessions.map { $0.withGatewaySource(id: profile.id, label: profile.label) } : [])
                ready = true
            } catch { self.error = error.localizedDescription }
        }
        .task(id: ready) {
            guard ready else { return }
            await gateway.observeHomeReads { summary in homeReads = summary }
            while !Task.isCancelled {
                homeStatusCount = await gateway.statusCount()
                taskListReads = await gateway.taskListReadCount()
                taskStatusReads = await gateway.taskStatusReadCount()
                sheetReadPeak = await gateway.sheetReadPeakCount()
                (controlCount, abortCount) = await gateway.controlCounts()
                configuredModel = await gateway.configuredModelIdentity()
                promptRoute = await gateway.lastPromptRoute()
                openedSession = await gateway.lastOpenedSession()
                settingsDecisionState = await gateway.settingsDecisionSummary()
                // Home dispatches a worker after the view loaded: its catalog row
                // arrives carrying `homeTaskId`, as the Gateway projects it.
                // `-late` holds the new worker until the view's sections revealed
                // and settled, so a journey observes the live update separately.
                if firstRevealAt == nil, !TronDashboardRevealProbe.shared.reveals.isEmpty { firstRevealAt = Date() }
                let newWorkerDue = !arguments.contains("-home-dashboard-new-worker-late")
                    || firstRevealAt.map { Date().timeIntervalSince($0) > 9 } == true
                if arguments.contains("-home-dashboard-new-worker"), !newWorkerAdded, newWorkerDue,
                   model.sessions.contains(where: \.isHomeWorker) {
                    newWorkerAdded = true
                    model.sessions = model.sessions + [HostedHomeDashboardWorkers.newWorker.withGatewaySource(id: profile.id, label: profile.label)]
                }
                // Requested once. A hosted reconnect is a new connection identity, which the mounted
                // sheet must observe by re-reading, so it fires after the second read (Manage Home's,
                // then the Tasks sheet's). A profile switch fires after the first task read (opening a
                // task from the Tasks sheet), so a test can observe the presented sheet first.
                if !reconnectRequested {
                    if arguments.contains("-home-switch-profile-after-task-open"), taskStatusReads >= 1 {
                        reconnectRequested = true
                        let other = GatewayProfile(id: "competing-profile", label: "Other Mac", host: "other.example.test", port: 9847, machineId: profile.machineId)
                        do {
                            try model.profiles.save(other, token: "other-fixture-token", selecting: false)
                            await model.switchGateway(other)
                        } catch { self.error = error.localizedDescription }
                    } else if arguments.contains("-home-reconnect-after-task-list"), taskListReads >= 2 {
                        reconnectRequested = true
                        do { try await model.connectHostedGateway(profile: profile, token: "fixture-token") }
                        catch { self.error = error.localizedDescription }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
}

private actor HostedHomeShellGateway {
    private let capabilityEnabled: Bool
    private let terminalEnabled: Bool
    private let initialState: String
    private var designated: Bool
    private var homeStatusCount = 0
    private var controlCount = 0
    private var abortCount = 0
    private var phase: String
    private var paused = false
    private var configured = true
    private let unresolved: Bool
    private let delayed: Bool
    private var acceptedControl: JSONValue?
    private var receiptChecks = 0
    private let browserState: String?
    private let emptyContext: Bool
    private let sheetState: String?
    private var browserReads = 0
    private var refusedMemoryPage = false
    private var refusedTaskPage = false
    private var taskListReads = 0
    private var taskStatusReads = 0
    // Sheet-only reads (never polled by the shell), so their overlap proves the
    // Manage Home load sends independent reads together rather than in series.
    private var sheetReadsInFlight = 0
    private var sheetReadPeak = 0
    /// The background model queue the fixture's last accepted change set, `provider/id` in order.
    private var configuredModels: [String] = []
    private var workerThinking = "sameAsHome"
    private var taskRedelivered = false
    private var scopeRevoked = false
    private var grantRevoked = false
    private var taskDecisions: [String: JSONValue] = [:]
    private var materialized = false
    private var promptRoutes: [String] = []
    private var openedSessions: [String] = []
    private var approvals: [JSONValue] = []
    private var settingsDecisions: [String] = []
    /// The learned profile as the fixture Gateway holds it, changed by `home.profileChange`
    /// and restored by `settings.undo`, with its record entries for Changes.
    private var profileItems: [HostedProfileItem] = HostedHomeToolFixture.profileItems
    private var profileEntries: [JSONValue] = []
    private var profileUndo: [String: (before: [HostedProfileItem], after: [HostedProfileItem])] = [:]
    private var profileChangeCount = 0
    /// Home's own learn of the first item, recorded as the Gateway records Home's
    /// profile tool: undoing it retires the item.
    private func seedHomeProfileEntry() {
        guard profileEntries.isEmpty, let index = profileItems.firstIndex(where: { $0.id == "9a364c45-34fe-4f0a-93e6-fc507e2b0bdc" }) else { return }
        var retired = profileItems
        retired[index].status = "retired"
        var entry = profileEntry(id: profileItems[index].id, before: [], after: profileItems, undoOf: nil).objectValue!
        entry["actor"] = .object(["kind": .string("home"), "sessionId": .string("home-session")])
        entry["presentation"] = .object(["label": .string("Profile item"), "section": .string("context"), "actor": .string("Home"),
            "layer": .string("Home profile"), "display": .object(["before": .string("Not in the profile"),
                "after": .string("Inferred preference: \(profileItems[index].text)")])])
        entry["reason"] = .string("You asked for screenshots before testing on every UI change")
        let changeID = entry["changeId"]!.stringValue!
        profileEntries.append(.object(entry))
        profileUndo[changeID] = (retired, profileItems)
    }
    init(capabilityEnabled: Bool, initialState: String, phase: String? = nil, unresolved: Bool = false, delayed: Bool = false, browserState: String? = nil, emptyContext: Bool = false, sheetState: String? = nil, settingsApprovals: Bool = false, terminalEnabled: Bool = true) {
        self.terminalEnabled = terminalEnabled
        self.sheetState = sheetState
        // Home's and a task worker's requests show in Manage Home; a chat agent's does not.
        approvals = settingsApprovals ? [
            Self.settingsApprovalRequest(requestId: "settings-request-approve", digest: String(repeating: "a", count: 64),
                actor: .object(["kind": .string("home"), "id": .string("home-session"), "sessionId": .string("home-session")]), requester: "Home",
                key: "permissions.projectTrust", label: "Project trust", qualifiers: ["project": "/work/other"],
                before: .null, after: .bool(true), display: ("Not set", "Trusted"),
                confirm: "Trusting a project lets its files run with your Mac user's authority."),
            Self.settingsApprovalRequest(requestId: "settings-request-decline", digest: String(repeating: "b", count: 64),
                actor: .object(["kind": .string("worker"), "id": .string("worker-session"), "sessionId": .string("worker-session"), "taskId": .string("nightly-sync")]),
                requester: "Home task nightly-sync", key: "run.retry.maxRetries", label: "Retries", qualifiers: nil,
                before: .number(3), after: .number(6), display: ("3", "6"), confirm: nil),
            Self.settingsApprovalRequest(requestId: "settings-request-chat", digest: String(repeating: "d", count: 64),
                actor: .object(["kind": .string("agent"), "id": .string("ordinary-session"), "sessionId": .string("ordinary-session")]),
                requester: "A chat's agent", key: "run.retry.maxRetries", label: "Retries", qualifiers: nil,
                before: .number(3), after: .number(9), display: ("3", "9"), confirm: nil),
        ] : []
        self.browserState = browserState
        self.emptyContext = emptyContext
        self.capabilityEnabled = capabilityEnabled
        self.initialState = initialState
        designated = initialState == "ready" || initialState == "rollover"
        self.phase = phase ?? "ready"
        paused = phase == "paused"
        configured = phase != "unconfigured"
        self.unresolved = unresolved
        self.delayed = delayed
    }
    func statusCount() -> Int { homeStatusCount }
    func taskListReadCount() -> Int { taskListReads }
    func taskStatusReadCount() -> Int { taskStatusReads }

    func sheetReadPeakCount() -> Int { sheetReadPeak }
    private func chapterListFixture() -> JSONValue {
        .object([
            "homeId": .string("home-fixture"), "generation": .number(1), "enabled": .bool(designated),
            "limits": .object(["softBytes": .number(25_165_824), "softEntries": .number(50_000),
                                "hardBytes": .number(209_715_200), "hardEntries": .number(100_000)]),
            "chapters": .array([
                .object(["sessionId": .string("home-chapter-sealed"), "ordinal": .number(1), "state": .string("sealed"),
                         "createdAt": .string(isoAgo(40 * 86_400)), "sealedAt": .string(isoAgo(10 * 86_400)),
                         "activationStarted": .bool(true), "sessionPresent": .bool(true),
                         "bytes": .number(25_165_824), "entries": .number(50_001),
                         "contents": .object(["firstAt": .string(isoAgo(40 * 86_400)), "lastAt": .string(isoAgo(10 * 86_400)),
                             "userMessages": .number(412), "homeReplies": .number(409), "tasksDelegated": .number(7),
                             "topics": .array([
                                 .string("""
                                     Planned the spring garden: raised beds along the south fence and **Thursday reviews**, with a watering plan Home keeps current through the season.
                                     - Order mulch and `drip-line` fittings
                                     - Ask the neighbour about the *shared* compost bin
                                     """),
                                 .string("Booked the Lisbon trip for May and asked Home to watch for fare drops."),
                                 .string("Reviewed the kitchen renovation quote and asked for a second countertop bid."),
                                 .string("Settled the quarterly budget and moved savings into the travel fund."),
                                 .string("Finished the settings model epic and delivered its report."),
                             ])])]),
                .object(["sessionId": .string("home-session"), "ordinal": .number(2), "state": .string("active"),
                         "createdAt": .string(isoAgo(3 * 86_400)), "activationStarted": .bool(true),
                         "sessionPresent": .bool(true), "bytes": .number(480), "entries": .number(12),
                         "contents": .object(["firstAt": .string(isoAgo(3 * 86_400)), "lastAt": .string(isoAgo(3 * 60)),
                             "userMessages": .number(6), "homeReplies": .number(6), "tasksDelegated": .number(1),
                             "topics": .array([.string("Garden redesign")])])]),
            ]),
        ])
    }
    private func heldSheetRead<Value>(_ value: () -> Value) async throws -> Value {
        guard sheetState == "presentation-loading" else { return value() }
        sheetReadsInFlight += 1
        sheetReadPeak = max(sheetReadPeak, sheetReadsInFlight)
        defer { sheetReadsInFlight -= 1 }
        try await Task.sleep(for: .seconds(1))
        return value()
    }
    func controlCounts() -> (Int, Int) { (controlCount, abortCount) }
    func configuredModelIdentity() -> String { configuredModels.isEmpty ? "none" : configuredModels.joined(separator: ",") }
    func lastPromptRoute() -> String { promptRoutes.last ?? "none" }
    func lastOpenedSession() -> String { openedSessions.last ?? "none" }
    func settingsDecisionSummary() -> String { settingsDecisions.isEmpty ? "none" : settingsDecisions.joined(separator: ",") }
    func capabilities() -> [String] { capabilityEnabled ? (sheetState == "dashboard-workers" ? [ProviderUsageCapability.name] : []) + ["sessions.v1", "home.v1", "home-chapter-list.v1", "home-profile-list.v1", "home-profile-edit.v1", "context-window.v1", "skill-prompt.v1"] + (terminalEnabled ? ["terminal.v1"] : []) + (sheetState == "browser-unsupported" ? [] : ["home-memory-view.v1"]) : ["sessions.v1"] }

    /// Every Home read a sheet sent, so journeys can prove a return to a sheet re-reads nothing.
    private var homeReads: [String: Int] = [:]
    /// Publishes each count before the read is answered, so the label is current
    /// by the time the sheet shows the content (no poll delay).
    private var onHomeRead: (@MainActor @Sendable (String) -> Void)?
    func observeHomeReads(_ observer: @escaping @MainActor @Sendable (String) -> Void) { onHomeRead = observer }
    func homeReadSummary() -> String {
        ["home.status", "home.context", "home.chapterList", "home.memory.view", "home.taskList", "home.taskStatus"]
            .map { "\($0)=\(homeReads[$0, default: 0])" }.joined(separator: ",")
    }

    /// The Gateway's profile change semantics on fixture data: the maintainer's edits are
    /// confirmed, a stale revision is a conflict, and each request is one undoable group.
    private func profileChange(_ params: [String: JSONValue]) -> (JSONValue?, JSONValue?) {
        guard params["commandId"]?.stringValue != nil, case .array(let changes)? = params["changes"], !changes.isEmpty else { return taskRefusal() }
        profileChangeCount += 1
        if ProcessInfo.processInfo.arguments.contains("-home-profile-conflict"), profileChangeCount == 1 {
            return (nil, .object(["code": .string("conflict"), "message": .string("This profile item changed since it was read; review it and try again"),
                "retryable": .bool(false)]))
        }
        let before = profileItems
        var touched: [String] = []
        let now = ISO8601DateFormatter().string(from: Date())
        for change in changes {
            guard let object = change.objectValue, let action = object["action"]?.stringValue, let id = object["id"]?.stringValue,
                  let index = profileItems.firstIndex(where: { $0.id == id && $0.status == "active" }),
                  object["expectedRevision"]?.stringValue == profileItems[index].revisionId else {
                profileItems = before
                return (nil, .object(["code": .string("conflict"), "message": .string("This profile item changed since it was read; review it and try again"), "retryable": .bool(false)]))
            }
            var item = profileItems[index]
            item.revisionId = UUID().uuidString.lowercased(); item.updatedAt = now
            switch action {
            case "confirm": item.confirmed = true
            case "refine":
                item.text = object["text"]?.stringValue ?? item.text; item.kind = object["kind"]?.stringValue ?? item.kind; item.confirmed = true
            case "retire": item.status = "retired"
            case "supersede":
                let next = HostedProfileItem(id: UUID().uuidString.lowercased(), revisionId: UUID().uuidString.lowercased(),
                    kind: object["kind"]?.stringValue ?? item.kind, text: object["text"]?.stringValue ?? item.text,
                    confirmed: true, status: "active", createdAt: now, updatedAt: now)
                item = profileItems[index]; item.status = "superseded"
                profileItems.append(next); touched.append(next.id)
            default: return taskRefusal()
            }
            profileItems[index] = item
            touched.insert(id, at: 0)
        }
        let entries = touched.map { profileEntry(id: $0, before: before, after: profileItems, undoOf: nil) }
        profileEntries.append(contentsOf: entries)
        let changeIDs = entries.compactMap { $0.objectValue?["changeId"]?.stringValue }
        for id in changeIDs { profileUndo[id] = (before, profileItems) }
        return (.object(["status": .string("applied"), "tier": .string("quiet"),
            "changes": .array(changeIDs.map { .object(["changeId": .string($0)]) }),
            "items": try! JSONValue.encode(profileItems.filter { touched.contains($0.id) })]), nil)
    }

    private func profileUndo(_ params: [String: JSONValue]) -> (JSONValue?, JSONValue?) {
        guard let changeID = params["changeId"]?.stringValue, let recorded = profileUndo[changeID] else { return taskRefusal() }
        let touched = Set(recorded.after.map(\.id) + recorded.before.map(\.id)).filter { id in
            recorded.after.first { $0.id == id } != recorded.before.first { $0.id == id }
        }
        let current = profileItems
        profileItems = recorded.before
        let entries = touched.sorted().map { profileEntry(id: $0, before: current, after: profileItems, undoOf: changeID) }
        profileEntries.append(contentsOf: entries)
        for (key, value) in profileUndo where value.after == recorded.after { profileUndo.removeValue(forKey: key) }
        return (.object(["status": .string("applied"), "tier": .string("quiet"), "changes": .array([])]), nil)
    }

    private func profileEntry(id: String, before: [HostedProfileItem], after: [HostedProfileItem], undoOf: String?) -> JSONValue {
        func display(_ item: HostedProfileItem?) -> String {
            guard let item else { return "Not in the profile" }
            switch item.status {
            case "retired": return "Retired: \(item.text)"
            case "superseded": return "Superseded: \(item.text)"
            default: return "\(item.confirmed ? "Confirmed" : "Inferred") \(item.kind.replacingOccurrences(of: "-", with: " ")): \(item.text)"
            }
        }
        let old = before.first { $0.id == id }, new = after.first { $0.id == id }
        var entry: [String: JSONValue] = [
            "changeId": .string(UUID().uuidString.lowercased()), "at": .string(ISO8601DateFormatter().string(from: Date())),
            "actor": .object(["kind": .string("ui")]), "target": .object(["kind": .string("home")]), "layer": .string("profile"),
            "key": .string("home.profile.item"), "qualifiers": .object(["note": .string(id)]), "op": .string("set"),
            "before": old.map { try! JSONValue.encode($0) } ?? .null, "after": new.map { try! JSONValue.encode($0) } ?? .null,
            "tier": .string("quiet"), "status": .string("applied"),
            "presentation": .object(["label": .string("Profile item"), "section": .string("context"), "actor": .string("You"),
                "layer": .string("Home profile"), "display": .object(["before": .string(display(old)), "after": .string(display(new))])]),
        ]
        if let undoOf { entry["undoOf"] = .string(undoOf) }
        return .object(entry)
    }

    func handle(_ method: String, _ params: [String: JSONValue]) async throws -> (JSONValue?, JSONValue?) {
        if method.hasPrefix("home.") {
            homeReads[method, default: 0] += 1
            if let onHomeRead { await onHomeRead(homeReadSummary()) }
        }
        switch method {
        // #479: one terminal the Gateway closed after its idle period, so the
        // sheet opens a fresh live one and lists the closed one under Recent.
        case "terminal.list" where ProcessInfo.processInfo.arguments.contains("-home-terminal-closed"):
            return (.object(["terminals": .array([HostedClosedTerminal.closed])]), nil)
        case "terminal.open" where ProcessInfo.processInfo.arguments.contains("-home-terminal-closed"):
            return (.object(["terminal": HostedClosedTerminal.live, "replay": .object(["terminal": HostedClosedTerminal.live,
                "chunks": .array([HostedClosedTerminal.chunk(1, "home % ")]), "reset": .bool(false)])]), nil)
        case "terminal.attach" where ProcessInfo.processInfo.arguments.contains("-home-terminal-closed"):
            let closed = params["terminalId"]?.stringValue == "closed-terminal"
            return (.object(["terminal": closed ? HostedClosedTerminal.closed : HostedClosedTerminal.live,
                "chunks": .array(closed ? [HostedClosedTerminal.chunk(1, "home % "), HostedClosedTerminal.chunk(2, "\r\n[Closed after 60 minutes idle]\r\n")]
                    : [HostedClosedTerminal.chunk(1, "home % ")]), "reset": .bool(false)]), nil)
        case "terminal.detach" where ProcessInfo.processInfo.arguments.contains("-home-terminal-closed"):
            return (.object(["detached": .bool(true)]), nil)
        case "terminal.resize" where ProcessInfo.processInfo.arguments.contains("-home-terminal-closed"):
            return (.object(["resized": .bool(true)]), nil)
        case "terminal.list":
            return (nil, .object(["code": .string("unavailable"),
                "message": .string("Fixture terminal unavailable for \(params["sessionId"]?.stringValue ?? "missing")"),
                "retryable": .bool(false)]))
        case "session.list":
            let row = SessionSummary(id: "ordinary-session", name: "Ordinary session", cwd: "/workspace", parentSessionId: nil,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z", messageCount: 0,
                firstMessage: "Ordinary session", phase: .idle, summaryRevision: 1)
            // Home's chapters are never ordinary rows: the Gateway's user list omits them.
            let workers = sheetState == "dashboard-workers" ? HostedHomeDashboardWorkers.sessions : []
            return (.object(["sessions": .array(([row] + workers).map { try! JSONValue.encode($0) }), "nextCursor": .null,
                "listRevision": .number(1), "projectionToken": .string("home-shell-fixture:1"), "archivedCount": .number(0)]), nil)
        // Read on every connection; an unknown-method failure would raise a
        // notice over the dashboard journeys' screenshots.
        case "device.list":
            return (.object(["devices": .array([])]), nil)
        case "provider.list" where sheetState == "dashboard-workers":
            return (HostedHomeDashboardWorkers.providers, nil)
        case "provider.usage":
            // Holds the usage card on its loading pulse long enough to see it.
            if ProcessInfo.processInfo.arguments.contains("-home-dashboard-usage-delay") {
                try await Task.sleep(for: .seconds(6))
            }
            return (HostedHomeDashboardWorkers.usage, nil)
        case "provider.list":
            return (.object(["providers": .array([.object(["id": .string("fixture"), "name": .string("Fixture"),
                "configured": .bool(true), "authMethods": .array([]), "modelCount": .number(3)])])]), nil)
        case "model.list":
            return (.object(["models": .array(sheetState == "empty-models" ? [] : [anthropicModel("claude-opus-5-5", name: "Claude Opus 5.5", window: 1_000_000),
                anthropicModel("claude-haiku-5-5", name: "Claude Haiku 5.5", window: 200_000), model("memory-a", name: "Memory Model A"),
                model("memory-b", name: "Memory Model B"), model("virtual", name: "Virtual model", virtual: true)]), "nextCursor": .null]), nil)
        case "model.recent": return (.object(["models": .array([])]), nil)
        case "settings.history":
            seedHomeProfileEntry()
            let entries: [JSONValue] = ProcessInfo.processInfo.arguments.contains("-home-settings-history") ? [
                .object(["changeId": .string("worker-setting"), "at": .string("2026-10-11T12:00:00Z"),
                    "actor": .object(["kind": .string("worker"), "sessionId": .string("worker-session"), "taskId": .string("active")]),
                    "target": .object(["kind": .string("home")]), "layer": .string("profile"), "key": .string("model.thinking[role=worker]"),
                    "op": .string("set"), "before": .string("off"), "after": .string("high"), "tier": .string("notify"),
                    "status": .string("applied"), "presentation": .object(["label": .string("Worker thinking"),
                        "actor": .string("Worker"), "layer": .string("Home profile"), "section": .string("model"),
                        "display": .object(["before": .string("Off"), "after": .string("High")])])])
            ] : []
            // The feed's default filter is agents and outside, as the Gateway's is.
            let profile = profileEntries.reversed().filter { entry in
                params["actor"]?.stringValue != "agents" || entry.objectValue?["actor"]?.objectValue?["kind"]?.stringValue != "ui"
            }
            return (.object(["entries": .array(profile + entries)]), nil)
        case "home.profileChange":
            seedHomeProfileEntry()
            return profileChange(params)
        case "settings.undo":
            return profileUndo(params)
        case "home.taskList":
            taskListReads += 1
            // Hold the real sheet's read at the socket boundary, not its view state.
            // Both Manage Home and its nested Tasks sheet must lay out before data.
            if sheetState == "presentation-loading" { try await Task.sleep(for: .seconds(12)) }
            if sheetState == "tasks-error", taskListReads == 2 {
                return (nil, .object(["code": .string("busy"), "message": .string("Task list unavailable"), "retryable": .bool(true)]))
            }
            if sheetState == "paging" {
                let offset = params["cursor"]?.stringValue.flatMap(Int.init) ?? 0
                if offset > 0, !refusedTaskPage {
                    refusedTaskPage = true
                    return (nil, .object(["code": .string("busy"), "message": .string("Older tasks temporarily unavailable"), "retryable": .bool(true)]))
                }
                let limit = params["limit"]?.intValue ?? 20
                let end = min(offset + limit, 45)
                let items = (offset..<end).map { index -> JSONValue in
                    if index == 0 { return taskSummary("active") }
                    var row = taskSummary("terminal").objectValue!
                    row["taskId"] = .string("paged-\(index)")
                    row["title"] = .string("Pagination task \(index)")
                    row["createdAt"] = .number(1_700_000_000_000 - Double(index * 1000))
                    row["updatedAt"] = row["createdAt"]
                    return .object(row)
                }
                var page: [String: JSONValue] = ["items": .array(items)]
                if end < 45 { page["nextCursor"] = .string(String(end)) }
                return (.object(page), nil)
            }
            return (.object(["items": .array(sheetState == "tasks-empty" ? [] : [taskSummary("active"), taskSummary("terminal")])]), nil)
        case "home.taskStatus":
            taskStatusReads += 1
            guard let id = params["taskId"]?.stringValue,
                  ["active", "terminal"].contains(id) || (sheetState == "paging" && id.hasPrefix("paged-")) else { return taskRefusal() }
            return (taskRecord(id), nil)
        case "home.taskPermissions":
            if sheetState == "tasks-empty" {
                return (nil, .object(["code": .string("conflict"), "message": .string("Home task namespace refused: not-initialized"), "retryable": .bool(false)]))
            }
            return (taskPermissions(), nil)
        case "home.redeliverTaskResult":
            guard params["commandId"]?.stringValue != nil, params["taskId"]?.stringValue == "terminal",
                  params["homeId"]?.stringValue == "home-fixture", params["routeGeneration"]?.intValue == 2 else { return taskRefusal() }
            taskRedelivered = true; controlCount += 1; return (.object(["accepted": .bool(true)]), nil)
        case "home.revokeTaskScope", "home.revokeTaskGrant", "home.reconfirmPermissions":
            guard params["commandId"]?.stringValue != nil else { return taskRefusal() }
            if method == "home.revokeTaskScope" {
                guard params["scopeId"]?.stringValue == "scope-one" else { return taskRefusal() }; scopeRevoked = true
            }
            if method == "home.revokeTaskGrant" {
                guard params["grantId"]?.stringValue == "grant-one" else { return taskRefusal() }; grantRevoked = true
            }
            controlCount += 1; return (.object(["accepted": .bool(true)]), nil)
        case "home.decideTaskGrant":
            guard params["commandId"]?.stringValue != nil, let id = params["requestId"]?.stringValue,
                  ["request-approve", "request-deny"].contains(id), taskDecisions[id] == nil,
                  let approved = params["approved"]?.boolValue, let expires = params["expiresAt"]?.intValue,
                  Double(expires) > Date.now.timeIntervalSince1970 * 1000 else { return taskRefusal() }
            let decision: JSONValue = .object(["id": params["commandId"]!, "requestId": .string(id), "approved": .bool(approved),
                "decidedAt": .number(Double(Int(Date.now.timeIntervalSince1970 * 1000))), "expiresAt": .number(Double(expires))])
            var grant = taskBinding().objectValue!
            grant["id"] = .string("grant-\(id)"); grant["decisionId"] = params["commandId"]!
            grant["expiresAt"] = .number(Double(expires)); grant["state"] = .string("available")
            let result: JSONValue = .object(["decision": decision, "grant": approved ? .object(grant) : .null])
            taskDecisions[id] = result; controlCount += 1
            return (result, nil)
        case "home.profileList":
            seedHomeProfileEntry()
            return (.object(["items": try JSONValue.encode(profileItems), "unclassified": .number(0)]), nil)
        case "home.chapterList":
            return (try await heldSheetRead { chapterListFixture() }, nil)
        case "home.context":
            return (try await heldSheetRead { contextProjection() }, nil)
        case "home.memory.view":
            browserReads += 1
            if browserState == "loading", browserReads == 1 { try? await Task.sleep(for: .seconds(4)) }
            if browserState == "error", browserReads == 1 {
                return (nil, .object(["code": .string("busy"), "message": .string("Canonical source unavailable"), "retryable": .bool(true)]))
            }
            if browserState == "paging", params["cursor"] != nil, !refusedMemoryPage {
                refusedMemoryPage = true
                return (nil, .object(["code": .string("busy"), "message": .string("Older memory temporarily unavailable"), "retryable": .bool(true)]))
            }
            return (memoryView(params, empty: browserState == "empty"), nil)
        case "home.memory.evidence":
            let offset = params["offset"]?.intValue ?? 0
            let first = "Canonical original, not the memory projection"
            let second = "Canonical continuation"
            let text = offset == 0 ? first : second
            var result: [String: JSONValue] = ["format": .string("canonical-history"), "evidence": params["evidence"] ?? evidence(),
                "text": .string(text), "offset": .number(Double(offset)),
                "totalCharacters": .number(Double(first.utf16.count + second.utf16.count)), "metadata": .object(["role": .string("user")])]
            if offset == 0 { result["nextOffset"] = .number(Double(first.utf16.count)) }
            else { result["previousOffset"] = .number(0) }
            return (.object(result), nil)
        case "home.prompt":
            // Composer resources ride the logical route as the Gateway's ordered
            // `resourceInvocations`; the route records exactly which, in order,
            // and the message text that follows them (#311).
            if let resources = params["resourceInvocations"]?.arrayValue, !resources.isEmpty {
                let names = resources.compactMap { $0.objectValue }.map {
                    "\($0["source"]?.stringValue ?? "?"):\($0["name"]?.stringValue ?? "?")"
                        + (($0["arguments"]?.stringValue ?? "").isEmpty ? "" : "=\($0["arguments"]!.stringValue!)")
                }
                promptRoutes.append("home.prompt:\(names.joined(separator: "+")):\(params["text"]?.stringValue ?? "")")
                return (.object(["logicalSessionId": .string("home"), "homeId": .string("home-fixture"), "bindingRevision": .number(1),
                    "sessionId": .string("home-session"), "operationId": .string("resource-operation")]), nil)
            }
            // The rollover journey: the logical route materializes the reserved
            // successor, and only the route's text is admitted.
            promptRoutes.append("home.prompt")
            guard params["commandId"]?.stringValue != nil, params["text"]?.stringValue == "After rollover" else { return taskRefusal() }
            materialized = true
            return (.object(["logicalSessionId": .string("home"), "homeId": .string("home-fixture"), "bindingRevision": .number(2),
                "sessionId": .string("home-successor"), "operationId": .string("successor-operation")]), nil)
        case "session.prompt":
            promptRoutes.append("session.prompt:\(params["sessionId"]?.stringValue ?? "none")")
            return (nil, .object(["code": .string("conflict"), "message": .string("Sealed chapter refused"), "retryable": .bool(false)]))
        case "home.status":
            homeStatusCount += 1
            // Hold the actual response across native back navigation so a transient
            // loading replacement cannot disappear before XCTest observes it.
            if sheetState == "navigation-refresh", homeStatusCount > 1 {
                try await Task.sleep(for: .seconds(4))
            }
            if sheetState == "delayed-status", !configuredModels.isEmpty { try? await Task.sleep(for: .seconds(4)) }
            return (homeStatus(), nil)
        case "home.designate":
            if delayed { try? await Task.sleep(for: .seconds(6)) }
            designated = true
            return (.object(["homeId": .string("home-fixture"), "sessionId": .string("home-session"), "generation": .number(1)]), nil)
        case "settings.resolve":
            if sheetState == "delayed-status", !configuredModels.isEmpty { try? await Task.sleep(for: .seconds(4)) }
            return (homeSettingsResolution(), nil)
        case "settings.options":
            return (homeSettingsOptions(params), nil)
        case "settings.approvals":
            return (.object(["requests": .array(approvals)]), nil)
        case "settings.decide":
            guard params["commandId"]?.stringValue != nil, let id = params["requestId"]?.stringValue,
                  let digest = params["digest"]?.stringValue, let approved = params["approved"]?.boolValue,
                  let index = approvals.firstIndex(where: { $0.objectValue?["requestId"]?.stringValue == id && $0.objectValue?["digest"]?.stringValue == digest })
            else { return taskRefusal() }
            approvals.remove(at: index)
            settingsDecisions.append("\(approved ? "approved" : "declined"):\(id)")
            controlCount += 1
            return (.object(["requestId": .string(id), "approved": .bool(approved)]), nil)
        case "home.pauseMemory", "home.resumeMemory", "settings.change", "home.disable":
            if method == "settings.change", params["dryRun"]?.boolValue == true {
                return (settingsChangePreview(params), nil)
            }
            controlCount += 1
            let memoryChange = params["changes"]?.arrayValue?.first?.objectValue
            if method == "settings.change", memoryChange?["key"]?.stringValue == "model.ref[role=chat]" {
                guard memoryChange?["layer"]?.stringValue == "chat" else { return taskRefusal() }
                settingsModelOverridden = memoryChange?["op"]?.stringValue != "unset"
                return (fixtureSettingsChangeResult(key: "model.ref[role=chat]"), nil)
            }
            if method == "settings.change", memoryChange?["key"]?.stringValue == "model.thinking[role=worker]" {
                guard memoryChange?["layer"]?.stringValue == "profile" else { return taskRefusal() }
                workerThinking = memoryChange?["value"]?.stringValue ?? "sameAsHome"
                return (fixtureSettingsChangeResult(key: "model.thinking[role=worker]"), nil)
            }
            if method == "settings.change", memoryChange?["key"]?.stringValue != "model.queue[role=background]" { return (nil, nil) }
            if method == "settings.change", sheetState == "configure-refused" {
                return (nil, .object(["code": .string("conflict"), "message": .string("Memory configuration refused"), "retryable": .bool(false)]))
            }
            if method == "home.pauseMemory" { paused = true; if phase != "active" { phase = "paused" } }
            if method == "home.resumeMemory" { paused = false; phase = "ready" }
            if method == "settings.change" {
                configured = true; phase = "ready"
                configuredModels = memoryChange?["value"]?.arrayValue?.compactMap(\.stringValue) ?? []
            }
            if method == "home.disable" { designated = false; phase = "disabled" }
            let result = method == "settings.change"
                ? fixtureSettingsChangeResult(key: "model.queue[role=background]")
                : JSONValue.object(["configured": .bool(configured), "open": .bool(true), "paused": .bool(paused)])
            if delayed {
                acceptedControl = result
                try? await Task.sleep(for: .seconds(6))
            }
            if unresolved {
                acceptedControl = result
                return (nil, .object(["code": .string("response_too_large"), "message": .string("Completion unavailable"), "retryable": .bool(false)]))
            }
            return (result, nil)
        case "command.status":
            receiptChecks += 1
            if unresolved && receiptChecks == 1 { return (.object(["status": .string("pending")]), nil) }
            return (.object(["status": .string("completed"), "result": acceptedControl ?? .null]), nil)
        case "session.abort":
            if params["sessionId"]?.stringValue == "home-session", params["operationId"]?.stringValue == "home-operation",
               params["kind"]?.stringValue == "agent", params["commandId"]?.stringValue != nil {
                abortCount += 1
                phase = paused ? "paused" : "ready"
            }
            return (.object(["aborted": .bool(abortCount > 0)]), nil)
        case "session.open":
            let sessionID = params["sessionId"]?.stringValue ?? "home-session"
            openedSessions.append(sessionID)
            var snapshot = SessionSnapshot(sessionId: sessionID, runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
                phase: phase == "active" ? .running : .idle, name: sessionID.hasPrefix("home-") ? "Home fixture chat" : "Ordinary session chat", cwd: "/workspace",
                parentSessionId: nil, model: nil, thinkingLevel: "medium", availableThinkingLevels: [], contextUsage: nil,
                stats: SessionStats(userMessages: 0, assistantMessages: 0, toolCalls: 0, toolResults: 0, totalMessages: 0,
                    tokens: .init(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0), latestCacheHitRate: nil, cost: 0),
                queueRevision: 0, queuedItems: [], automaticCompactionEnabled: true, transcript: [], transcriptStart: nil,
                transcriptTotal: nil, streaming: nil, leafEntryId: nil,
                operation: phase == "active" ? try! JSONValue.object(["id": .string("home-operation"), "kind": .string("prompt"),
                    "startedAt": .string("2026-01-01T00:00:00Z"), "lifecycle": .string("running")]).decode(SessionOperationState.self) : nil,
                retry: nil, toolExecutions: [],
                extensionPresentation: ExtensionPresentationState(version: 3, hostEpoch: "fixture", revision: 1, capabilities: [], diagnostics: [],
                    semanticState: .init(statuses: [:], working: .init(message: nil, visible: false), hiddenThinkingLabel: nil, widgets: [], title: nil, toolsExpanded: false, editorRevision: 0, editorText: ""),
                    surfaces: [], pendingInteractions: []), diagnostics: [])
            if sessionID.hasPrefix("home-") { applyHomeChatConfiguration(to: &snapshot) }
            if sessionID == "home-session", ProcessInfo.processInfo.arguments.contains("-home-tool-transcript") {
                snapshot.transcript = HostedHomeToolFixture.transcript
                snapshot.transcriptStart = 0
                snapshot.transcriptTotal = snapshot.transcript.count
            }
            return (.object(["session": try! JSONValue.encode(snapshot), "syncToken": .string("fixture-sync"),
                "subscriptionToken": .string("fixture-subscription"), "completionRevision": .number(0)]), nil)
        case "session.sync": return (.object(["synchronized": .bool(true)]), nil)
        case "session.close": return (.object(["closed": .bool(true)]), nil)
        case "session.commands":
            // Home's catalog as the Gateway serves it: user-level skills and
            // prompt templates only, never project resources.
            func user(_ name: String, _ source: String, _ description: String, hint: String? = nil) -> JSONValue {
                var row: [String: JSONValue] = ["name": .string(name), "source": .string(source), "description": .string(description),
                    "resourceSource": .string("auto"), "resourceScope": .string("user"), "resourceOrigin": .string("top-level")]
                if let hint { row["argumentHint"] = .string(hint) }
                return .object(row)
            }
            return (.object(["commands": .array([
                user("daily-brief", "prompt", "Draft a short daily brief from my notes", hint: "<topic>"),
                user("weekly-review", "prompt", "Review the week's notes and open loops"),
                user("skill:jev", "skill", "Use Tron's explicit typed Jev decision adapter for bounded workflow decisions."),
                user("skill:wordcraft", "skill", "Create, edit, inspect, render and convert word-processor documents."),
            ])]), nil)
        case "session.attention.read": return (.object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)]), nil)
        default: return (nil, .object(["code": .string("not_found"), "message": .string("Not part of this fixture: \(method)"), "retryable": .bool(false)]))
        }
    }

    private var settingsModelOverridden = true
    private func homeSettingsResolution() -> JSONValue {
        let modelValue: JSONValue = .object(["provider": .string("anthropic"), "id": .string(settingsModelOverridden ? "claude-opus-5-5" : "claude-haiku-5-5")])
        let modelKey: JSONValue = .object([
            "key": .string("model.ref[role=chat]"), "group": .string("model"),
            "value": modelValue, "display": .string(settingsModelOverridden ? "Claude Opus 5.5" : "Claude Haiku 5.5"),
            "layer": .string(settingsModelOverridden ? "chat" : "mac"), "applied": .bool(true),
            "layers": .array([.object(["layer": .string("chat"), "value": settingsModelOverridden ? modelValue : .null]), .object(["layer": .string("mac")])]),
            "badges": .array(settingsModelOverridden ? [
                .object(["kind": .string("layer"), "label": .string("Set in this chat")]),
                .object(["kind": .string("source"), "label": .string("Chosen for this chat"), "action": .object(["kind": .string("useCurrentDefault"), "label": .string("Use the current default")])])
            ] : [.object(["kind": .string("layer"), "label": .string("Set on Mac")])]),
            "presentation": .object(["label": .string("Model"), "help": .string("The model for this chat."),
                "order": .number(10), "importance": .string("essential"), "control": .string("catalog"),
                "optionsSource": .object(["name": .string("catalog.models"), "dependsOn": .array([])])])
        ])
        let thinkingLabel = workerThinking == "sameAsHome" ? "Same as Home" : workerThinking.capitalized
        let choices: [JSONValue] = [
            ("sameAsHome", "Same as Home"), ("off", "Off"), ("low", "Low"),
            ("medium", "Medium"), ("high", "High"),
        ].map { .object(["value": $0.0 == "sameAsHome" ? .object(["sameAs": .string("home")]) : .string($0.0), "label": .string($0.1)]) }
        let workerThinkingKey: JSONValue = .object([
            "key": .string("model.thinking[role=worker]"), "qualifiers": .object(["role": .string("worker")]),
            "group": .string("model"), "subgroup": .string("Workers"),
            "value": workerThinking == "sameAsHome" ? .object(["sameAs": .string("home")]) : .string(workerThinking),
            "display": .string(thinkingLabel), "layer": .string(workerThinking == "sameAsHome" ? "builtin" : "profile"),
            "applied": .bool(true), "badges": .array([.object(["kind": .string("source"), "label": .string(workerThinking == "sameAsHome" ? "Tron default" : "Set in Home profile")])]),
            "layers": .array([.object(["layer": .string("profile")]), .object(["layer": .string("builtin")])]),
            "presentation": .object(["label": .string("Worker thinking"), "help": .string("Thinking level for Home task workers."),
                "order": .number(45), "importance": .string("essential"), "control": .string("choice"),
                "options": .array(choices)]),
        ])
        let contextWindowKey: JSONValue = .object([
            "key": .string("model.contextWindow"), "qualifiers": .object(["model": .string("anthropic/claude-opus-5-5")]),
            "group": .string("model"), "value": .number(200_000), "display": .string("200,000 tokens"),
            "layer": .string("builtin"), "applied": .bool(true), "badges": .array([]),
            "layers": .array([.object(["layer": .string("chat")]), .object(["layer": .string("mac")]), .object(["layer": .string("builtin")])]),
            "presentation": .object(["label": .string("Context window"), "help": .string("How many tokens the model receives."),
                "order": .number(30), "importance": .string("essential"), "control": .string("number"),
                "optionsSource": .object(["name": .string("catalog.contextWindow"), "dependsOn": .array([])])]),
        ])
        let names = ["fixture/memory-a": "Memory Model A", "fixture/memory-b": "Memory Model B"]
        let memoryName = configuredModels.isEmpty ? "Same as subagent models" : configuredModels.map { names[$0] ?? $0 }.joined(separator: " → ")
        let memoryKey: JSONValue = .object([
            "key": .string("model.queue[role=background]"), "qualifiers": .object(["role": .string("background")]),
            "group": .string("model"), "subgroup": .string("Model queues"), "value": .array(configuredModels.map(JSONValue.string)),
            "display": .string(memoryName), "layer": .string(configuredModels.isEmpty ? "builtin" : "profile"), "applied": .bool(true),
            "badges": .array([.object(["kind": .string("source"), "label": .string(configuredModels.isEmpty ? "Tron default" : "Set in Home profile")])]),
            "layers": .array([.object(["layer": .string("profile"), "value": configuredModels.isEmpty ? .null : .array(configuredModels.map(JSONValue.string))]), .object(["layer": .string("mac")]), .object(["layer": .string("builtin")])]),
            "presentation": .object(["label": .string("Background models"), "help": .string("The models for memory and Knowledge calls, in order. Empty uses the subagent models."),
                "order": .number(42), "importance": .string("essential"), "control": .string("list"), "valueKind": .string("stringList"),
                "entry": .object(["hint": .string("A provider/model ID. Tron uses the first available model in this order."), "example": .string("anthropic/claude-haiku-5-5")]),
                "optionsSource": .object(["name": .string("catalog.models"), "dependsOn": .array([])])]),
        ])
        return .object(["keys": .array([modelKey, workerThinkingKey, contextWindowKey, memoryKey]), "sections": .array([.object([
            "id": .string("model"), "title": .string("Model"), "order": .number(10),
        ]), .object(["id": .string("context"), "title": .string("Context"), "order": .number(20)])])])
    }

    private func homeSettingsOptions(_ params: [String: JSONValue]) -> JSONValue {
        if params["key"]?.stringValue == "model.ref[role=chat]" {
            let options: [JSONValue] = [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-haiku-5-5", "Claude Haiku 5.5")].map { id, name in
                .object(["value": .object(["provider": .string("anthropic"), "id": .string(id)]), "label": .string(name)])
            }
            return .object(["key": params["key"]!, "source": .string("catalog.models"), "dependsOn": .array([]), "options": .array(options)])
        }
        if params["key"]?.stringValue == "model.queue[role=background]" {
            let options: [JSONValue] = sheetState == "empty-models" ? [] : [("memory-a", "Memory Model A"), ("memory-b", "Memory Model B")].map { id, name in
                .object(["value": .object(["provider": .string("fixture"), "id": .string(id)]), "label": .string(name)])
            }
            return .object(["key": params["key"]!, "source": .string("catalog.models"), "dependsOn": .array([]), "options": .array(options)])
        }
        return .object(["key": params["key"] ?? .string("model.contextWindow"),
            "source": .string("catalog.contextWindow"), "dependsOn": .array([]), "options": .array([]),
            "range": .object(["min": .number(1_024), "max": .number(200_000), "unit": .string("tokens")])])
    }

    private func settingsChangePreview(_ params: [String: JSONValue]) -> JSONValue {
        let change = params["changes"]?.arrayValue?.first?.objectValue ?? [:]
        let value = change["value"] ?? .null
        if change["key"]?.stringValue == "model.queue[role=background]", sheetState == "configure-refused" {
            return .object(["changes": .array([.object(["error": .object([
                "code": .string("conflict"), "message": .string("Memory configuration refused"),
            ])])])])
        }
        return .object(["dryRun": .bool(true), "status": .string("applied"), "tier": .string("notify"),
            "changes": .array([.object(["key": change["key"] ?? .string(""), "layer": change["layer"] ?? .string("profile"),
                "status": .string("applied"), "tier": .string("notify"), "before": .string(workerThinking), "after": value])])])
    }

    /// One pending Mac-layer change as `settings.approvals` serves it (gateway approvalProjection).
    private static func settingsApprovalRequest(
        requestId: String, digest: String, actor: JSONValue, requester: String, key: String, label: String,
        qualifiers: [String: String]?, before: JSONValue, after: JSONValue, display: (String, String), confirm: String?
    ) -> JSONValue {
        var change: [String: JSONValue] = [
            "changeId": .string("change-\(requestId)"), "key": .string(key), "label": .string(label),
            "layer": .string("mac"), "op": .string("set"), "tier": .string("approve"), "tierBasis": .object([:]),
            "before": before, "after": after,
            "display": .object(["before": .string(display.0), "after": .string(display.1)]),
        ]
        if let qualifiers { change["qualifiers"] = .object(qualifiers.mapValues(JSONValue.string)) }
        if let confirm { change["confirm"] = .string(confirm) }
        return .object([
            "requestId": .string(requestId), "digest": .string(digest),
            "createdAt": .string("2026-01-01T00:00:00.000Z"), "expiresAt": .string(Date.now.addingTimeInterval(23 * 60 * 60).formatted(.iso8601)),
            "target": .object(["kind": .string("session"), "sessionId": actor.objectValue?["sessionId"] ?? .null]),
            "actor": actor, "requester": .string(requester), "reason": .string("You asked me to"),
            "changes": .array([.object(change)]),
        ])
    }

    private func taskRefusal() -> (JSONValue?, JSONValue?) {
        (nil, .object(["code": .string("conflict"), "message": .string("Task fixture binding refused"), "retryable": .bool(false)]))
    }
    private func taskSpend() -> JSONValue {
        .object(["sourceDigest": .string(String(repeating: "a", count: 64)), "inputTokens": .number(12),
                 "cacheReadTokens": .number(480), "cacheWriteTokens": .number(0), "outputTokens": .number(3)])
    }
    private func taskSummary(_ id: String) -> JSONValue {
        let terminal = id == "terminal"
        // The Gateway sends whole epoch milliseconds; the task DTOs decode them as Int.
        let now = nowMilliseconds()
        let created = id == "active" ? now - 2 * 3_600_000 : now - 86_400_000
        let updated = id == "active" ? now - 6 * 60_000 : now - 3 * 3_600_000
        return .object(["taskId": .string(id), "createdAt": .number(created), "updatedAt": .number(updated),
            "title": .string(id == "active" ? "Settings model: continue epic #758" : "Garden review email draft"), "project": .string("tron"),
            "sessionId": .string("worker-session"), "target": .string("/trusted/project"),
            "lifecycle": .string(terminal ? "terminal" : "active"), "outcome": terminal ? .string(id == "active" ? "interrupted" : "final") : .null,
            "spend": taskSpend(), "attention": .bool(false), "pendingGrant": .bool(false),
            "checkins": .array(id == "active" ? [.object([
                "id": .string("checkin-one"), "taskId": .string(id), "sessionId": .string("worker-session"),
                "operationId": .string("task-operation"), "at": .string(isoAgo(360)),
                "step": .string("Validating settings changes"), "done": .string("Gateway journey passed"),
                "next": .string("Review native screenshots"), "attention": .string("none"),
            ])] : [])])
    }
    private func taskRecord(_ id: String) -> JSONValue {
        var record = taskSummary(id).objectValue!
        record["version"] = .number(1); record["revision"] = .number(1)
        record["homeId"] = .string("home-fixture"); record["generation"] = .number(1); record["routeGeneration"] = .number(1)
        record["intentDigest"] = .string(String(repeating: "a", count: 64)); record["grantRef"] = .null; record["scopeRef"] = .string("scope-one")
        record["sessionId"] = .string("worker-session"); record["stopIntent"] = .null
        record["workerModel"] = .object(["provider": .string("anthropic"), "id": .string("claude-opus-5-5")])
        record["subagents"] = .object(["started": .number(2), "stoppedAtEnd": .number(1)])
        record["subagentRuns"] = .object(["total": .number(id == "active" ? 1 : 0), "runs": .array(id == "active" ? [.object(["runId": .string("run-live"), "agent": .string("researcher"), "state": .string("running"), "startedAt": .string(isoAgo(900)), "lastActivityAt": .string(isoAgo(120))])] : [])])
        record["reportRef"] = id == "terminal" ? .object(["resultId": .string("report-one"), "sessionId": .string("worker-session"),
            "entryId": .string("report-entry"), "digest": .string(String(repeating: "b", count: 64))]) : .null
        record["intent"] = .object(["text": .string(id == "active"
            ? """
              Continue epic #758 (settings model) on its integration branch. Implement the next slice, keep draft PR 798 updated, and **do not merge**.

              Steps:
              - Merge `origin/main` into the integration branch first.
              - Land the *layer badge* slice behind the existing schema.
              - Run `scripts/tron work verify` before every push.
              - Report the PR head and the journeys you ran.

              Keep the settings model doc in step with each slice.
              """
            : "Draft the email that summarises Thursday's garden review and send it for approval.")])
        record["operationId"] = .string("task-operation")
        let terminal = id == "terminal"
        record["terminalEvidence"] = terminal ? .object(["outcome": .string(id == "active" ? "interrupted" : "final"), "reason": .string("explicit-report"), "sessionId": .string("worker-session"), "entryIds": .array([.string("terminal-entry")])]) : .null
        record["wake"] = terminal ? .object(["state": .string(id == "terminal" && !taskRedelivered ? "blocked" : "pending"),
            "routeGeneration": .number(taskRedelivered ? 2 : 1), "delivery": .null,
            "eventId": .string("task-result-" + String(repeating: "b", count: 64)), "createdAt": .string("2026-01-01T00:00:00Z"),
            "push": .string("decided"), "acknowledgedAt": .null, "redeliveries": .array([])]) : .null
        for key in ["outcome", "attention", "pendingGrant"] { record.removeValue(forKey: key) }
        return .object(record)
    }
    private func taskBinding() -> JSONValue {
        .object(["intentDigest": .string(String(repeating: "a", count: 64)),
            "target": .string("/trusted/project"), "authorizationScope": .string("full-work"), "restoreEpoch": .string("fixture-epoch")])
    }
    private func taskPermissions() -> JSONValue {
        let ids = ["request-existing", "request-approve", "request-deny"]
        let binding = taskBinding()
        // A grant's expiry must equal its decision's exactly; read the clock once.
        let expiresAt = nowMilliseconds() + 604_800_000
        var decisions: [JSONValue] = [.object(["id": .string("existing-decision"), "requestId": .string("request-existing"),
            "decidedAt": .number(1000), "approved": .bool(true), "expiresAt": .number(expiresAt)])]
        decisions += taskDecisions.keys.sorted().map { taskDecisions[$0]!.objectValue!["decision"]! }
        var grant = binding.objectValue!
        grant["id"] = .string("grant-one"); grant["decisionId"] = .string("existing-decision")
        grant["expiresAt"] = .number(expiresAt); grant["state"] = .string(grantRevoked ? "revoked" : "available")
        var scope: [String: JSONValue] = ["id": .string("scope-one"), "kind": .string("all-trusted-projects"),
            "active": .bool(!scopeRevoked), "restoreEpoch": .string("fixture-epoch"), "createdAt": .number(1000)]
        if scopeRevoked { scope["revokedAt"] = .number(2000) }
        if ProcessInfo.processInfo.arguments.contains("-home-permissions-empty") {
            return .object(["revision": .number(1), "needsReconfirmation": .bool(false), "scopes": .array([.object(scope)]),
                            "requests": .array([]), "decisions": .array([]), "grants": .array([])])
        }
        return .object(["revision": .number(Double(controlCount + 1)), "scopes": .array([.object(scope)]),
            "needsReconfirmation": .bool(ProcessInfo.processInfo.arguments.contains("-home-permissions-restored") && !scopeRevoked && controlCount == 0),
            "requests": .array(ids.map { .object(["id": .string($0), "request": binding]) }), "decisions": .array(decisions), "grants": .array([.object(grant)] + taskDecisions.keys.sorted().compactMap { taskDecisions[$0]!.objectValue!["grant"].flatMap { $0 == .null ? nil : $0 } })])
    }

    private func model(_ id: String, name: String, virtual: Bool = false) -> JSONValue {
        .object(["provider": .string("fixture"), "id": .string(id), "name": .string(name), "reasoning": .bool(false),
                 "input": .array([.string("text")]), "contextWindow": .number(8192), "maxTokens": .number(1024),
                 "available": .bool(true), "virtual": .bool(virtual)])
    }
    private func anthropicModel(_ id: String, name: String, window: Int) -> JSONValue {
        .object(["provider": .string("anthropic"), "id": .string(id), "name": .string(name), "reasoning": .bool(true),
                 "input": .array([.string("text")]), "contextWindow": .number(Double(window)), "maxTokens": .number(64_000),
                 "available": .bool(true), "virtual": .bool(false)])
    }
    /// The Home chat's own configuration, as a real session reports it: its model,
    /// thinking, context window usage, token totals and cost, and its window policy.
    private func applyHomeChatConfiguration(to snapshot: inout SessionSnapshot) {
        let model = ModelRef(provider: "anthropic", id: "claude-opus-5-5")
        snapshot.model = model
        snapshot.thinkingLevel = "high"
        snapshot.availableThinkingLevels = ["off", "low", "medium", "high"]
        snapshot.contextUsage = try! JSONValue.object(["tokens": .number(30_800), "contextWindow": .number(1_000_000),
            "percent": .number(3.08)]).decode(ContextUsage.self)
        snapshot.stats = SessionStats(userMessages: 6, assistantMessages: 6, toolCalls: 4, toolResults: 4, totalMessages: 12,
            tokens: .init(input: 412_000, output: 38_000, cacheRead: 1_230_000, cacheWrite: 96_000, total: 1_776_000),
            latestCacheHitRate: 91.4, cost: 9.37)
        snapshot.contextWindowPolicy = try! JSONValue.object(["model": try! JSONValue.encode(model), "minimum": .number(8_192),
            "maximum": .number(1_000_000), "default": .number(200_000), "effective": .number(1_000_000), "override": .null,
            "source": .string("model"), "warning": .null]).decode(ContextWindowPolicy.self)
    }
    private func anthropicRef(_ id: String) -> JSONValue {
        .object(["provider": .string("anthropic"), "id": .string(id)])
    }
    /// An ISO timestamp the given seconds before now, so fixture rows read as recent.
    private func nowMilliseconds() -> Double {
        (Date.now.timeIntervalSince1970 * 1000).rounded(.down)
    }
    private func isoAgo(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date.now.addingTimeInterval(-seconds))
    }
    /// The exact evidence of one memory message, in the chapter that holds it.
    private func evidence(index: Int = 0, sessionID: String = "home-chapter-sealed") -> JSONValue {
        .object(["index": .number(Double(index)), "sessionId": .string(sessionID), "entryId": .string("source-entry"),
                 "sourceDigest": .string(String(repeating: "a", count: 64))])
    }
    /// Home's memory view over 40 messages: chapter 1 (sealed) holds messages 0–31
    /// and chapter 2 (active) 32–39. Older ranges are summary lines (`0+16`, `16+8`,
    /// `24+4`, `28+4`, `32+2`); the six newest messages are their own lines.
    private static let memoryTotal = 40
    private static let memorySealedEnd = 32
    private static let memoryViewParts: [(start: Int, span: Int)] =
        [(0, 16), (16, 8), (24, 4), (28, 4), (32, 2)] + (34..<40).map { ($0, 1) }
    private static let memoryMessages: [(kind: String, text: String)] = [
        ("user", "Move the garden planning to Thursday reviews."),
        ("talk", "Scheduled the **garden review** for Thursday at `10:00`."),
        ("echo", "Created calendar event: Garden review, Thursday 10:00."),
        ("event", "Task result: settings model epic #758 finished."),
        ("user", "Email me the Thursday summary."),
        ("talk", "Will email the summary Thursday morning."),
    ]

    private func memoryItem(_ index: Int) -> JSONValue {
        let message = Self.memoryMessages[index % Self.memoryMessages.count]
        let attribution = ["user": "user", "talk": "assistant", "echo": "tool", "event": "event"][message.kind]!
        let session = index < Self.memorySealedEnd ? "home-chapter-sealed" : "home-session"
        let summary: JSONValue = index % 6 == 1 ? .null : .object(["format": .string("memory-summary"),
            "text": .string(message.kind + ": " + message.text), "truncated": .bool(false)])
        return .object([
            "index": .number(Double(index)), "kind": .string(message.kind), "attribution": .string(attribution),
            "timestamp": .string(memoryTime(index)), "evidence": evidence(index: index, sessionID: session),
            "projection": .object(["format": .string("memory-projection"), "text": .string(message.text),
                "omitted": .bool(false), "omissions": .array([])]),
            "summary": summary,
        ])
    }

    private func memoryTime(_ index: Int) -> String { isoAgo(Double(Self.memoryTotal - index) * 3 * 3_600) }

    private func memorySummaryText(start: Int, span: Int) -> String {
        switch (start, span) {
        case (0, 16): "Planned the spring garden: moved reviews to Thursdays, chose raised beds for the south fence, and set a weekly email summary."
        case (16, 8): "Booked the Lisbon trip for May, compared two hotels near Alfama and asked Home to watch for fare drops."
        case (24, 4): "Reviewed the kitchen renovation quote and asked for a second bid on the countertops."
        case (28, 4): "Closed out chapter 1: settings model epic #758 finished and its report was delivered."
        case (32, 2): "Started chapter 2 by asking for the Thursday garden review and a reminder to order mulch."
        default: "Messages \(start + 1)–\(start + span): garden planning, travel and renovation follow-ups."
        }
    }

    private func memoryLine(start: Int, span: Int) -> JSONValue {
        var line: [String: JSONValue] = ["start": .number(Double(start)), "span": .number(Double(span)),
            "truncated": .bool(false), "firstAt": .string(memoryTime(start)), "lastAt": .string(memoryTime(start + span - 1))]
        if span == 1 {
            let message = Self.memoryMessages[start % Self.memoryMessages.count]
            line["text"] = .string(message.text); line["kind"] = .string(message.kind); line["item"] = memoryItem(start)
        } else {
            line["text"] = .string(memorySummaryText(start: start, span: span))
        }
        return .object(line)
    }

    /// `home.memory.view`: newest first; the whole view pages ten lines then the rest,
    /// a chapter answers its own lines, and a part answers its two halves.
    private func memoryView(_ params: [String: JSONValue], empty: Bool) -> JSONValue {
        let revision = JSONValue.string(String(repeating: "a", count: 64))
        func view(_ lines: [JSONValue], next: String? = nil) -> JSONValue {
            var result: [String: JSONValue] = ["homeId": .string("home-fixture"), "revision": revision,
                "totalMessages": .number(Double(empty ? 0 : Self.memoryTotal)), "lines": .array(empty ? [] : lines)]
            if let next, !empty { result["nextCursor"] = .string(next) }
            return .object(result)
        }
        if let part = params["part"]?.objectValue, let start = part["start"]?.intValue, let span = part["span"]?.intValue {
            return view([memoryLine(start: start, span: span / 2), memoryLine(start: start + span / 2, span: span / 2)])
        }
        let range = switch params["sessionId"]?.stringValue {
        case "home-chapter-sealed": 0..<Self.memorySealedEnd
        case "home-session": Self.memorySealedEnd..<Self.memoryTotal
        default: 0..<Self.memoryTotal
        }
        let lines = Self.memoryViewParts.filter { range.contains($0.start) }.reversed().map { memoryLine(start: $0.start, span: $0.span) }
        guard params["sessionId"] == nil, lines.count > 10 else { return view(Array(lines)) }
        return params["cursor"] == nil ? view(Array(lines.prefix(10)), next: "fixture-next") : view(Array(lines.dropFirst(10)))
    }

    /// `home.context`: the activation's request sizes with the body-free breakdown
    /// (sections sum to the effective tokens; the chapter section takes the remainder).
    private func contextProjection() -> JSONValue {
        if emptyContext { return .object(["available": .bool(false)]) }
        return .object(["available": .bool(true), "activationStartEntryId": .string("activation-entry"), "activationOpen": .bool(true),
            "viewLines": .number(412), "viewBytes": .number(18_400), "effectiveTokens": .number(30_800), "contextWindow": .number(1_000_000),
            "breakdown": .object([
                "activation": .object(["state": .string("running"), "kind": .string("user"), "startedAt": .string(isoAgo(240))]),
                "contextWindow": .number(1_000_000), "effectiveTokens": .number(30_800),
                "sections": .array([
                    .object(["id": .string("instructions"), "tokens": .number(8_000)]),
                    .object(["id": .string("profile"), "tokens": .number(1_200), "count": .number(3)]),
                    .object(["id": .string("memory"), "tokens": .number(20_000), "count": .number(260)]),
                    .object(["id": .string("chapter"), "tokens": .number(1_500), "count": .number(12)]),
                    .object(["id": .string("results"), "tokens": .number(0), "count": .number(0)]),
                    .object(["id": .string("input"), "tokens": .number(100)]),
                ]),
            ])])
    }

    /// The Gateway's rollover shape: the reserved successor is named but absent.
    /// The sealed predecessor is the openable route until a logical prompt
    /// materializes the successor.
    private var hostPressure: JSONValue {
        let args = ProcessInfo.processInfo.arguments
        let level = args.contains("-host-critical") ? "critical" : args.contains("-host-elevated") ? "elevated" : "normal"
        return .object(["level": .string(level)])
    }

    private var workers: JSONValue {
        let args = ProcessInfo.processInfo.arguments
        return .object(["running": .number(args.contains("-host-critical") ? 7 : args.contains("-host-elevated") ? 1 : 0)])
    }

    private func rolloverStatus() -> JSONValue {
        .object(["hostPressure": hostPressure, "workers": workers, "taskRecovery": .object(["available": .bool(true)]), "routeGeneration": .number(2),
            "phase": .string(materialized ? "ready" : "rollover-pending"),
            "activation": .object(["available": .bool(true), "activationOpen": .bool(false), "effectiveTokens": .number(30_800),
                "contextWindow": .number(1_000_000), "viewLines": .number(412), "viewBytes": .number(18_400)]),
            "readiness": .object(["ready": .bool(materialized), "gaps": .array(materialized ? [] : [.string("session-missing")])]),
            "recovery": .object(["action": .string(materialized ? "none" : "designate")]),
            "available": .bool(true), "enabled": .bool(true), "homeId": .string("home-fixture"),
            "sessionId": .string("home-successor"), "openSessionId": .string(materialized ? "home-successor" : "home-session"),
            "generation": .number(1), "live": .bool(false), "sessionPresent": .bool(materialized),
            "memory": .object(["configured": .bool(true), "open": .bool(true), "paused": .bool(false),
                "spentTokens": .number(42), "model": .null])])
    }

    private func homeStatus() -> JSONValue {
        if initialState == "rollover" { return rolloverStatus() }
        let phase = designated ? (phase == "unconfigured" ? "blocked" : phase) : self.phase == "disabled" || initialState == "disabled" ? "disabled"
            : initialState == "missing-session" ? "missing-session" : "undesignated"
        let sessionPresent = designated || initialState == "disabled" || phase == "disabled"
        let enabled = designated || initialState == "missing-session"
        return .object(["hostPressure": hostPressure, "workers": workers,
            "taskRecovery": .object(["available": .bool(sheetState != "task-fenced"), "reason": .string("unsafe-state")]),
            "routeGeneration": .number(2), "phase": .string(phase),
            "activation": emptyContext ? .object(["available": .bool(false)]) : .object(["available": .bool(true), "activationOpen": .bool(phase == "active"),
                "effectiveTokens": .number(30_800), "contextWindow": .number(1_000_000), "viewLines": .number(12), "viewBytes": .number(480)]),
            "readiness": .object(["ready": .bool(designated && phase == "ready"), "gaps": .array([])]),
            "recovery": .object(["action": .string(designated ? "none" : "designate")]),
            "available": .bool(true), "enabled": .bool(enabled),
            "homeId": designated || initialState == "disabled" || initialState == "missing-session" ? .string("home-fixture") : .null,
            "sessionId": sessionPresent ? .string("home-session") : .null,
            "openSessionId": sessionPresent ? .string("home-session") : .null,
            "generation": .number(1), "live": .bool(false), "sessionPresent": .bool(sessionPresent),
            "waitingForUser": .bool(ProcessInfo.processInfo.arguments.contains("-home-waiting")),
            "model": designated ? .object(["provider": .string("anthropic"), "id": .string("claude-opus-5-5")]) : .null,
            "chapter": designated ? .object(["count": .number(2), "currentBytes": .number(480),
                "currentEntries": .number(12), "recoveryDecision": .string("none")]) : .null,
            "memory": .object(["configured": .bool(configured), "open": .bool(true), "paused": .bool(paused),
                "blocked": phase == "blocked" && configured ? .string("source-unavailable") : .null,
                "spentTokens": .number(10_000_000), "models": .array((configuredModels.isEmpty && configured ? ["anthropic/claude-haiku-5-5"] : configuredModels).map(JSONValue.string))])])
    }
}

private actor HostedHomeShellSocket: GatewaySocketConnection {
    private let gateway: HostedHomeShellGateway
    private var inbound: [Data]
    private var receivers: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    init(gateway: HostedHomeShellGateway) {
        self.gateway = gateway
        inbound = []
        Task {
            let caps = await gateway.capabilities()
            let data = try! JSONEncoder.gateway.encode(JSONValue.object(["type": .string("hello"), "gatewayVersion": .string("fixture"),
                "piVersion": .string("fixture"), "protocolVersion": .number(8), "minProtocolVersion": .number(8),
                "machineId": .string("home-shell-fixture"), "machineName": .string("Home fixture"),
                "gatewayChannel": .string("stable"), "capabilities": .array(caps.map(JSONValue.string))]))
            await deliver(data)
        }
    }
    func send(_ data: Data) async throws {
        guard !closed else { throw CancellationError() }
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue ?? [:]
        guard frame["type"]?.stringValue == "request", let id = frame["id"]?.stringValue,
              let method = frame["method"]?.stringValue else { return }
        let params = frame["params"]?.objectValue ?? [:]
        let result: (JSONValue?, JSONValue?)
        do {
            result = try await gateway.handle(method, frame["params"]?.objectValue ?? [:])
        } catch is CancellationError {
            return
        }
        var response: [String: JSONValue] = ["type": .string("response"), "id": .string(id), "ok": .bool(result.1 == nil)]
        if let body = result.0 { response["result"] = body }
        if let failure = result.1 { response["error"] = failure }
        await deliver(try JSONEncoder.gateway.encode(JSONValue.object(response)))
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
    private func deliver(_ data: Data) { if receivers.isEmpty { inbound.append(data) } else { receivers.removeFirst().resume(returning: data) } }
}

private actor HostedChatDisplaySocket: GatewaySocketConnection {
    private var hello = true
    private var receiver: CheckedContinuation<Data, Error>?
    private var inbound: [Data] = []
    private var closed = false
    func deliver(_ data: Data) {
        guard !closed else { return }
        if let receiver { self.receiver = nil; receiver.resume(returning: data) } else { inbound.append(data) }
    }
    func resume() async { }
    func send(_ data: Data) async throws { }
    func ping() async throws { }
    func receive() async throws -> Data {
        guard !closed else { throw CancellationError() }
        if hello {
            hello = false
            return Data(#"{"type":"hello","gatewayVersion":"fixture","piVersion":"fixture","protocolVersion":8,"minProtocolVersion":8,"machineId":"fixture-machine","machineName":"Fixture","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
        }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { receiver = $0 }
    }
    func close() async {
        closed = true
        receiver?.resume(throwing: CancellationError())
        receiver = nil
    }
}

/// Home's workers for the Home dashboard view journeys: running, waiting,
/// recently completed and unread rows (each more than its section shows), each
/// carrying the Gateway's `homeTaskId`, plus usage-capable providers.
enum HostedHomeDashboardWorkers {
    private static func iso(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
    }

    private static func worker(_ id: String, _ name: String, cwd: String, ago: TimeInterval, phase: SessionPhase = .idle,
                               waiting: Bool = false, unread: Bool = false) -> SessionSummary {
        SessionSummary(id: id, name: name, cwd: cwd, parentSessionId: nil,
            homeTaskId: id.hasPrefix("worker-") ? "task-\(id)" : nil, createdAt: iso(ago + 600), updatedAt: iso(ago),
            activeSince: phase.isActive ? iso(ago) : nil, messageCount: 4, firstMessage: name, phase: phase,
            foregroundPhase: phase.isActive ? .running : nil, waitingForUser: waiting, summaryRevision: 1,
            completionRevision: unread ? 1 : 0, isUnread: unread)
    }

    static let sessions: [SessionSummary] = [
        worker("worker-running", "Home dashboard view prototype", cwd: "/work/tron", ago: 120, phase: .running),
        worker("worker-waiting", "Lisbon fare watch", cwd: "/work/travel", ago: 300, phase: .running, waiting: true),
        worker("worker-done-1", "Settings model epic report", cwd: "/work/tron", ago: 1_800),
        worker("worker-done-2", "Garden review email draft", cwd: "/work/home", ago: 3_600),
        worker("worker-done-3", "Kitchen countertop bids", cwd: "/work/home", ago: 7_200),
        worker("worker-done-4", "Quarterly budget summary", cwd: "/work/finance", ago: 14_400),
        worker("worker-done-5", "Push relay certificate check", cwd: "/work/tron", ago: 28_800),
        worker("worker-done-6", "Raindrop triage", cwd: "/work/knowledge", ago: 86_400),
        worker("worker-done-7", "Simulator lane cleanup", cwd: "/work/tron", ago: 172_800),
        worker("worker-unread-1", "Weekly reading digest", cwd: "/work/knowledge", ago: 5_400, unread: true),
        worker("worker-unread-2", "Mac reinstall preflight", cwd: "/work/tron", ago: 604_800, unread: true),
        worker("worker-unread-3", "Photo library dedupe plan", cwd: "/work/home", ago: 1_209_600, unread: true),
        worker("worker-unread-4", "Insurance renewal comparison", cwd: "/work/finance", ago: 1_500_000, unread: true),
        worker("worker-unread-5", "Router firmware notes", cwd: "/work/home", ago: 1_600_000, unread: true),
        // An ordinary unread chat: no Home task names it, yet it joins the Unread queue.
        worker("chat-unread", "Apple Watch app", cwd: "/work/tron", ago: 1_814_400, unread: true),
    ]

    static let newWorker = worker("worker-new", "Freshly dispatched worker", cwd: "/work/tron", ago: 5, phase: .running)

    /// `-home-usage-long-name` adds a single-window provider with a long name.
    private static var longName: Bool { ProcessInfo.processInfo.arguments.contains("-home-usage-long-name") }
    /// `-home-usage-opencode-go` adds OpenCode Go's three plan windows: 5h idle,
    /// weekly past the warning level and the monthly limit reached (#1163).
    private static var openCodeGo: Bool { ProcessInfo.processInfo.arguments.contains("-home-usage-opencode-go") }

    static var providers: JSONValue {
        .object(["providers": .array([
            provider("anthropic", "Anthropic"), provider("openai-codex", "OpenAI Codex"),
            provider("fixture", "Fixture", usage: false),
        ] + (longName ? [provider("cortexkit", "Anthropic (CortexKit)")] : [])
          + (openCodeGo ? [provider("opencode-go", "OpenCode Go")] : []))])
    }

    private static func provider(_ id: String, _ name: String, usage: Bool = true) -> JSONValue {
        .object(["id": .string(id), "name": .string(name), "configured": .bool(true), "usageSupported": .bool(usage),
                 "authMethods": .array([]), "modelCount": .number(3)])
    }

    static var usage: JSONValue {
        func window(_ id: String, _ label: String, _ percent: Double, _ seconds: Int, resetsIn: TimeInterval? = nil) -> JSONValue {
            var row: [String: JSONValue] = ["id": .string(id), "label": .string(label), "usedPercent": .number(percent),
                                            "windowSeconds": .number(Double(seconds))]
            if let resetsIn { row["resetsAt"] = .string(iso(-resetsIn)) }
            return .object(row)
        }
        func snapshot(_ id: String, _ windows: [JSONValue]) -> JSONValue {
            .object(["providerId": .string(id), "status": .string("available"), "updatedAt": .string(iso(60)),
                     "stale": .bool(false), "windows": .array(windows), "balances": .array([])])
        }
        return .object(["providers": .array([
            snapshot("anthropic", [window("five-hour", "5h", 42, 18_000), window("weekly", "Weekly", 18, 604_800)]),
            snapshot("openai-codex", [window("five-hour", "5h", 7, 18_000), window("weekly", "Weekly", 2, 604_800)]),
        ] + (longName ? [snapshot("cortexkit", [window("weekly", "Weekly", 48, 604_800)])] : [])
          + (openCodeGo ? [snapshot("opencode-go", [
              window("rolling", "5h", 0, 18_000, resetsIn: 18_000), window("weekly", "Weekly", 72, 604_800, resetsIn: 172_800),
              window("monthly", "Monthly", 100, 2_592_000, resetsIn: 259_200),
          ])] : []))])
    }
}

/// The #479 terminal fixture: a closed terminal with the Gateway's reason, and
/// the live terminal the sheet opens beside it.
private enum HostedClosedTerminal {
    static let closed: JSONValue = .object([
        "id": .string("closed-terminal"), "sessionId": .string("home-session"), "cwd": .string("/workspace"),
        "createdAt": .string("2026-01-01T09:00:00Z"), "exitedAt": .string("2026-01-01T10:01:00Z"), "exitCode": .number(0),
        "sequence": .number(2), "closedReason": .string("Closed after 60 minutes idle"),
    ])
    static let live: JSONValue = .object([
        "id": .string("live-terminal"), "sessionId": .string("home-session"), "cwd": .string("/workspace"),
        "createdAt": .string("2026-01-01T11:00:00Z"), "sequence": .number(1),
    ])
    static func chunk(_ sequence: Int, _ data: String) -> JSONValue {
        .object(["sequence": .number(Double(sequence)), "data": .string(data)])
    }
}
#endif
