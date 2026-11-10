import SwiftUI
import TronMobileCore

struct ChatToolRunSheetRoute: Equatable, Sendable {
    let runID: String
    let toolIDs: [String]
    let state: ToolRunResolvedState
}

struct ChatThinkingTraceSheetRoute: Equatable, Sendable {
    let identity: String
    let opened: ChatThinkingTraceContent
}

struct ChatNotificationDetailSheetRoute: Equatable, Sendable {
    let eventID: String
    let detailID: UUID
    let opened: ChatNotificationPresentation
}

enum ChatTranscriptSheetRoute: Equatable, Identifiable {
    case toolRun(ChatToolRunSheetRoute)
    case thinkingTrace(ChatThinkingTraceSheetRoute)
    case prompt(HomeTextReading)
    case notificationDetail(ChatNotificationDetailSheetRoute)

    var id: String {
        switch self {
        case .toolRun(let route): "chat.tool-run.\(route.runID)"
        case .thinkingTrace(let route): "chat.thinking-trace.\(route.identity)"
        case .prompt(let reading): "chat.prompt.\(reading.id)"
        case .notificationDetail(let route): "chat.transcript-event-detail.\(route.eventID)"
        }
    }

    var toolRun: ChatToolRunSheetRoute? {
        guard case .toolRun(let route) = self else { return nil }
        return route
    }
}

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
    var chatTranscriptSheetRoutes: ChatTranscriptSheetRouteOwner? {
        get { self[ChatTranscriptSheetRouteOwnerKey.self] }
        set { self[ChatTranscriptSheetRouteOwnerKey.self] = newValue }
    }
}

struct ChatTranscriptSheetHost: ViewModifier {
    let routes: ChatTranscriptSheetRouteOwner
    var installationTag: ChatTranscriptProjectionTag?
    var resolveToolRun: (([String], ChatTranscriptProjectionTag) -> [ChatToolPresentation]?)?
    var resolveThinkingTrace: ((String) -> ChatThinkingTraceContent?)?
    var resolveNotificationDetail: ((String) -> ChatNotificationPresentation?)?

    @Environment(AppModel.self) private var model
    @Environment(\.displayPresentationHandler) private var presentDisplay
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var activity
    @State private var toolRun: ToolRunResolvedState?
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
                guard let route else { return }
                displayHandoff.cancel()
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
                onDisplay: stageDisplayHandoff,
                onDismiss: { routes.dismiss() }
            )
        case .thinkingTrace(let value):
            LiveThinkingTraceSheet(
                identity: value.identity,
                opened: value.opened,
                resolve: resolveThinkingTrace
            )
        case .prompt(let reading):
            HomeTextReader(reading: reading).tronSettingsVisualTheme(accent: .tronPrimary)
        case .notificationDetail(let value):
            LiveNotificationDetailSheet(
                eventID: value.eventID,
                detailID: value.detailID,
                opened: value.opened,
                resolve: resolveNotificationDetail
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

private struct LiveThinkingTraceSheet: View {
    let identity: String
    let opened: ChatThinkingTraceContent
    let resolve: ((String) -> ChatThinkingTraceContent?)?
    @State private var followed: ChatThinkingTraceContent?

    var body: some View {
        let live = resolve?(identity)
        let content = live ?? followed ?? opened
        ThinkingTraceDetailSheet(
            inline: content.inline,
            identity: identity,
            streaming: content.streaming
        )
        .onChange(of: live, initial: true) { _, resolved in
            guard let resolved else { return }
            followed = resolved
        }
    }
}

private struct LiveNotificationDetailSheet: View {
    let eventID: String
    let detailID: UUID
    let opened: ChatNotificationPresentation
    let resolve: ((String) -> ChatNotificationPresentation?)?
    @State private var followed: ChatNotificationPresentation?

    var body: some View {
        let live = resolve?(eventID)
        ChatNotificationDetailSheet(
            presentation: live ?? followed ?? opened,
            detailID: detailID
        )
        .onChange(of: live, initial: true) { _, resolved in
            guard let resolved else { return }
            followed = resolved
        }
    }
}
