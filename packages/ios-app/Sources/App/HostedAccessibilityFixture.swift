#if HOSTED_TEST
import SwiftUI

/// Real production surfaces inspected by the out-of-process accessibility client.
/// Fixture controls change inputs, never duplicate the surfaces' AX descriptions.
struct HostedAccessibilityFixtureView: View {
    @State private var state = HostedAccessibilityFixtureState()
    @State private var destination: Destination?

    private enum Destination: String, Identifiable, CaseIterable {
        case metadata = "Gateway Server Info", maintenance = "Maintenance"
        case json = "Structured JSON", activity = "Session Activity"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("-fixture-dashboard") {
                SessionShellView()
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 2) {
                            ForEach([40, 120, -120, 0], id: \.self) { offset in
                                Button("Scroll \(offset)") { state.scroll(to: offset) }
                            }
                        }.font(.caption2).buttonStyle(.bordered).padding(.bottom, 76)
                    }
            } else {
                NavigationStack {
                    List(Destination.allCases) { item in
                        Button(item.rawValue) { destination = item }
                    }
                    .navigationTitle("Accessibility fixtures")
                }
                .sheet(item: $destination) { item in
                    switch item {
                    case .metadata:
                        GatewayServerInfoSheet(
                            metadata: GatewayConnectionDetailPresentation.metadata(info: Self.info),
                            identities: GatewayConnectionDetailPresentation.technicalDetails(info: Self.info, updateStatus: Self.status),
                            loading: false
                        )
                    case .maintenance:
                        NavigationStack {
                            GatewayMaintenanceActions(
                                lifecycle: ["Rebuild from Source", "Roll Back", "Restart", "Disable"].map { title in
                                    GatewayMaintenanceAction(id: title, title: title) {}
                                },
                                destructive: GatewayMaintenanceAction(id: "forget", title: "Forget Server") {}
                            ).padding(20)
                        }
                    case .json:
                        NavigationStack {
                            ScrollView {
                                TronStructuredJSONView(value: Self.json, title: "Details", accent: .tronEmerald,
                                                       showsRawDisclosure: false).padding(18)
                            }
                        }
                    case .activity:
                        SessionActivitySheet(
                            sessionID: state.snapshot.sessionId,
                            extensionContent: Self.retainedContent,
                            omittedExtensionContentCount: 0,
                            processActivities: state.model.sessionProcessPresentation(for: state.snapshot.sessionId)?.activities ?? []
                        )
                        .overlay(alignment: .bottom) {
                            HStack {
                                Button("Update fixture output") { state.update(completed: false) }
                                Button("Finish fixture output") { state.update(completed: true) }
                            }.font(.caption).buttonStyle(.bordered).padding(6)
                        }
                    }
                }
            }
        }
        .environment(state.model)
        .environment(\.tronPresentationActivityCoordinator, state.presentation)
        .environment(\.scenePhase, .active)
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("-fixture-large-type") ? .accessibility3 : .large)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("-fixture-light") ? .light : .dark)
        .tronPresentation()
    }

    private static let info = GatewayInfo(
        gatewayVersion: "1", piVersion: "2", protocolVersion: 5, minProtocolVersion: 5,
        machineId: "machine", machineName: "Mac", capabilities: ["gateway-update.v1", "restart-supervised.v1"],
        sourceRevision: "source-revision", runtimeEpoch: "runtime-epoch"
    )
    private static let status = GatewayUpdateStatus(
        state: "ready", channel: "stable",
        currentIdentity: GatewayUpdateIdentity(version: "candidate", gatewayVersion: "1", sourceRevision: "fallback-revision",
                                              runtimeEpoch: "fallback-epoch", payloadFingerprint: "payload-identity"),
        candidateIdentity: nil, candidateAvailable: false, error: nil, updatedAt: nil
    )
    private static let json: JSONValue = .object([
        "activeAsyncCapacity": .object(["mode": .string("single"), "max": .number(4)]),
        "mode": .string("single"), "results": .array([]),
    ])
    private static let retainedContent = ExtensionRetainedContentPolicy.content(
        widgets: [ExtensionWidget(key: "goal", revision: 1, lines: ["Checking the selected files"], placement: .belowEditor,
                                 owner: ExtensionOwner(id: "goal", title: "Goal", source: "npm:fixture-goal"))],
        surfaces: [], statuses: ["goal": "Goal active"],
        statusOwners: ["goal": ExtensionOwner(id: "goal", title: "Goal", source: "npm:fixture-goal")]
    )
}

