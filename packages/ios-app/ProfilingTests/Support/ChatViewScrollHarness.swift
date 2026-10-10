import SwiftUI
import Testing
@testable import TronMobileCore
import UIKit
@testable import TronMobile



/// The operation identity the hosted composer send stub returns for every
/// submission (`composerSubmissionHarness`). An acknowledgement must carry it:
/// `ComposerDraftCoordinator` reconciles an admitted submission only against a
/// canonical user row whose `presentationId` is that operation ID.
let harnessHostedPromptOperationID = "hosted-prompt-operation"

/// The bottom-coverage evidence of one sampled display boundary, in window
/// coordinates. `blank` is the CT-2 blank oracle: no mounted transcript row
/// intersects the visible transcript at all. `uncoveredBand` is the pinned
/// bottom band left without a mounted row, which is what catches the partial
/// blanks ("stops short", rows far above the composer) a whole-screen test
/// misses. `visibleRowFraction` is how much of the visible transcript the
/// mounted rows cover.
struct TranscriptBottomCoverage: Sendable, Equatable {
    let blank: Bool
    let uncoveredBand: Bool
    let visibleRowFraction: CGFloat
    let newestRowClearance: CGFloat?
}

struct CT2BoundarySample {
    let contentHeight: CGFloat
    let offsetY: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat
    let visibleRowCount: Int
    let tallRowFrame: CGRect?
    let coverage: TranscriptBottomCoverage
}

struct KeyboardInsetTransition: Sendable {
    let height: CGFloat
    let duration: Double
    let curve: UIView.AnimationCurve
    /// The driven display boundaries the inset's steps are spread over. The
    /// keyboard interpolates for `duration`; this lane's boundary is about
    /// one display frame, so the count stands for that duration here.
    let boundaries: Int

    /// A full-height keyboard on this window at the iOS keyboard's usual
    /// 250 ms curve, the transition a real keyboard delivers.
    static func show(
        height: CGFloat = 336,
        duration: Double = 0.25,
        curve: UIView.AnimationCurve = .easeInOut,
        boundaries: Int = 12
    ) -> KeyboardInsetTransition {
        KeyboardInsetTransition(
            height: height, duration: duration, curve: curve, boundaries: boundaries
        )
    }

    /// The same transition back to no keyboard.
    static func hide(
        duration: Double = 0.25,
        curve: UIView.AnimationCurve = .easeInOut,
        boundaries: Int = 12
    ) -> KeyboardInsetTransition {
        KeyboardInsetTransition(height: 0, duration: duration, curve: curve, boundaries: boundaries)
    }
}

/// One display boundary of the safe-area keyboard journey: the gap the reader
/// sees between the newest row's bottom edge and the composer's top edge, the
/// composer's own top edge and height, all in window coordinates. The gap is the
/// quantity P0-1's scenario records; the composer's absolute position is what
/// shows the keyboard's inset actually moved it.
struct KeyboardBoundarySample {
    let clearance: CGFloat?
    let composerTop: CGFloat?
    let composerHeight: CGFloat
    let coverage: TranscriptBottomCoverage
    let distanceFromNewest: CGFloat
    let tailState: String?
}






private func harnessInlineMarkdownDisplaySnapshot() throws -> SessionSnapshot {
    var snapshot = try SessionScenarioBuilder(seed: 1_210).openingTail(targetEncodedBytes: 10_000)
    snapshot.transcript = try decodeTranscriptFixture(
        [TranscriptItem].self,
        from: Data(#"""
        [
          {"id":"display-request","parentId":null,"presentationId":"display-request","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"display-call-content","ordinal":0,"type":"toolCall","toolCallId":"display-call","name":"display","arguments":{"presentation":{"surface":"inline"}}}
          ]},
          {"id":"display-result","parentId":"display-request","presentationId":"display-result","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"display-result-text","ordinal":0,"type":"text","text":"Displayed Inline Markdown."}],"toolCallId":"display-call","toolName":"display","isError":false,
           "display":{"schema":"tron.display.v1","displayId":"inline-markdown","revision":1,"title":"Inline Markdown","altText":"An inline Markdown fixture.","kind":"markdown","presentation":{"requestedSurface":"inline","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline"],"fallbackText":"Inline Markdown fixture.","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc3b","name":"inline.md","mimeType":"text/markdown","size":335,"kind":"markdown"}}},
          {"id":"display-answer","parentId":"display-result","presentationId":"display-answer","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"display-answer-text","ordinal":0,"type":"text","text":"Displayed Inline Markdown inline."}]}
        ]
        """#.utf8)
    )
    snapshot.transcriptStart = 0
    snapshot.transcriptTotal = snapshot.transcript.count
    snapshot.toolExecutions = []
    return snapshot
}

func harnessRuntimeTool(
    id: String = "active-race",
    order: Int = 0,
    status: ToolExecutionState.Status,
    groupId: String? = nil,
    groupIndex: Int = 0,
    groupCount: Int = 1,
    groupFinalized: Bool = true
) -> ToolExecutionState {
    ToolExecutionState(
        toolCallId: id,
        toolName: "read",
        order: order,
        status: status,
        arguments: .object(["path": .string("README.md")]),
        partialResult: nil,
        result: status == .completed ? .object(["ok": .bool(true)]) : nil,
        output: status == .completed ? "done" : nil,
        isError: false,
        startedAt: "2026-01-01T00:00:00Z",
        updatedAt: status == .completed ? "2026-01-01T00:00:01Z" : "2026-01-01T00:00:00Z",
        completedAt: status == .completed ? "2026-01-01T00:00:01Z" : nil,
        durationMs: status == .completed ? 1_000 : nil,
        progressSequence: status == .completed ? 2 : 1,
        groupId: groupFinalized ? (groupId ?? id) : nil,
        groupIndex: groupFinalized ? groupIndex : nil,
        groupCount: groupFinalized ? groupCount : nil,
        groupFinalized: groupFinalized ? true : nil
    )
}

func harnessAssistantMessage(
    id: String,
    presentationID: String,
    text: String
) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"presentationId":"\(presentationID)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"\(id):text","ordinal":0,"type":"text","text":"\(text)"}]}
        """.utf8)
    )
}

func harnessRichAssistantMessage(
    id: String,
    presentationID: String,
    thinkingLines: [String],
    text: String
) throws -> TranscriptItem {
    var content: [[String: Any]] = []
    if !thinkingLines.isEmpty {
        content.append([
            "id": "\(id):thinking",
            "ordinal": 0,
            "thinkingRunOrdinal": 0,
            "type": "thinking",
            "text": thinkingLines.joined(separator: "\n")
        ])
    }
    content.append([
        "id": "\(id):text",
        "ordinal": thinkingLines.isEmpty ? 0 : 1,
        "type": "text",
        "text": text
    ])
    let data = try JSONSerialization.data(withJSONObject: [
        "id": id,
        "parentId": NSNull(),
        "presentationId": presentationID,
        "timestamp": "2026-01-01T00:00:00Z",
        "kind": "message",
        "role": "assistant",
        "content": content
    ])
    return try decodeTranscriptFixture(TranscriptItem.self, from: data)
}

