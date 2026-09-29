import SwiftUI
import TronMobileCore

// A sheet a transcript row asked to present. The row cannot own it: the
// transcript's own lazy window discards a row while streaming pushes it out of
// realization, and a row-owned sheet is dismissed with the row that presented
// it. The transcript owns the route instead, exactly as the display sheet is
// owned above the rows.

/// One tool run's detail. It carries what identifies the run — its calls and the
/// state the row resolved when the user asked for it — so the host can refresh it
/// from the projection the host itself owns.
struct ChatToolRunSheetRoute: Equatable, Sendable {
    let runID: String
    let toolIDs: [String]
    let state: ToolRunResolvedState
}

/// One wrapped thinking trace's full detail.
struct ChatThinkingTraceSheetRoute: Equatable, Sendable {
    let identity: String
    let inline: MarkdownPresentation.Inline
    let streaming: Bool
}

/// One transcript event's detail, with the identity its diagnostics carry.
struct ChatNotificationDetailSheetRoute: Equatable, Sendable {
    let presentation: ChatNotificationPresentation
    let detailID: UUID
}

enum ChatTranscriptSheetRoute: Equatable, Identifiable {
    case toolRun(ChatToolRunSheetRoute)
    case thinkingTrace(ChatThinkingTraceSheetRoute)
    case notificationDetail(ChatNotificationDetailSheetRoute)

    var id: String {
        switch self {
        case .toolRun(let route): "chat.tool-run.\(route.runID)"
        case .thinkingTrace(let route): "chat.thinking-trace.\(route.identity)"
        case .notificationDetail(let route): "chat.transcript-event-detail.\(route.presentation.id)"
        }
    }

    var toolRun: ChatToolRunSheetRoute? {
        guard case .toolRun(let route) = self else { return nil }
        return route
    }
}

/// The route owner a row presents through. One instance belongs to one rendered
/// transcript, so a row is never able to outlive its own sheet's owner.
@MainActor
@Observable
final class ChatTranscriptSheetRouteOwner {
    private(set) var route: ChatTranscriptSheetRoute?

    func present(_ route: ChatTranscriptSheetRoute) {
        self.route = route
    }

    func dismiss() {
        route = nil
    }
}

private struct ChatTranscriptSheetRouteOwnerKey: EnvironmentKey {
    static let defaultValue: ChatTranscriptSheetRouteOwner? = nil
}

extension EnvironmentValues {
    /// The owner a row asks to present its detail sheet, or nil when the row is
    /// rendered outside a transcript host (a bare preview or fixture), where the
    /// detail action is simply unavailable.
    var chatTranscriptSheetRoutes: ChatTranscriptSheetRouteOwner? {
        get { self[ChatTranscriptSheetRouteOwnerKey.self] }
        set { self[ChatTranscriptSheetRouteOwnerKey.self] = newValue }
    }
}

/// Presents the route a row asked for, above the rows that asked for it.
/// `resolveToolRun` re-resolves a tool run from the projection this host owns —
/// the same capability the row had, moved to the boundary that survives the row.
/// A run that no longer resolves retires its route instead of presenting stale
/// content, which is what the row did when it refreshed its own details.
struct ChatTranscriptSheetHost: ViewModifier {
    let routes: ChatTranscriptSheetRouteOwner
    var installationTag: ChatTranscriptProjectionTag?
    var resolveToolRun: (([String], ChatTranscriptProjectionTag) -> [ChatToolPresentation]?)?

    @Environment(AppModel.self) private var model
    @Environment(\.displayPresentationHandler) private var presentDisplay
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.scenePhase) private var scenePhase
    @State private var toolRun: ToolRunResolvedState?
    @State private var detailDetent: PresentationDetent = .medium
    @State private var displayHandoff = ToolDisplayHandoff()

    func body(content: Content) -> some View {
        content
            .tronManagedSheet(
                item: Binding(
                    get: { routes.route },
                    set: { if $0 == nil { routes.dismiss() } }
                ),
                identity: { $0.id },
                onDismiss: completeDisplayHandoff
            ) { route in
                sheetContent(route)
            }
            .onChange(of: routes.route) { _, route in
                // A new presentation supersedes any intent the previous one left
                // behind. A dismissal is not a cancellation: the sheet completes
                // its own handoff as it goes away.
                guard let route else { return }
                displayHandoff.cancel()
                // The opened run's own resolution stays the fallback while the
                // sheet dismisses and its handoff completes.
                if let opened = route.toolRun { toolRun = opened.state }
            }
            .onChange(of: installationTag) { previous, current in
                if let previous, let current,
                   previous.presentationGeneration != current.presentationGeneration
                   || previous.runtimeGeneration != current.runtimeGeneration
                   || previous.sessionID != current.sessionID {
                    displayHandoff.cancel()
                }
                refreshToolRun()
            }
            .onChange(of: model.selectedGatewayProfileID()) { _, _ in displayHandoff.cancel() }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { displayHandoff.cancel() }
            }
    }

    @ViewBuilder
    private func sheetContent(_ route: ChatTranscriptSheetRoute) -> some View {
        switch route {
        case .toolRun(let value):
            LiveToolRunDetails(
                initial: toolRun ?? value.state,
                detent: $detailDetent,
                onDisplay: stageDisplayHandoff,
                onDismiss: { routes.dismiss() }
            )
        case .thinkingTrace(let value):
            ThinkingTraceDetailSheet(
                inline: value.inline,
                identity: value.identity,
                streaming: value.streaming
            )
        case .notificationDetail(let value):
            ChatNotificationDetailSheet(
                presentation: value.presentation,
                detailID: value.detailID
            )
        }
    }

    private func refreshToolRun() {
        guard let route = routes.route?.toolRun else { return }
        guard let installationTag,
              let tools = resolveToolRun?(route.toolIDs, installationTag), !tools.isEmpty else {
            routes.dismiss()
            return
        }
        // The opened run keeps its identity; only the install's generation and
        // the resolved payloads move with the projection the host owns.
        toolRun = ToolRunResolvedState(
            installationTag: installationTag,
            run: route.state.run,
            tools: tools
        )
    }

    private func stageDisplayHandoff(toolID: String, command: DisplayPresentationCommand) {
        guard let state = toolRun else { return }
        displayHandoff.stage(
            command,
            toolID: toolID,
            runtime: state.installationTag.runtimeGeneration,
            installation: state.installationTag.presentationGeneration,
            profile: model.selectedGatewayProfileID()
        )
        routes.dismiss()
    }

    /// The detail source establishes authority; the visible projection also
    /// includes admitted history pages, not just the 512-item gateway tail.
    private func completeDisplayHandoff() {
        guard let state = toolRun,
              let currentInstallation = model.presentationGeneration(
                for: state.installationTag.sessionID
              ) else {
            displayHandoff.cancel()
            return
        }
        let activity = surfaceToken.flatMap { activityCoordinator?.activity(for: $0) }
        let active = activity?.allowsPresentationPublication == true
            && scenePhase == .active && UIApplication.shared.applicationState == .active
        let source = model.sessionToolDetailSource(for: state.installationTag.sessionID)
            .flatMap { _ in model.transcriptSnapshot(for: state.installationTag.sessionID) }
        if let command = displayHandoff.consume(
            source: source,
            installation: currentInstallation,
            profile: model.selectedGatewayProfileID(),
            active: active
        ) { presentDisplay?(command) }
    }
}