@MainActor @Observable
private final class HostedAccessibilityFixtureState {
    let model: AppModel
    let presentation = PresentationActivityCoordinator()
    var snapshot: SessionSnapshot
    @ObservationIgnored private weak var scrollOwner: UIScrollView?
    @ObservationIgnored private var scrollOrigin = CGPoint.zero

    // SwiftUI content margins are not UIKit adjustedContentInset. Measure the
    // actual native origin once per owner, just as the hosted geometry test does.
    func scroll(to offset: Int) {
        func find(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController?.view,
              let scroll = find(in: root) else { return }
        if scrollOwner !== scroll {
            scrollOwner = scroll
            scrollOrigin = scroll.contentOffset
        }
        // This route samples exact rendered geometry, not command animation.
        // DashboardChromeTests independently drives and verifies animated return
        // outside injected touches and accessibility-client focus adjustments.
        scroll.setContentOffset(CGPoint(x: scrollOrigin.x, y: scrollOrigin.y + CGFloat(offset)), animated: false)
    }

    init() {
        let name = "hosted-accessibility-\(UUID().uuidString)"
        model = AppModel(profiles: GatewayProfileStore(defaults: UserDefaults(suiteName: name)!),
                         cache: SnapshotCache(root: FileManager.default.temporaryDirectory.appending(path: name)))
        snapshot = SessionSnapshot(
            sessionId: "accessibility-fixture", runtimeGeneration: "fixture-runtime", revision: 1, eventSequence: 1,
            phase: .idle, name: "Activity fixture", cwd: "/workspace", parentSessionId: nil, model: nil,
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
        snapshot.processActivities = [Self.process(completed: false, output: "Inspecting the source files.")]
        if !ProcessInfo.processInfo.arguments.contains("-fixture-dashboard") {
            model.installHostedAuthoritativeSnapshot(snapshot)
        }
        AutomationDashboardPreferences.save(AutomationDashboardViewPreferences())
        model.sessions = (0..<30).map { index in
            SessionSummary(id: "session-\(index)", name: "Review project \(index)", cwd: "/workspace/project-\(index / 5)",
                           parentSessionId: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                           messageCount: 1, firstMessage: "Example conversation", phase: .idle, summaryRevision: 1)
        }
    }

    func update(completed: Bool) {
        snapshot.revision += 1
        snapshot.eventSequence += 1
        snapshot.processActivities = [Self.process(completed: completed, output: completed
            ? "All focused checks passed." : "Old output\nFirst check passed.\nSecond check passed.\nLatest check passed.")]
        model.installHostedAuthoritativeSnapshot(snapshot)
    }

    private static func process(completed: Bool, output: String) -> SessionProcessActivity {
        let now = Date.now
        return SessionProcessActivity(
            processId: "live-worker", kind: .subagent, executionMode: .asynchronous, source: .delegatedAgent,
            lifecycle: SessionProcessLifecycle(state: completed ? .completed : .running, sequence: completed ? 2 : 1,
                                               observedAt: now.ISO8601Format(), terminalAt: completed ? now.ISO8601Format() : nil,
                                               recentUntil: completed ? now.addingTimeInterval(300).ISO8601Format() : nil),
            visibility: completed ? .recent : .active, startedAt: now.addingTimeInterval(-42).ISO8601Format(), title: "worker",
            currentTool: completed ? nil : "read", model: "fixture/model", thinking: "high", outputTail: output,
            durationMs: 42_000, toolCount: 12, turnCount: 4, childCount: 1
        )
    }
}
#endif