func harnessUserMessage(id: String, text: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"presentationId":"\(id)","timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"\(id):text","ordinal":0,"type":"text","text":"\(text)"}]}
        """.utf8)
    )
}

func harnessMessage(id: String) throws -> TranscriptItem {
    try decodeTranscriptFixture(
        TranscriptItem.self,
        from: Data("""
        {"id":"\(id)","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"\(id):text","type":"text","text":"A new response"}]}
        """.utf8)
    )
}

@MainActor @Observable
private final class HarnessCoverState {
    var presented = false
    var scenePhase: ScenePhase = .active
    var rootToken: PresentationSurfaceToken?
    let coordinator = PresentationActivityCoordinator()
}

private struct HarnessManagedSurface: View {
    let content: AnyView
    @Bindable var cover: HarnessCoverState

    var body: some View {
        TronPresentationSurface(id: "harness-chat", onMount: { cover.rootToken = $0 }) {
            content.tronManagedSheet(isPresented: $cover.presented, identity: "harness-cover") {
                Text("Covered chat").presentationDetents([.medium])
            }
        }
        .environment(\.tronPresentationActivityCoordinator, cover.coordinator)
        // UIHostingController is not a SwiftUI Scene; declare this fixture's
        // scene input independently of its real native sheet ownership.
        .environment(\.scenePhase, cover.scenePhase)
    }
}

@MainActor
final class ChatViewScrollHarness {
    let snapshot: SessionSnapshot
    let transcriptIDs: Set<String>
    let firstTranscriptID: String
    let lastTranscriptID: String
    let recorder: PresentedFrameRecorder
    let signposts: RecordingPerformanceSignposts
    let probe: ChatHostedProbe
    /// The mounted callbacks a hosted test activates through the control that
    /// owns them (a SwiftUI button cannot be tapped from the harness).
    let toolActionProbe = HostedToolActionProbe()

    private struct Dependencies {
        let suiteName: String
        let defaults: UserDefaults
        let cacheRoot: URL
        let client: GatewayClient
        let model: AppModel
        let socket: ScriptedGatewaySocket?
        let profile: GatewayProfile?
        fileprivate let uploads: HostedUploadReceipt
    }

    private let model: AppModel
    private let client: GatewayClient
    private let socket: ScriptedGatewaySocket?
    fileprivate let uploads: HostedUploadReceipt
    private var rpcTask: Task<Void, Never>?
    private(set) var rpcMethods: [String] = []
    private let suiteName: String
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private let window: UIWindow
    private let hostingController: UIHostingController<AnyView>
    private let cover = HarnessCoverState()
    /// The sole transcript orientation exercised by hosted chat journeys.
    let orientation: ChatTranscriptOrientation

    convenience init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil,
        enablesPresentationCover: Bool = false,
        installsSubscribedSnapshot: Bool = true,
        scrollCallbackMode: ChatHostedScrollCallbackMode = .synthetic,
        mediaFetch: ChatMediaFetch? = nil,
        orientation: ChatTranscriptOrientation = .newestAtOrigin,
        reduceMotionEnabled: Bool = false
    ) throws {
        let dependencies = try Self.makeDependencies(
            enablesComposerSubmission: false,
            mediaFetch: mediaFetch
        )
        try self.init(
            snapshot: snapshot,
            displayFrameScheduler: displayFrameScheduler,
            performanceSignposts: performanceSignposts,
            dependencies: dependencies,
            installsSubscribedSnapshot: installsSubscribedSnapshot,
            enablesPresentationCover: enablesPresentationCover,
            scrollCallbackMode: scrollCallbackMode,
            orientation: orientation,
            reduceMotionEnabled: reduceMotionEnabled
        )
    }

    static func composerSubmissionHarness(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)? = nil,
        enablesPresentationCover: Bool = false,
        usesRealOpening: Bool = false,
        unansweredRPCMethods: Set<String> = [],
        mediaFetch: ChatMediaFetch? = nil,
        orientation: ChatTranscriptOrientation = .newestAtOrigin,
        reduceMotionEnabled: Bool = false
    ) async throws -> ChatViewScrollHarness {
        let dependencies = try makeDependencies(
            enablesComposerSubmission: true,
            mediaFetch: mediaFetch
        )
        guard let socket = dependencies.socket, let profile = dependencies.profile else {
            throw HarnessError.invalidAuthorityBoundary
        }
        await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"hosted-machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","skill-prompt.v1"]}"#.utf8))
        do {
            try await dependencies.model.connectHostedGateway(
                profile: profile,
                token: "hosted-token"
            )
            let harness = try ChatViewScrollHarness(
                snapshot: snapshot,
                displayFrameScheduler: displayFrameScheduler,
                performanceSignposts: performanceSignposts,
                dependencies: dependencies,
                installsSubscribedSnapshot: true,
                enablesPresentationCover: enablesPresentationCover,
                usesRealOpening: usesRealOpening,
                orientation: orientation,
                reduceMotionEnabled: reduceMotionEnabled
            )
            if usesRealOpening { await harness.startRPCResponder(unansweredMethods: unansweredRPCMethods) }
            return harness
        } catch {
            await dependencies.model.teardown()
            await dependencies.client.close()
            dependencies.defaults.removePersistentDomain(forName: dependencies.suiteName)
            try? FileManager.default.removeItem(at: dependencies.cacheRoot)
            throw error
        }
    }

    private static func makeDependencies(
        enablesComposerSubmission: Bool,
        mediaFetch: ChatMediaFetch? = nil
    ) throws -> Dependencies {
        let suiteName = "ChatViewScrollHarnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(
            path: suiteName,
            directoryHint: .isDirectory
        )
        let socket = enablesComposerSubmission ? ScriptedGatewaySocket() : nil
        let profile = enablesComposerSubmission ? GatewayProfile(
            id: "hosted-chat",
            label: "Hosted Chat",
            host: "gateway.test",
            port: 9_847,
            machineId: "hosted-machine",
            deviceId: "hosted-device"
        ) : nil
        if let profile {
            defaults.set(
                try JSONEncoder.gateway.encode([profile]),
                forKey: "gatewayProfiles.v1"
            )
            defaults.set(profile.id, forKey: "selectedGateway.v1")
        }
        let client = if let socket {
            GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        } else {
            GatewayClient()
        }
        let hostedSend: ComposerSendOperation = {
            _, _, _, _, _, _ in harnessHostedPromptOperationID
        }
        let composerSend: ComposerSendOperation? = enablesComposerSubmission
            ? hostedSend
            : nil
        let uploads = HostedUploadReceipt()
        let model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot),
            composerUpload: { _, _, data in try await uploads.upload(data) },
            composerSend: composerSend,
            composerDraftStore: ComposerDraftStore(root: cacheRoot.appending(path: "drafts")),
            chatMediaFetch: mediaFetch
        )
        return Dependencies(
            suiteName: suiteName,
            defaults: defaults,
            cacheRoot: cacheRoot,
            client: client,
            model: model,
            socket: socket,
            profile: profile,
            uploads: uploads
        )
    }

    private init(
        snapshot: SessionSnapshot,
        displayFrameScheduler: DisplayFrameScheduler,
        performanceSignposts: (any PerformanceSignposting)?,
        dependencies: Dependencies,
        installsSubscribedSnapshot: Bool,
        enablesPresentationCover: Bool = false,
        usesRealOpening: Bool = false,
        scrollCallbackMode: ChatHostedScrollCallbackMode = .synthetic,
        orientation: ChatTranscriptOrientation = .newestAtOrigin,
        reduceMotionEnabled: Bool = false
    ) throws {
        self.snapshot = snapshot
        self.orientation = orientation
        transcriptIDs = Set(snapshot.transcript.map(\.id)).union(["transcript-bottom"])
        firstTranscriptID = snapshot.transcript.first?.id ?? "transcript-bottom"
        lastTranscriptID = snapshot.transcript.last?.id ?? "transcript-bottom"
        let signposts = RecordingPerformanceSignposts()
        self.signposts = signposts
        suiteName = dependencies.suiteName
        defaults = dependencies.defaults
        cacheRoot = dependencies.cacheRoot
        client = dependencies.client
        model = dependencies.model
        socket = dependencies.socket
        uploads = dependencies.uploads
        guard model.authoritativeSnapshot(for: snapshot.sessionId) == nil else {
            throw HarnessError.invalidAuthorityBoundary
        }
        // Hosted presentation generations are authoritative and need not match
        // ChatOpenPresentationState's local opening epoch.
        model.invalidateHostedPendingPresentation()
        if usesRealOpening {
            // No hosted authority: ChatView must call AppModel/session.open.
        } else if installsSubscribedSnapshot {
            model.installHostedSubscribedSnapshot(snapshot, token: "hosted-session-token")
        } else {
            model.installHostedAuthoritativeSnapshot(snapshot)
        }
        guard usesRealOpening || model.authoritativeSnapshot(for: snapshot.sessionId) == snapshot else {
            throw HarnessError.invalidAuthorityBoundary
        }

        let probe = ChatHostedProbe(scrollCallbackMode: scrollCallbackMode)
        if !usesRealOpening {
            probe.fixtureOpenPresentation = { [model] in
                guard let target = model.presentationTarget(for: snapshot.sessionId),
                      model.hasMountedSessionAuthority(target) else { throw CancellationError() }
                return target.generation
            }
        }
        self.probe = probe
        let sessionID = snapshot.sessionId
        let root = AnyView(
            NavigationStack {
                ChatView(
                    sessionID: sessionID,
                    hostedProbe: probe,
                    displayFrameScheduler: displayFrameScheduler,
                    performanceSignposts: performanceSignposts ?? signposts,
                    transcriptOrientation: orientation
                )
            }
            .environment(model)
            .environment(\.hostedToolActionProbe, toolActionProbe)
            .environment(\._accessibilityReduceMotion, reduceMotionEnabled)
        )
        hostingController = UIHostingController(rootView: enablesPresentationCover
            ? AnyView(HarnessManagedSurface(content: root, cover: cover))
            : AnyView(root.environment(\.scenePhase, .active)))
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw HarnessError.missingWindowScene
        }
        window = UIWindow(windowScene: windowScene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()

        let hostedView = hostingController.view!
        recorder = PresentedFrameRecorder(
            probe: probe,
            orientation: orientation,
            windowState: { TranscriptWindowOracle.state(in: hostedView) }
        )
        recorder.start()
    }

    /// A method in `unansweredMethods` is received and never answered, like a
    /// stalled Gateway request.
    private func startRPCResponder(unansweredMethods: Set<String>) async {
        guard let socket else { return }
        rpcTask = Task { @MainActor [weak self] in
            var index = 1 // connection hello is the sole non-RPC frame
            do {
                while !Task.isCancelled {
                    try await socket.waitUntilSent(count: index + 1)
                    let request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
                    index += 1
                    guard let self,
                          let method = request.objectValue?["method"]?.stringValue,
                          let id = request.objectValue?["id"]?.stringValue else { continue }
                    rpcMethods.append(method)
                    if unansweredMethods.contains(method) { continue }
                    let result: JSONValue
                    switch method {
                    case "session.open":
                        result = .object([
                            "session": try JSONValue.encode(snapshot),
                            "syncToken": .string("fixture-sync-\(index)"),
                            "subscriptionToken": .string("fixture-subscription-\(index)"),
                            "completionRevision": .number(0),
                        ])
                    case "session.sync": result = .object(["synchronized": .bool(true)])
                    case "session.close": result = .object(["closed": .bool(true)])
                    case "session.commands": result = .object(["commands": .array([])])
                    case "session.attention.read":
                        result = .object(["completionRevision": .number(0), "attentionRevision": .number(0), "isUnread": .bool(false)])
                    default:
                        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                            "type": .string("response"), "id": .string(id), "ok": .bool(false),
                            "error": .object(["code": .string("fixture_unsupported"), "message": .string(method), "retryable": .bool(false)])
                        ])))
                        continue
                    }
                    await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                        "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result
                    ])))
                }
            } catch is CancellationError {} catch { Issue.record("Fake Gateway responder: \(error)") }
        }
    }


    var currentTarget: SessionPresentationIdentity? { model.mountedPresentationTarget }
    var currentSubmission: ComposerSubmissionSnapshot? {
        currentTarget.flatMap { model.composerDrafts.outgoingSubmission(for: $0) }
    }
    var currentAttachments: [PendingAttachment] {
        currentTarget.map { model.composerDrafts.pendingAttachments(for: $0) } ?? []
    }

    /// The mounted chat's media owner, so a hosted test can read what it
    /// retained for an exact artifact identity.
    var chatMedia: ChatMediaLoader { model.chatMedia }

    /// The exact media identity the mounted chat resolves for one artifact.
    func chatMediaIdentity(blobID: String) -> ChatMediaIdentity? {
        model.chatMediaIdentity(blobID: blobID, sessionID: snapshot.sessionId)
    }


    func setCovered(_ value: Bool) { cover.presented = value }

    var chatSurfaceActivity: PresentationSurfaceActivity { cover.coordinator.activity(for: cover.rootToken) }
    var coverTransitionSettled: Bool {
        guard let presented = hostingController.presentedViewController else { return false }
        return !presented.isBeingPresented && presented.transitionCoordinator == nil
    }
    var uncoverTransitionSettled: Bool { hostingController.presentedViewController == nil }

    /// Whether the hosted chat has a sheet presented. A transcript row's detail
    /// sheet is presented above the rows, so it must outlive the row that asked
    /// for it.
    var presentsManagedSheet: Bool { hostingController.presentedViewController != nil }
    func waitForCoverTransition(presented: Bool) async throws {
        for _ in 0..<180 {
            if presented ? coverTransitionSettled : uncoverTransitionSettled { return }
            try await DisplayFrameScheduler.displayLink.nextFrame()
        }
        throw HarnessError.coverTransitionDidNotSettle
    }

    var probeObservation: ChatHostedObservation { probe.observation }

    var openingOverlayMotionMarker: ChatOpeningOverlayMotionMarker? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(hostingController.view).compactMap { $0 as? ChatOpeningOverlayMotionMarker }.first
    }

    var openingOverlayMotionFrame: CGRect {
        guard let marker = openingOverlayMotionMarker else { return window.bounds }
        let layer = marker.layer.presentation() ?? marker.layer
        return layer.convert(layer.bounds, to: window.layer).standardized
    }

    var openingOverlayMotionOpacity: CGFloat {
        guard let marker = openingOverlayMotionMarker else { return 0 }
        var opacity: CGFloat = 1
        var layer: CALayer? = marker.layer.presentation() ?? marker.layer
        while let current = layer {
            opacity *= CGFloat(current.opacity)
            layer = current.superlayer
        }
        return opacity
    }

    func driveOpeningOverlay(failed: Bool) {
        probe.openingOverlayControl?(failed)
    }

    var composerProcessOrbMotionMarker: ChatComposerProcessOrbMotionMarker? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(hostingController.view).compactMap { $0 as? ChatComposerProcessOrbMotionMarker }.first
    }

    var composerProcessOrbMotionFrame: CGRect? {
        guard let marker = composerProcessOrbMotionMarker else { return nil }
        let layer = marker.layer.presentation() ?? marker.layer
        return layer.convert(layer.bounds, to: window.layer).standardized
    }

    func deliverProcessActivity(_ activity: SessionProcessActivity) async throws {
        guard let socket else { throw HarnessError.missingSocket }
        let current = model.selectedSnapshot ?? snapshot
        let revision = (current.processOverview?.revision ?? 0) + 1
        let asOf = activity.lifecycle.observedAt
        let active = activity.visibility == .active
        let recent = activity.visibility == .recent
        let overview = SessionProcessOverview(
            revision: revision,
            asOf: asOf,
            activeCount: active ? 1 : 0,
            recentCount: recent ? 1 : 0,
            problemCount: 0,
            visibility: active ? .active : (recent ? .recent : .hidden),
            nearestExpiry: recent ? activity.lifecycle.recentUntil : nil
        )
        let delta = SessionProcessDelta(
            activity: activity,
            removedProcessIds: [],
            processRevision: revision,
            processAsOf: asOf,
            overview: overview
        )
        let data = try JSONDecoder.gateway.decode(JSONValue.self, from: JSONEncoder.gateway.encode(delta))
        let event = JSONValue.object([
            "type": .string("event"),
            "topic": .string("session.processActivity"),
            "sessionId": .string(snapshot.sessionId),
            "payload": .object([
                "runtimeGeneration": .string(current.runtimeGeneration),
                "eventSequence": .number(Double(current.eventSequence + 1)),
                "revision": .number(Double(current.revision + 1)),
                "data": data,
            ]),
        ])
        await socket.enqueue(try JSONEncoder.gateway.encode(event))
    }

    var composerTrailingMotionMarker: ChatComposerTrailingMotionMarker? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        return descendants(hostingController.view).compactMap { $0 as? ChatComposerTrailingMotionMarker }.first
    }

    var composerTrailingMotionFrame: CGRect? {
        guard let marker = composerTrailingMotionMarker else { return nil }
        let layer = marker.layer.presentation() ?? marker.layer
        return layer.convert(layer.bounds, to: window.layer).standardized
    }

    var composerMotionFrame: CGRect? {
        TranscriptWindowOracle.composerFrame(in: hostingController.view)
    }

    func pendingAttachmentMotionFrame(id: String) -> CGRect? {
        guard let window = hostingController.view.window,
              let marker = Self.pendingAttachmentMarkers(in: hostingController.view).first(where: {
                  $0.attachmentID == id
              }) else { return nil }
        let layer = marker.layer.presentation() ?? marker.layer
        return layer.convert(layer.bounds, to: window.layer).standardized
    }

    var catchUpMotionMarker: ChatCatchUpMotionMarker? {
        Self.catchUpMotionMarkers(in: hostingController.view).first
    }

    var catchUpMotionFrame: CGRect? {
        guard let window = hostingController.view.window,
              let marker = catchUpMotionMarker else { return nil }
        let layer = marker.layer.presentation() ?? marker.layer
        return layer.convert(layer.bounds, to: window.layer).standardized
    }

    func beginReaderDetachmentForMotion() async throws {
        try scrollReader(byVisualPoints: 10_000_000)
        try await driveFrameBoundary()
        drivePhase(from: .idle, to: .interacting, geometry: nil)
        drivePhase(from: .interacting, to: .idle, geometry: nil)
    }

    /// `chat.tail.first-displacement` diagnostics seen so far. The incident's
    /// trace ring held 99 of them and evicted the geometry records they shared
    /// the ring with, so the CT-2 fixtures count them explicitly.
    var tailDisplacementRecordCount: Int {
        traceRecords.count { "\($0.record.event)".contains("first-displacement") }
    }

    var traceRecords: [GatewayProfileLogRecord] { model.chatInteractionTrace.diagnosticRecords(limit: 256) }
    var screenScale: CGFloat { window.screen.scale }

    var canonicalCommandNames: [String] { model.commands.map(\.name) }

    func loadCanonicalCommands(
        _ names: [String], skills: [String] = [], prompts: [String] = [],
        beforeResponse: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        let socket = try #require(socket)
        let priorFrames = await socket.sentFrames().count
        let loading = Task { await model.loadCommands(sessionID: snapshot.sessionId) }
        do {
            // Presentation registration can race catalog loading; respond to
            // this request's method rather than whichever RPC arrived first.
            var index = priorFrames
            var request: JSONValue
            repeat {
                try await socket.waitUntilSent(count: index + 1)
                request = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
                index += 1
            } while request.objectValue?["method"]?.stringValue != "session.commands"
            let id = try #require(request.objectValue?["id"]?.stringValue)
            try await beforeResponse?()
            let commands = names.map {
                CommandInfo(name: $0, description: nil, argumentHint: nil, source: .extension, sourcePath: nil)
            } + skills.map {
                CommandInfo(name: $0, description: nil, argumentHint: nil, source: .skill, sourcePath: nil)
            } + prompts.map {
                CommandInfo(name: $0, description: nil, argumentHint: nil, source: .prompt, sourcePath: nil)
            }
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(id), "ok": .bool(true),
                "result": .object(["commands": try JSONValue.encode(commands)]),
            ])))
            await loading.value
            #expect(model.commandCatalogTarget == model.mountedPresentationTarget)
        } catch {
            loading.cancel()
            await loading.value
            throw error
        }
    }

    func replaceAuthoritativeSnapshot(_ snapshot: SessionSnapshot) {
        model.replaceHostedAuthoritativeSnapshot(snapshot)
    }

    func canonicalTranscriptContains(_ id: String) -> Bool {
        model.selectedSnapshot?.transcript.contains { $0.id == id } == true
    }

    func driveGeometry(
        previous: ChatTranscriptGeometry,
        current: ChatTranscriptGeometry,
        viewport: Bool = false
    ) {
        probe.driveGeometry(previous: previous, current: current, viewport: viewport)
    }

    func drivePhase(from: ScrollPhase, to: ScrollPhase, geometry: ChatTranscriptGeometry?) {
        probe.drivePhase(from: from, to: to, geometry: geometry)
    }

    func driveNativeOwnership(_ owned: Bool) {
        probe.driveNativeOwnership(owned)
    }

    func driveSemanticResponse() {
        probe.driveSemanticResponse()
    }

    func driveCatchUp(reduceMotion: Bool) {
        probe.driveCatchUp(reduceMotion: reduceMotion)
    }

    func submitPrompt() { probe.submitPrompt() }

    func drivePrepend() -> Bool { probe.drivePrepend() }

    func releasePrependPage() { probe.releasePrependPage() }

    func driveFrameBoundary() async throws {
        try await probe.driveFrameBoundary()
    }

    var firstReadyEvents: [RecordingPerformanceSignposts.Event] {
        signposts.events().filter { $0.operation == .firstReadyFrame }
    }

    /// The transcript's bottom, measured in window coordinates: the composer's
    /// top edge, the pinned bottom band, the newest mounted row's bottom edge
    /// and the fraction of the visible transcript the rows cover.
    func transcriptBottom() -> TranscriptWindowOracle.Bottom {
        TranscriptWindowOracle.bottom(in: hostingController.view)
    }

    /// The view the window oracle walks: the hosted chat's own view.
    var visibleRootView: UIView { hostingController.view }

    /// Whether the newest mounted row's bottom edge sits in the pinned bottom
    /// band. The one spelling of "the transcript is pinned to its visual
    /// bottom", and the replacement for every scroll-space tail error: window
    /// coordinates measure the rendered rows rather than lazy content estimates.
    func isPinnedToBottom() -> Bool { transcriptBottom().isPinned }

    /// The visual gap between the newest mounted row's bottom edge and the
    /// composer's top edge. The eager marker owns its 12 pt band; the measured
    /// row-to-composer clearance is fixture-specific and pinned by opening tests.
    /// `nil` when no composer or no mounted row is there to measure.
    func newestRowClearance() -> CGFloat? { transcriptBottom().clearance }

    /// Place the real reader `points` visual points from the newest end: `0` is
    /// the pinned bottom, larger values move toward older history, and the value
    /// is clamped to the transcript's legal scroll range. The distance is a
    /// visual distance from the origin-anchored transcript's newest end.
    func scrollReader(byVisualPoints points: CGFloat) throws {
        let scrollView = try nativeTranscriptScrollView()
        let inset = scrollView.adjustedContentInset
        let maximumOffset = max(
            -inset.top,
            scrollView.contentSize.height - scrollView.bounds.height + inset.bottom
        )
        // The origin transcript is flipped: its newest end is the native content
        // origin, and a larger visual distance moves the reader toward older
        // history (down the content, up the screen).
        let newestEnd = -inset.top
        let proposed = newestEnd + points
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: min(maximumOffset, max(-inset.top, proposed))),
            animated: false
        )
        scrollView.layoutIfNeeded()
    }

    /// The scroll view's own offset at the transcript's newest end: the flipped
    /// origin transcript's content origin (see `scrollReader(byVisualPoints:)`,
    /// which places the reader from it).
    func nativeNewestEndOffset() throws -> CGFloat {
        let scrollView = try nativeTranscriptScrollView()
        return -scrollView.adjustedContentInset.top
    }

    /// Move the real transcript scroll view to its oldest loaded content, then
    /// deliver the native drag phases that make that viewport movement direct
    /// user intent. Programmatic content-offset changes alone are not a reader
    /// taking over. The geometry and visible row frames remain those produced by
    /// the mounted scroll view.
    func detachReaderByRealScroll(boundaries: Int = 60) async throws {
        try scrollReader(byVisualPoints: 10_000_000)
        try await driveFrameBoundary()
        drivePhase(from: .idle, to: .interacting, geometry: nil)
        drivePhase(from: .interacting, to: .idle, geometry: nil)
        for _ in 0..<boundaries {
            if probeObservation.isDetached, readerAnchor() != nil { return }
            try await driveFrameBoundary()
        }
    }

    /// Detach the reader part-way up the loaded history, the way a reader who
    /// scrolls up and stops does: move the real transcript scroll view `viewports`
    /// viewports above the pinned tail and report the pan's own phase callbacks,
    /// which is the coordinator path that reads a viewport in motion as direct
    /// ownership. `detachReaderByRealScroll` exercises the status-bar path, which
    /// lands at the oldest loaded row (its heuristic needs a visual top inside 2
    /// pt of the window's) and leaves the reader at the content's far edge, where
    /// nothing above it can move it. A mid-history reader is the position the
    /// streaming, keyboard and page-load phases have to hold.
    func detachReaderMidHistory(
        byViewports viewports: CGFloat = 1.5,
        boundaries: Int = 60
    ) async throws {
        let scrollView = try nativeTranscriptScrollView()
        try scrollReader(byVisualPoints: viewports * scrollView.bounds.height)
        // One boundary so the coordinator's own geometry is the real mid-history
        // viewport before the phase callbacks arrive: a pinned position left in
        // its evidence would read the retreat as a bottom rubber band.
        try await driveFrameBoundary()
        drivePhase(from: .idle, to: .interacting, geometry: nil)
        drivePhase(from: .interacting, to: .idle, geometry: nil)
        for _ in 0..<boundaries {
            if probeObservation.isDetached, readerAnchor() != nil { return }
            try await driveFrameBoundary()
        }
    }

    /// Return the reader to the newest row the way a finger does: move the real
    /// transcript scroll view back to the tail, then deliver the pan's own
    /// interacting→idle phase callbacks. The idle phase at the tail is the
    /// coordinator's manual re-pin path (`scrollPhaseChanged` → `pinAtTail`), the
    /// same phase synthesis `detachReaderByRealScroll` uses to take ownership.
    func returnReaderToPinnedTail(boundaries: Int = 60) async throws {
        try scrollReader(byVisualPoints: 0)
        try await driveFrameBoundary()
        drivePhase(from: .idle, to: .interacting, geometry: nil)
        drivePhase(from: .interacting, to: .idle, geometry: nil)
        for _ in 0..<boundaries {
            if !probeObservation.isDetached && isPinnedToBottom() { return }
            try await driveFrameBoundary()
        }
    }

    /// Drive display-frame boundaries until the newest row's rendered bottom
    /// sits in the pinned band, or the bound is reached. A smooth catch-up or a
    /// keyboard inset change animates the native offset over several frames, so
    /// the window-coordinate pinned check only holds once it settles.
    func settleUntilPinned(boundaries: Int = 60) async throws {
        for _ in 0..<boundaries where !isPinnedToBottom() {
            try await driveFrameBoundary()
        }
    }

    /// Return the reader to the pinned tail by pressing the product's own
    /// catch-up affordance: the default (non-Reduce-Motion) staged `.offsetY`
    /// reveal and origin reflection on the way to the final `.tail`, then the
    /// settled pinned mode. This is the catch-up path, distinct from the manual
    /// phase-driven return above.
    func returnReaderToPinnedTailByCatchUp(boundaries: Int = 60) async throws {
        let baseline = probeObservation.scrollCommandCount
        driveCatchUp(reduceMotion: false)
        for _ in 0..<boundaries {
            if !probeObservation.isDetached { return }
            if probeObservation.scrollCommandCount > baseline, isPinnedToBottom() { return }
            try await driveFrameBoundary()
        }
    }

    /// The row the reader is reading: the topmost mounted row that intersects the
    /// transcript's visible region, in window coordinates. A detached reader's
    /// anchor is this row's window position, so the same measurement holds
    /// whichever way the transcript's scroll view is oriented.
    struct ReaderAnchor: Equatable {
        let physicalID: String
        let instance: UUID
        let windowMinY: CGFloat
    }

    func readerAnchor() -> ReaderAnchor? {
        TranscriptWindowOracle.rows(in: hostingController.view)
            .filter(\.isOnScreen)
            .min { $0.windowFrame.minY < $1.windowFrame.minY }
            .map { ReaderAnchor(
                physicalID: $0.physicalID, instance: $0.instance, windowMinY: $0.windowFrame.minY
            ) }
    }

    func isNativeTranscriptInteractionEnabled() throws -> Bool {
        let scrollView = try nativeTranscriptScrollView()
        return scrollView.isScrollEnabled && scrollView.isUserInteractionEnabled
            && scrollView.panGestureRecognizer.isEnabled
    }

    private func nativeTranscriptScrollView() throws -> UIScrollView {
        guard let value = Self.nativeTranscriptScrollView(in: hostingController.view) else {
            throw HarnessError.missingTranscript
        }
        return value
    }

    /// The real transcript scroll view, for a test that drives or inspects the
    /// native container directly.
    func nativeTranscriptScrollViewForTesting() throws -> UIScrollView {
        try nativeTranscriptScrollView()
    }

    /// The prompt rows' production context-menu surfaces: the native views that
    /// carry the interaction, with the owner that builds their preview. The
    /// prompt and display-card menus share this source-owned UIKit interaction.
    func promptContextMenuSurfaces() -> [(view: UIView, interaction: UIContextMenuInteraction, owner: ChatMessageContextMenuOwner)] {
        Self.contextMenuViews(in: hostingController.view).compactMap { view in
            guard let interaction = view.interactions.compactMap({ $0 as? UIContextMenuInteraction }).first,
                  let owner = interaction.delegate as? ChatMessageContextMenuOwner else { return nil }
            return (view, interaction, owner)
        }
    }

    /// The row the reader sees at the top of the transcript, or `nil` when no
    /// mounted row is on screen.
    func visuallyTopmostOnScreenRow() -> TranscriptWindowOracle.Row? {
        TranscriptWindowOracle.rows(in: visibleRootView)
            .filter(\.isOnScreen)
            .min { $0.windowFrame.minY < $1.windowFrame.minY }
    }

    private static func contextMenuViews(in view: UIView) -> [UIView] {
        let found = view.interactions.contains { $0 is UIContextMenuInteraction } ? [view] : []
        return found + view.subviews.flatMap(contextMenuViews)
    }

    /// The parity gate's rendered frame: the mean luminance per row and per
    /// column band of the transcript region, plus the PNG a recording run
    /// retains as its per-frame artifact.
    ///
    /// This capture is the gate's frame clock. The gate samples one frame per
    /// driven display boundary, so a capture that costs more than a display
    /// period makes the app skip the frames in between: a full-window capture at
    /// 1x was measured at about 110 ms (about 45 ms rendering, 45 ms flattening
    /// the pixels to luminance, 20 ms building the profiles), so a 280 ms
    /// entrance landed on two or three samples and most of its frames were never
    /// compared. Rendering the transcript below the navigation bar at half scale,
    /// and accumulating both profiles in one pass over the image's bytes, costs
    /// about a third of that, so the entrance's own frames are sampled. The
    /// artifact encoding is part of the capture in every mode, so a recording run
    /// and a verifying run sample the same instants; only writing it differs.
    ///
    /// The screen update is forced. A sample that reads the last committed state
    /// without forcing one shows the same picture for tens of boundaries while an
    /// entrance runs: the app commits its layer tree only a few times per
    /// transition, so a stale sample cannot carry the animation at all (measured
    /// on the recorded send scenario, whose captured frames were identical for
    /// runs of 20 to 37 boundaries). Forcing the update makes the frame carry the
    /// animation state the display is showing at that instant, which is what the
    /// gate compares.
    ///
    /// The region is the transcript: below the navigation bar (whose glass
    /// material re-renders with pixel noise unrelated to it, as the reveal oracle
    /// already assumes) and above the composer (whose own material and spring
    /// dominated the run-to-run difference of a frame that included it, at up to
    /// 0.06 against 0.015 for the transcript alone).
    func renderedParityFrame(
        scale: CGFloat,
        rowBandPixels: Int,
        columnBandPixels: Int,
        includingPNG: Bool
    ) -> ParityFrame {
        let view = hostingController.view!
        let top = min(Self.parityTopInset, view.bounds.height)
        let bottom = min(top + Self.parityBottomInset, view.bounds.height)
        let region = CGRect(
            x: 0,
            y: top,
            width: view.bounds.width,
            height: max(0, view.bounds.height - bottom)
        )
        let image = renderedImage(in: region, scale: scale, afterScreenUpdates: true)
        let empty = ParityFrame(width: 0, height: 0, rows: [], columns: [], png: nil)
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return empty }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let rowBands = max(1, (height + rowBandPixels - 1) / rowBandPixels)
        let columnBands = max(1, (width + columnBandPixels - 1) / columnBandPixels)
        var rowSums = [Int](repeating: 0, count: rowBands)
        var columnSums = [Int](repeating: 0, count: columnBands)
        for y in 0..<height {
            let line = y * cgImage.bytesPerRow
            let rowBand = y / rowBandPixels
            for x in 0..<width {
                let offset = line + x * bytesPerPixel
                let value = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                rowSums[rowBand] += value
                columnSums[x / columnBandPixels] += value
            }
        }
        func bands(_ sums: [Int], total: Int, step: Int, divisor: Int) -> [UInt8] {
            sums.enumerated().map { index, sum in
                let length = min(step, total - index * step)
                return UInt8(sum / (3 * length * divisor))
            }
        }
        return ParityFrame(
            width: width,
            height: height,
            rows: bands(rowSums, total: height, step: rowBandPixels, divisor: width),
            columns: bands(columnSums, total: width, step: columnBandPixels, divisor: height),
            png: includingPNG ? image.pngData() : nil
        )
    }

    struct ParityFrame {
        let width: Int
        let height: Int
        let rows: [UInt8]
        let columns: [UInt8]
        let png: Data?
    }

    /// The parity gate's rendered region: the transcript, below the navigation
    /// bar (whose glass material re-renders with pixel noise) and above the
    /// composer (whose own material and spring are not the transcript, and whose
    /// animated height was measured as the largest source of run-to-run
    /// difference in a frame). Both insets are fixed so a frame's region has the
    /// same shape whatever the composer is doing.
    private static let parityTopInset: CGFloat = 100
    private static let parityBottomInset: CGFloat = 200

    /// A region of the hosted window rendered from the current hierarchy,
    /// including any in-flight presentation values an entrance or size change is
    /// showing. `drawHierarchy` renders at the view's coordinates, so the context
    /// is translated by the region's origin.
    private func renderedImage(in region: CGRect, scale: CGFloat, afterScreenUpdates: Bool) -> UIImage {
        let view = hostingController.view!
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(
            bounds: CGRect(origin: .zero, size: region.size),
            format: format
        ).image { context in
            context.cgContext.translateBy(x: -region.minX, y: -region.minY)
            view.drawHierarchy(in: region, afterScreenUpdates: afterScreenUpdates)
        }
    }

    /// The hosted window rendered from the current hierarchy, including any
    /// in-flight presentation values an entrance or size change is showing.
    private func renderedWindowImage(scale: CGFloat = 1, afterScreenUpdates: Bool = true) -> UIImage {
        renderedImage(
            in: hostingController.view.bounds,
            scale: scale,
            afterScreenUpdates: afterScreenUpdates
        )
    }

    /// One origin-layout geometry sample for the scale and lazy-history regressions.
    func ct2BoundarySample(tallSemanticID: String) throws -> CT2BoundarySample {
        let scrollView = try nativeTranscriptScrollView()
        let rows = TranscriptWindowOracle.rows(in: hostingController.view)
        let bottom = transcriptBottom()
        return CT2BoundarySample(
            contentHeight: scrollView.contentSize.height,
            offsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom,
            visibleRowCount: rows.count { $0.isOnScreen },
            tallRowFrame: rows.first { $0.semanticID == tallSemanticID }?.windowFrame,
            coverage: TranscriptBottomCoverage(
                blank: rows.count { $0.isOnScreen } == 0,
                uncoveredBand: !bottom.isBandCovered,
                visibleRowFraction: bottom.visibleRowFraction,
                newestRowClearance: newestRowClearance()
            )
        )
    }

    fileprivate func keyboardBoundarySample() throws -> KeyboardBoundarySample {
        let bottom = transcriptBottom()
        let rows = TranscriptWindowOracle.rows(in: hostingController.view)
        let composer = TranscriptWindowOracle.composerFrame(in: hostingController.view)
        return KeyboardBoundarySample(
            clearance: bottom.clearance,
            composerTop: composer?.minY ?? bottom.composerTop,
            composerHeight: composer?.height ?? 0,
            coverage: TranscriptBottomCoverage(
                blank: !rows.contains { $0.isOnScreen },
                uncoveredBand: !bottom.isBandCovered,
                visibleRowFraction: bottom.visibleRowFraction,
                newestRowClearance: bottom.clearance
            ),
            distanceFromNewest: probeObservation.geometry.distanceFromBottom,
            tailState: traceRecords.first { $0.record.message.contains("tail=") }?.record.message
        )
    }


    /// Resize the hosted window, for a journey that changes the available height.
    func resize(height: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        hostingController.view.frame = window.bounds
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    /// The keyboard transition's own beginning: one end-frame notification, as
    /// UIKit posts one when a keyboard starts moving.
    func beginKeyboardInset(_ transition: KeyboardInsetTransition) {
        postKeyboardFrame(transition)
    }

    /// One step of a keyboard inset transition: the bottom safe area at `step` of
    /// `transition.boundaries`, on the curve's own values. A caller that captures
    /// between steps gets the keyboard's intermediate frames.
    func applyKeyboardInset(_ transition: KeyboardInsetTransition, step: Int) {
        let progress = Double(step) / Double(max(1, transition.boundaries))
        applyKeyboardInset(
            transition.height * Self.keyboardProgress(progress, curve: transition.curve)
        )
    }

    /// Drive the keyboard's inset transition: the notification UIKit posts, then
    /// the bottom safe area through the curve's own values, one driven display
    /// boundary per step. A journey samples the keyboard's intermediate frames
    /// deterministically; the returned samples are the gap between the composer's
    /// top edge and the newest row's bottom edge at each of those boundaries, in
    /// window coordinates.
    @discardableResult
    func driveKeyboardInset(
        _ transition: KeyboardInsetTransition,
        onBoundary: (@MainActor () throws -> Void)? = nil
    ) async throws -> [KeyboardBoundarySample] {
        beginKeyboardInset(transition)
        var samples: [KeyboardBoundarySample] = []
        for step in 1...max(1, transition.boundaries) {
            applyKeyboardInset(transition, step: step)
            try await driveFrameBoundary()
            samples.append(try keyboardBoundarySample())
            try onBoundary?()
        }
        return samples
    }

    /// The bottom safe area a keyboard owns, applied without a notification:
    /// for a journey that needs the inset at a stated height while it drives the
    /// chat itself.
    func applyKeyboardInset(_ height: CGFloat) {
        hostingController.additionalSafeAreaInsets = UIEdgeInsets(
            top: 0, left: 0, bottom: height, right: 0
        )
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    /// The keyboard's own end-frame notification, in the form UIKit delivers it:
    /// `ChatKeyboardObserver` reads the same three user-info keys, so the layout
    /// transaction takes the keyboard it takes on a device.
    private func postKeyboardFrame(_ transition: KeyboardInsetTransition) {
        let endFrame = window.convert(
            CGRect(
                x: 0, y: window.bounds.maxY - transition.height,
                width: window.bounds.width, height: transition.height
            ),
            to: nil
        )
        NotificationCenter.default.post(
            name: transition.height > 0
                ? UIResponder.keyboardWillChangeFrameNotification
                : UIResponder.keyboardWillHideNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: transition.duration),
                UIResponder.keyboardAnimationCurveUserInfoKey: NSNumber(value: transition.curve.rawValue),
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: endFrame),
            ]
        )
    }

    /// Focus the production editor: UIKit posts the notification and owns the
    /// hosting controller's keyboard safe-area animation over real time.
    func setRealKeyboardVisible(_ visible: Bool) throws {
        let editor = try #require(Self.textViews(in: hostingController.view).first)
        if visible { editor.becomeFirstResponder() } else { editor.resignFirstResponder() }
    }

    func topViewportEvidence() throws -> (uncoveredTop: CGFloat, description: String) {
        let scroll = try nativeTranscriptScrollView()
        func navigationBar(in view: UIView) -> UINavigationBar? {
            (view as? UINavigationBar) ?? view.subviews.lazy.compactMap { navigationBar(in: $0) }.first
        }
        let navigation = try #require(navigationBar(in: hostingController.view))
        let nav = navigation.convert(navigation.bounds, to: window).maxY
        let frame = scroll.layer.convert(scroll.bounds, to: window.layer).standardized
        var clip = frame
        var parent = scroll.superview
        var chain: [String] = []
        while let view = parent {
            let rect = view.layer.convert(view.bounds, to: window.layer).standardized
            if view.clipsToBounds { clip = clip.intersection(rect) }
            chain.append("\(type(of: view)):\(rect):clip=\(view.clipsToBounds)")
            parent = view.superview
        }
        let rows = TranscriptWindowOracle.rows(in: hostingController.view)
        let first = rows.filter { $0.windowFrame.maxY > max(nav, clip.minY) }.min { $0.windowFrame.minY < $1.windowFrame.minY }
        return (max(0, max(clip.minY, first?.windowFrame.minY ?? .infinity) - nav), "nav=\(nav) frame=\(frame) clip=\(clip) insets=\(scroll.contentInset) adjusted=\(scroll.adjustedContentInset) safe=\(scroll.safeAreaInsets) first=\(String(describing: first?.windowFrame)) chain=\(chain)")
    }

    enum MotionAccessory { case photo, file, skill, command }

    func setMotionAccessory(_ accessory: MotionAccessory?) throws {
        let target = try #require(model.mountedPresentationTarget)
        let scope = try #require(model.composerDrafts.scope(for: target))
        model.composerDrafts.removeSelectedResource(for: scope)
        model.composerDrafts.removeAttachment("motion-attachment", target: target)
        switch accessory {
        case .photo, .file:
            let photo = accessory == .photo
            model.composerDrafts.installHostedAttachment(PendingAttachment(
                id: "motion-attachment", name: photo ? "Photo" : "Notes.txt",
                mimeType: photo ? "image/jpeg" : "text/plain", size: 1, previewData: nil
            ), target: target)
        case .skill:
            try selectCanonicalSkill(named: "skill:review")
        case .command:
            let command = try #require(model.commands.first { $0.name == "inspect" })
            model.composerDrafts.selectResource(command, for: scope)
        case nil: break
        }
    }

    func obstructionRecorder(trackedID: String? = nil) throws -> AnimatedObstructionRecorder {
        let root = hostingController.view!
        let newest = try #require(TranscriptWindowOracle.rows(in: root).max { $0.windowFrame.maxY < $1.windowFrame.maxY })
        return AnimatedObstructionRecorder(root: root, newestID: trackedID ?? newest.physicalID, probe: probe)
    }

    /// UIKit's keyboard curve evaluated at `progress`. The public
    /// `UIView.AnimationCurve` cases map one-to-one onto `CAMediaTimingFunction`'s
    /// named curves, so the intermediate positions are the curve's own rather
    /// than a substituted approximation of it.
    static func keyboardProgress(_ progress: Double, curve: UIView.AnimationCurve) -> CGFloat {
        let name: CAMediaTimingFunctionName = switch curve {
        case .linear: .linear
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        default: .easeInEaseOut
        }
        let function = CAMediaTimingFunction(name: name)
        var first = [Float](repeating: 0, count: 2)
        var second = [Float](repeating: 0, count: 2)
        function.getControlPoint(at: 1, values: &first)
        function.getControlPoint(at: 2, values: &second)
        let target = CGFloat(progress)
        // The curve's x axis is progress and its y axis is the fraction applied.
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<24 {
            let middle = (lower + upper) / 2
            if cubic(first[0], first[1], second[0], second[1], middle).x < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        let resolved = (lower + upper) / 2
        let sample = cubic(first[0], first[1], second[0], second[1], resolved)
        guard sample.x != 0 else { return 0 }
        return min(1, max(0, sample.y))
    }

    /// A cubic Bézier's point at parameter `t`, for the four control values
    /// `CAMediaTimingFunction` reports.
    private static func cubic(
        _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ t: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        let inverse = 1 - t
        func axis(_ first: Float, _ second: Float) -> CGFloat {
            3 * inverse * inverse * t * CGFloat(first)
                + 3 * inverse * t * t * CGFloat(second)
                + t * t * t
        }
        return (axis(x1, x2), axis(y1, y2))
    }

    struct FloatingLayout {
        let marker: FloatingDisplayHostedMarker
        let frame: CGRect
        let composer: CGRect
        let toolbarBottom: CGFloat
    }

    func floatingLayout() -> FloatingLayout? {
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(hostingController.view)
        guard let marker = views.compactMap({ $0 as? FloatingDisplayHostedMarker }).first,
              let composer = views.compactMap({ $0 as? ChatHostedNativeRowMarker })
                .first(where: { $0.physicalID == ChatHostedNativeRowProbe.composerID }),
              let toolbar = views.compactMap({ $0 as? UINavigationBar }).first else { return nil }
        let presentedMarkerLayer = marker.layer.presentation() ?? marker.layer
        // Compare the visible surfaces on the same clock; mixing a rendered
        // panel with the composer's target layer invents transient overlap.
        let presentedComposerLayer = composer.layer.presentation() ?? composer.layer
        return FloatingLayout(marker: marker,
                              frame: presentedMarkerLayer.convert(presentedMarkerLayer.bounds, to: window.layer).standardized,
                              composer: presentedComposerLayer.convert(presentedComposerLayer.bounds, to: window.layer).standardized,
                              toolbarBottom: toolbar.convert(toolbar.bounds, to: window).maxY)
    }

    func setComposerAccessories(_ enabled: Bool) throws {
        guard let target = model.mountedPresentationTarget,
              let scope = model.composerDrafts.scope(for: target) else { throw HarnessError.missingComposer }
        if enabled {
            model.composerDrafts.selectResource(CommandInfo(name: "skill:layout", description: "Layout fixture",
                argumentHint: nil, source: .skill, sourcePath: "/fixture/skills/layout"), for: scope)
            model.composerDrafts.installHostedAttachment(PendingAttachment(id: "layout-photo", name: "Photo",
                mimeType: "image/jpeg", size: 1, previewData: nil), target: target)
        } else {
            model.composerDrafts.removeSelectedResource(for: scope)
            model.composerDrafts.removeAttachment("layout-photo", target: target)
        }
    }

    func focusComposer(_ focused: Bool) throws {
        guard let textView = Self.textViews(in: hostingController.view).first else { throw HarnessError.missingComposer }
        if focused { textView.becomeFirstResponder() } else { textView.resignFirstResponder() }
    }

    func pasteFromClipboard() throws {
        guard let textView = Self.textViews(in: hostingController.view).first else { throw HarnessError.missingComposer }
        #expect(textView.canPerformAction(#selector(UITextView.paste(_:)), withSender: nil))
        textView.paste(nil)
    }

    func pasteImages(_ providers: [NSItemProvider]) throws {
        guard let textView = Self.textViews(in: hostingController.view).first else { throw HarnessError.missingComposer }
        #expect(textView.canPaste(providers))
        textView.paste(itemProviders: providers)
    }

    func setComposerText(_ text: String) throws {
        guard let textView = Self.textViews(in: hostingController.view).first else {
            throw HarnessError.missingComposer
        }
        textView.text = text
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textView.delegate?.textViewDidChange?(textView)
        textView.delegate?.textViewDidChangeSelection?(textView)
        hostingController.view.setNeedsLayout()
    }

    func selectCanonicalSkill(named name: String) throws {
        let target = try #require(model.mountedPresentationTarget)
        let scope = try #require(model.composerDrafts.scope(for: target))
        let command = try #require(model.commands.first { $0.source == .skill && $0.name == name })
        model.composerDrafts.selectResource(command, for: scope)
    }

    var selectedComposerResource: CommandInfo? {
        guard let target = model.mountedPresentationTarget,
              let scope = model.composerDrafts.scope(for: target) else { return nil }
        return model.composerDrafts.selectedResource(for: scope)
    }

    func composerTextAndSelection() throws -> (text: String, selection: NSRange, identity: ObjectIdentifier) {
        guard let textView = Self.textViews(in: hostingController.view).first else {
            throw HarnessError.missingComposer
        }
        return (textView.text, textView.selectedRange, ObjectIdentifier(textView))
    }

    func setComposerDraftText(_ text: String) throws {
        guard model.setHostedComposerText(text, sessionID: snapshot.sessionId) else {
            throw HarnessError.missingComposer
        }
    }

    func isAttachmentButtonEnabled() throws -> Bool {
        guard let button = Self.buttons(in: hostingController.view).first(where: {
            $0.accessibilityLabel == "Add attachment"
        }) else {
            throw HarnessError.missingComposer
        }
        return button.isEnabled
    }

    func cleanup() {
        retireHostedView()
        retireStorage()
    }

    func close() async {
        uploads.release()
        if hostingController.presentedViewController != nil {
            await withCheckedContinuation { continuation in
                hostingController.dismiss(animated: false) { continuation.resume() }
            }
        }
        retireHostedView()
        await model.teardown()
        rpcTask?.cancel()
        await rpcTask?.value
        await client.close()
        retireStorage()
    }

    private func retireHostedView() {
        probe.retirePresentation()
        recorder.stop()
        window.isHidden = true
        window.rootViewController = nil
    }

    private func retireStorage() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw HarnessError.missingTranscript }
        return value
    }

    private static func nativeTranscriptScrollView(in root: UIView) -> UIScrollView? {
        TranscriptWindowOracle.transcriptScrollView(in: root)
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        let current = (view as? UITextView).map { [$0] } ?? []
        return current + view.subviews.flatMap(textViews)
    }

    private static func pendingAttachmentMarkers(in view: UIView) -> [ChatPendingAttachmentMotionMarker] {
        let current = (view as? ChatPendingAttachmentMotionMarker).map { [$0] } ?? []
        return current + view.subviews.flatMap { pendingAttachmentMarkers(in: $0) }
    }

    private static func catchUpMotionMarkers(in view: UIView) -> [ChatCatchUpMotionMarker] {
        let current = (view as? ChatCatchUpMotionMarker).map { [$0] } ?? []
        return current + view.subviews.flatMap { catchUpMotionMarkers(in: $0) }
    }

    private static func buttons(in view: UIView) -> [UIButton] {
        let current = (view as? UIButton).map { [$0] } ?? []
        return current + view.subviews.flatMap(buttons)
    }
}

/// The transcript's bottom, measured in window coordinates: the one oracle for
/// "is the newest row where the pinned tail puts it?".
///
/// Window coordinates carry what the reader sees, so every quantity here means
/// the same thing whichever way the transcript's scroll view is oriented. That
/// is what CT-23 needs: after the scroll view is flipped and the rows are
/// counter-flipped, a scroll-space tail error measures the distance to the
/// oldest estimated end and calls a blank viewport aligned, while the newest
/// row's window frame is exactly what it was.
///
/// The rects come from the layer chain (`CALayer.convert`), not
/// `UIView.convert`: SwiftUI applies its own transforms (`scaleEffect`,
/// `offset`) on layers, which `UIView.convert` does not walk, so the flip CT-23
/// puts on the scroll view is visible here and invisible there.
enum TranscriptWindowOracle {
    /// The tail spacing a pinned transcript keeps between its newest row and the
    /// composer.
    static let tailSpacing = ChatTranscriptLayoutConstants.tailAffordanceHeight
    /// The band above the composer a pinned transcript keeps covered: the tail
    /// spacing plus 24 pt of the newest row.
    static let bottomBandHeight = tailSpacing + 24
    /// The tolerance the profiling scenarios allow a measured window's pinned
    /// bottom: the window ends while the transcript may still be settling.
    static let profilingTolerance: CGFloat = 24

    /// How far the newest row's rendered bottom edge may sit outside the pinned
    /// band and still count as pinned. The edge is read from the render tree, so
    /// it carries a row's own animated transforms: the queued card's 80 → 44 pt
    /// shrink measured 4.1-13.5 pt excursions below the band, while a detached
    /// reader or a blank is tens or hundreds of points away.
    static let pinnedTolerance: CGFloat = 6

    /// One mounted transcript row, in window coordinates.
    struct Row: Sendable, Equatable {
        let physicalID: String
        let semanticID: String
        let instance: UUID
        /// The row marker's frame in window coordinates.
        let windowFrame: CGRect
        /// Whether the row intersects the transcript's visible region: the
        /// scroll view's on-screen rect, less the composer it insets under.
        let isOnScreen: Bool
        /// Whether the row intersects the pinned bottom band.
        let isInBottomBand: Bool
        /// The visual gap between the row's bottom edge and the composer's top
        /// edge, `nil` without a mounted composer. The pinned tail row sits at
        /// `tailSpacing`; a negative value runs under the composer.
        let composerClearance: CGFloat?

        /// Whether the row's bottom edge sits at the tail spacing above the
        /// composer: the position of a pinned transcript's newest row.
        func isAtTailSpacing(tolerance: CGFloat = 2) -> Bool {
            guard let composerClearance else { return false }
            return abs(composerClearance - TranscriptWindowOracle.tailSpacing) <= tolerance
        }
    }

    /// The transcript's bottom in window coordinates.
    struct Bottom: Sendable, Equatable {
        /// The composer marker's top edge.
        let composerTop: CGFloat?
        /// The pinned bottom band: `bottomBandHeight` points ending at the
        /// composer's top edge.
        let band: CGRect?
        /// The bottom edge and identity of the bottom-most mounted row, which
        /// is the newest row when the origin-anchored viewport is pinned.
        let newestRowBottomEdge: CGFloat?
        let newestRowSemanticID: String?
        /// The fraction of the visible transcript rect that mounted rows cover.
        let visibleRowFraction: CGFloat
        /// Whether any mounted row intersects the bottom band.
        let isBandCovered: Bool
        /// The visual distance of the bottom-most row's bottom edge from the
        /// pinned band, signed: `0` anywhere inside the band, negative when the
        /// row rests above it (a detached reader, or a blank) and positive when
        /// it runs under it below the composer.
        let pinnedError: CGFloat?

        /// The visual gap between the bottom-most row's bottom edge and the
        /// composer's top edge.
        var clearance: CGFloat? {
            guard let composerTop, let newestRowBottomEdge else { return nil }
            return composerTop - newestRowBottomEdge
        }

        /// The marker-owned band is the sole pinned placement; short and tall
        /// terminal rows produce different measured gaps within that band.
        var isPinned: Bool {
            guard let clearance else { return false }
            return clearance >= -pinnedTolerance && clearance <= tailSpacing + pinnedTolerance
        }
    }

    /// Every mounted transcript row and the transcript's bottom, from one walk
    /// of the live hierarchy.
    struct State: Sendable, Equatable {
        let rows: [Row]
        let bottom: Bottom
        /// The transcript scroll view's own content height. Both layouts report
        /// it identically, so a readiness fence can still require the native
        /// view and the coordinator to agree about it.
        let contentHeight: CGFloat?
    }

    static func rows(in root: UIView) -> [Row] { state(in: root).rows }

    static func bottom(in root: UIView) -> Bottom { state(in: root).bottom }

    /// The composer marker's frame in window coordinates: the one structural
    /// inset owner's own frame, which is where the keyboard's safe area lands.
    static func composerFrame(in root: UIView) -> CGRect? {
        guard let window = root.window else { return nil }
        return markers(in: root)
            .first { $0.physicalID == ChatHostedNativeRowProbe.composerID }
            .map { $0.layer.convert($0.bounds, to: window.layer).standardized }
    }

    /// Whether the newest row's bottom edge sits within `tolerance` points of
    /// the pinned band: the decision the profiling scenarios make about a
    /// measured window, which ends while the transcript may still be settling,
    /// so it is wider than `Bottom.isPinned`.
    static func isPinned(in root: UIView, tolerance: CGFloat) -> Bool {
        guard let pinnedError = bottom(in: root).pinnedError else { return false }
        return abs(pinnedError) <= tolerance
    }

    static func state(in root: UIView) -> State {
        guard let window = root.window, let scroll = transcriptScrollView(in: root) else {
            return State(rows: [], bottom: emptyBottom, contentHeight: nil)
        }
        let windowLayer = window.layer
        let composerTop = markers(in: root)
            .first { $0.physicalID == ChatHostedNativeRowProbe.composerID }
            .map { $0.layer.convert($0.bounds, to: windowLayer).standardized.minY }
        var visible = scroll.layer.convert(scroll.bounds, to: windowLayer).standardized
            .intersection(window.bounds)
        // The composer is subtracted from the window rect rather than read from
        // `adjustedContentInset`, which a flipped scroll view would apply at the
        // other edge.
        if let composerTop, composerTop > visible.minY {
            visible = visible.intersection(CGRect(
                x: visible.minX, y: visible.minY,
                width: visible.width, height: composerTop - visible.minY
            ))
        }
        let band = composerTop.map { top in
            CGRect(
                x: visible.minX, y: top - bottomBandHeight,
                width: visible.width, height: bottomBandHeight
            )
        }
        let hasVisibleArea = !visible.isNull && visible.height > 0
        var rows: [Row] = []
        var coveredHeight: CGFloat = 0
        for marker in markers(in: scroll) where marker.window == window && !marker.isHidden {
            let frame = marker.layer.convert(marker.bounds, to: windowLayer).standardized
            guard frame.height > 0 else { continue }
            let isOnScreen = hasVisibleArea && frame.intersects(visible)
            if isOnScreen { coveredHeight += frame.intersection(visible).height }
            rows.append(Row(
                physicalID: marker.physicalID,
                semanticID: marker.semanticID,
                instance: marker.hostIdentity,
                windowFrame: frame,
                isOnScreen: isOnScreen,
                isInBottomBand: band.map { frame.intersects($0) } ?? false,
                composerClearance: composerTop.map { $0 - frame.maxY }
            ))
        }
        let newestRow = rows.max { $0.windowFrame.maxY < $1.windowFrame.maxY }
        let newestRowBottomEdge = newestRow?.windowFrame.maxY
        let clearance = composerTop.flatMap { top in
            newestRowBottomEdge.map { top - $0 }
        }
        let pinnedError = clearance.map(Self.pinnedError(forClearance:))
        let bottom = Bottom(
            composerTop: composerTop,
            band: band,
            newestRowBottomEdge: newestRowBottomEdge,
            newestRowSemanticID: newestRow?.semanticID,
            visibleRowFraction: hasVisibleArea
                ? min(1, max(0, coveredHeight / visible.height)) : 0,
            isBandCovered: rows.contains { $0.isInBottomBand },
            pinnedError: pinnedError
        )
        return State(rows: rows, bottom: bottom, contentHeight: scroll.contentSize.height)
    }

    /// Whether this view renders flipped (CT-23's transcript layout), read from
    /// the render tree: a vertical scale of -1 on the view's own layer or on one
    /// of its ancestors up to the window. The signs multiply along the chain,
    /// because a flip on the scroll view and another on an ancestor renders the
    /// content upright — reading the first negative `m22` alone would call a
    /// doubly flipped container flipped and send every orientation-dependent
    /// branch (`scrollReader`'s newest end, the pinned checks, a context-menu
    /// preview's uprightness) the wrong way.
    static func isFlipped(_ view: UIView) -> Bool {
        var layer: CALayer? = view.layer
        var flipped = false
        while let current = layer {
            if current.transform.m22 < 0 { flipped.toggle() }
            layer = current.superlayer
        }
        return flipped
    }

    /// This fixed-window harness has one full-size transcript viewport. Its
    /// identity cannot depend on overflowing content or a lazy child being
    /// mounted at the instant an entrance or compaction is sampled.
    static func transcriptScrollView(in root: UIView) -> UIScrollView? {
        scrollViews(in: root).filter { !($0 is UITextView) }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        }
    }

    /// The signed distance of a newest-row clearance from the pinned band: `0`
    /// inside it, negative above it, positive below it.
    private static func pinnedError(forClearance clearance: CGFloat) -> CGFloat {
        if clearance > tailSpacing + pinnedTolerance {
            return (tailSpacing + pinnedTolerance) - clearance
        }
        if clearance < -pinnedTolerance { return -pinnedTolerance - clearance }
        return 0
    }

    private static let emptyBottom = Bottom(
        composerTop: nil, band: nil, newestRowBottomEdge: nil,
        newestRowSemanticID: nil,
        visibleRowFraction: 0, isBandCovered: false, pinnedError: nil
    )

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap(scrollViews)
    }

    private static func markers(in view: UIView) -> [ChatHostedNativeRowMarker] {
        (view as? ChatHostedNativeRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }
}

/// Dedicated motion oracle: no revision deduplication, forced layout or driven
/// frames. Presentation layers retain all ancestor transforms, including the
/// transcript flip and UIKit's animated scroll offset.
@MainActor
final class AnimatedObstructionRecorder: NSObject {
    struct Sample: Encodable {
        let time: Double
        let phase: String
        let composerTop: CGFloat?
        let newestBottom: CGFloat?
        let declaredObstruction: CGFloat
        let renderedObstruction: CGFloat?
        let distanceFromNewest: CGFloat
        let trackedTop: CGFloat?
        let trackedInstance: UUID?
        var gap: CGFloat? {
            guard let composerTop, let newestBottom else { return nil }
            return composerTop - newestBottom
        }
    }
    private let root: UIView
    private let newestID: String
    private let probe: ChatHostedProbe
    private var link: CADisplayLink?
    var phase = "settled"
    private(set) var samples: [Sample] = []

    init(root: UIView, newestID: String, probe: ChatHostedProbe) {
        self.root = root
        self.newestID = newestID
        self.probe = probe
    }
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func sample(_ link: CADisplayLink) {
        guard let window = root.window else { return }
        let markers = markers(in: root)
        func frame(_ id: String) -> CGRect? {
            guard let marker = markers.first(where: { $0.physicalID == id }),
                  let layer = marker.layer.presentation(),
                  let windowLayer = window.layer.presentation() else { return nil }
            return layer.convert(layer.bounds, to: windowLayer).standardized
        }
        samples.append(Sample(time: link.timestamp, phase: phase,
                              composerTop: frame(ChatHostedNativeRowProbe.composerID)?.minY,
                              newestBottom: frame(newestID)?.maxY,
                              declaredObstruction: probe.observation.geometry.bottomInset,
                              renderedObstruction: obstruction(in: root)?.layer.presentation()?.bounds.height,
                              distanceFromNewest: probe.observation.geometry.distanceFromBottom,
                              trackedTop: frame(newestID)?.minY,
                              trackedInstance: markers.first { $0.physicalID == newestID }?.hostIdentity))
    }
    private func obstruction(in view: UIView) -> ChatHostedObstructionMarker? {
        (view as? ChatHostedObstructionMarker) ?? view.subviews.lazy.compactMap { self.obstruction(in: $0) }.first
    }
    private func markers(in view: UIView) -> [ChatHostedNativeRowMarker] {
        (view as? ChatHostedNativeRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
    }
}

@MainActor
final class PresentedFrameRecorder: NSObject {
    /// How many samples the recorder retains. It drops the oldest beyond this,
    /// so a journey that reads native frames across a window it no longer holds
    /// checks only part of the transition: `windowIsComplete(since:)` is how
    /// such a journey fails instead of passing quietly.
    static let retainedSampleLimit = 256

    struct Sample: Sendable {
        let frameIndex: Int
        let observation: ChatHostedObservation
        /// The transcript's bottom in window coordinates at this display frame.
        let nativeBottom: TranscriptWindowOracle.Bottom
        let nativeRows: [TranscriptWindowOracle.Row]
        /// The transcript scroll view's own content height at this display frame.
        let nativeContentHeight: CGFloat?

        /// Whether the newest row is visible at the origin-anchored pinned edge.
        var nativePinnedAtOrigin: Bool {
            guard let newestRowID = nativeBottom.newestRowSemanticID else { return false }
            return nativeBottom.isPinned
                && observation.geometry.distanceFromBottom <= ChatTranscriptGeometry.catchUpDistance
                && observation.visibleRowIDs.contains(newestRowID)
                && nativeRows.contains { $0.semanticID == newestRowID && $0.isOnScreen }
        }

        /// Opening is settled at the pinned edge, without comparing estimates of
        /// the lazily materialized far history end.
        var nativeSettledAtOrigin: Bool { nativePinnedAtOrigin }
    }

    private struct Waiter {
        let id: Int
        let predicate: @MainActor (Sample) -> Bool
        let continuation: CheckedContinuation<Sample, Error>
    }

    private let probe: ChatHostedProbe
    private let orientation: ChatTranscriptOrientation
    private let windowState: @MainActor () -> TranscriptWindowOracle.State
    private var lastWindowState: TranscriptWindowOracle.State?
    private var displayLink: CADisplayLink?
    private var frameIndex = 0
    private var lastRevision = -1
    private var waiters: [Waiter] = []
    private var nextWaiterID = 0
    private(set) var samples: [Sample] = []
    /// Samples the recorder's bounded window has dropped.
    private(set) var droppedSampleCount = 0

    init(
        probe: ChatHostedProbe,
        orientation: ChatTranscriptOrientation,
        windowState: @escaping @MainActor () -> TranscriptWindowOracle.State
    ) {
        self.probe = probe
        self.orientation = orientation
        self.windowState = windowState
    }

    /// Whether the retained sample window still holds every sample from
    /// `frameIndex` on. A journey that reads native frames over a range the
    /// recorder has evicted must fail this rather than inspect a partial window.
    func windowIsComplete(since frameIndex: Int) -> Bool {
        guard let oldest = samples.first?.frameIndex else { return false }
        return oldest <= frameIndex
    }

    func start() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayFrame))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }

    func waitUntil(_ predicate: @escaping @MainActor (Sample) -> Bool) async throws -> Sample {
        if let sample = samples.last(where: predicate) { return sample }
        let id = nextWaiterID
        nextWaiterID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id: id) }
        }
    }

    @objc private func displayFrame() {
        frameIndex += 1
        let observation = probe.observation
        let state = windowState()
        guard observation.revision != lastRevision || state != lastWindowState else { return }
        lastRevision = observation.revision
        lastWindowState = state
        let sample = Sample(
            frameIndex: frameIndex,
            observation: observation,
            nativeBottom: state.bottom,
            nativeRows: state.rows,
            nativeContentHeight: state.contentHeight.map {
                $0 - observation.geometry.bottomInset
            }
        )
        samples.append(sample)
        if samples.count > Self.retainedSampleLimit {
            droppedSampleCount += samples.count - Self.retainedSampleLimit
            samples.removeFirst(samples.count - Self.retainedSampleLimit)
        }

        var ready: [Waiter] = []
        var pending: [Waiter] = []
        for waiter in waiters {
            if waiter.predicate(sample) {
                ready.append(waiter)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
        for waiter in ready { waiter.continuation.resume(returning: sample) }
    }

    private func cancelWaiter(id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

enum HarnessError: Error {
    case invalidAuthorityBoundary
    case missingSocket
    case missingTranscript
    case missingWindowScene
    case missingComposer
    case coverTransitionDidNotSettle
}

@MainActor
private final class HostedUploadReceipt {
    private(set) var calls = 0
    private var continuation: CheckedContinuation<String, Error>?
    var hold = false

    func upload(_ data: Data) async throws -> String {
        #expect(!data.isEmpty)
        calls += 1
        if hold {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return "fixture-upload-\(calls)"
    }

    func release() {
        continuation?.resume(returning: "fixture-upload-\(calls)")
        continuation = nil
    }
}

@MainActor
private final class OpeningFrameGate {
    var condition: (() -> Bool)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var consumed = false
    var scheduler: DisplayFrameScheduler {
        DisplayFrameScheduler { [self] in
            if !consumed, condition?() == true {
                consumed = true
                // Intentionally ignore cancellation: prove the production
                // continuation rejects a late frame from its retired owner.
                await withCheckedContinuation { continuation = $0 }
            } else {
                try await DisplayFrameScheduler.displayLink.nextFrame()
            }
        }
    }
    func waitUntilHeld() async throws {
        while continuation == nil { try await DisplayFrameScheduler.displayLink.nextFrame() }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
