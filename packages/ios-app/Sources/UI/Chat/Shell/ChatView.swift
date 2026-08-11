import SwiftUI
import UIKit

// ARCHITECTURE: ~844 lines — coordinates navigation, keyboard, sheet presentation,
// and message rendering for the core chat interface. Complexity is inherent to the
// feature. 9 extracted computed properties keep sections navigable. Pragmatic trigger
// for decomposition: if it exceeds ~1,000 lines or gains a fourth coordination concern.

// MARK: - Chat View

enum ChatPresentationMode: Equatable {
    case interactiveSession
    case workerAudit
}

struct ChatView: View {
    // MARK: - Environment & State (internal for extension access)
    @Environment(\.dismiss) var dismiss
    @Environment(\.dependencies) var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @State var viewModel: ChatViewModel

    // Convenience accessor
    var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    @State var inputHistory = InputHistoryStore(defaults: .standard)
    @State var scrollCoordinator = ScrollStateCoordinator()
    @State var taskCoordinator: ChatViewTaskCoordinator
    @State var sessionConfigurationQueue = SessionConfigurationQueue()

    // MARK: - Sheet Coordinator (single sheet pattern)
    // Uses enum-based single .sheet(item:) modifier to avoid Swift compiler type-checking timeout
    // See: https://www.hackingwithswift.com/quick-start/swiftui/how-to-present-multiple-sheets
    @State var sheetCoordinator = SheetCoordinator()

    // MARK: - Navigation Lifecycle (SDF crash guard)
    // Disables .textSelection(.enabled) before navigation pop animation starts,
    // preventing EXC_BREAKPOINT in SwiftUI.SDFStyle.distanceRange.getter
    @State private var isDisappearing = false

    // MARK: - Toolbar Title Appearance
    /// Controls the fade-in of the principal toolbar item after navigation transition settles.
    @State var toolbarTitleOpacity: Double = 0
    @State var toolbarTitleOffsetY: CGFloat = 4

    // MARK: - Scroll State (internal for extension access)
    var scrollProxy: ScrollViewProxy? {
        get { viewportMeasurements.scrollProxy }
        nonmutating set { viewportMeasurements.scrollProxy = newValue }
    }
    @State var transcriptScrollPosition = ScrollPosition(edge: .bottom)

    // MARK: - Message Loading State (internal for extension access)
    @State var initialLoadComplete = false
    /// Non-observable measurement cache. Geometry callbacks must not invalidate
    /// the same LazyVStack layout pass that produced their values.
    @State var viewportMeasurements = ChatViewportMeasurements()

    // MARK: - Deep Link Scroll Target (internal for extension access)
    @Binding var scrollTarget: ScrollTarget?

    // MARK: - Stored Properties (internal for extension access)
    let sessionId: String
    let services: ChatSessionServices
    let presentationMode: ChatPresentationMode
    let readOnlyTitle: String?
    var onToggleSidebar: (() -> Void)?

    init(
        services: ChatSessionServices,
        sessionId: String,
        scrollTarget: Binding<ScrollTarget?> = .constant(nil),
        onToggleSidebar: (() -> Void)? = nil,
        presentationMode: ChatPresentationMode = .interactiveSession,
        readOnlyTitle: String? = nil
    ) {
        self.sessionId = sessionId
        self.services = services
        self.presentationMode = presentationMode
        self.readOnlyTitle = readOnlyTitle
        self._scrollTarget = scrollTarget
        self.onToggleSidebar = onToggleSidebar
        _viewModel = State(wrappedValue: ChatViewModel(services: services, sessionId: sessionId))
        _taskCoordinator = State(wrappedValue: ChatViewTaskCoordinator(sessionId: sessionId))
    }

    // MARK: - Body

    private var notificationContent: some View {
        chatNavigationContent
        .chatSheets(
            coordinator: sheetCoordinator,
            viewModel: viewModel,
            sessionId: sessionId,
            onSelectModel: { switchModel(to: $0) },
            onSelectReasoningLevel: { changeReasoningLevel(to: $0) }
        )
        // iOS 26 menu actions route through NotificationCenter before state mutation.
        .onReceive(NotificationCenter.default.publisher(for: .chatMenuAction)) { notification in
            guard presentationMode == .interactiveSession else { return }
            guard let raw = notification.object as? String,
                  let action = ChatMenuAction(rawValue: raw) else { return }
            switch action {
            case .settings: sheetCoordinator.showSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingShareMessage)) { notification in
            guard presentationMode == .interactiveSession else { return }
            guard let payload = notification.object as? ShareMessagePayload else { return }
            viewModel.inputText = payload.prompt
            viewModel.sendMessage(
                onPromptSent: { sentText in
                    inputHistory.addToHistory(sentText)
                }
            )
        }
        .onChange(of: viewModel.pendingUserInputRequest) { _, request in
            guard presentationMode == .interactiveSession else { return }
            if let request {
                guard viewModel.userInputAutoPresentationInvocationId == request.invocationId else {
                    return
                }
                viewModel.userInputAutoPresentationInvocationId = nil
                presentUserInput(request, automatically: true)
            } else {
                viewModel.userInputAutoPresentationInvocationId = nil
                sheetCoordinator.clearUserInput()
            }
        }
    }

    private var lifecycleContent: some View {
        notificationContent
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            scrollCoordinator.sceneDidBecomeActive(
                isPositionedByUser: transcriptScrollPosition.isPositionedByUser
            )
            guard initialLoadComplete else { return }
            scrollToBottomIfAllowed(reason: "foreground activation")
            // Do not rely exclusively on a SwiftUI-observed connection edge:
            // state mutations can be coalesced while the process is suspended.
            // The keyed task is idempotent with the connected-edge owner and
            // guarantees an authoritative catch-up on every foreground return.
            scheduleCoalescedRecoveryRefresh()
        }
        .onDisappear {
            taskCoordinator.invalidate()
            if presentationMode == .interactiveSession {
                // Persist draft state before an interactive chat is destroyed.
                Task {
                    await dependencies.draftStore.saveImmediately(
                        sessionId: sessionId,
                        inputBarState: viewModel.inputBarState
                    )
                    await dependencies.draftStore.flushPending()
                }
            }
            viewModel.clearLocalNotifications()
            viewModel.deactivateMountedResources()
            let sessionEvents = services.events
            Task { @MainActor in
                await sessionEvents.releaseSessionEventSubscription(
                    sessionId: sessionId,
                    workspaceId: nil
                )
            }
            // Do not reset `initialLoadComplete` here. SwiftUI can send
            // `onDisappear` for transient app/sheet/navigation transitions
            // while the same view state may return; clearing it hides the
            // transcript until a fresh reconstruction cycle completes.
            // A truly new ChatView instance starts with the default false.
            // Full reset of animation state when leaving session
            viewModel.animationCoordinator.fullReset()
        }
        .onChange(of: viewModel.inputBarState.draftFingerprint) { _, _ in
            guard presentationMode == .interactiveSession else { return }
            dependencies.draftStore.scheduleSave(sessionId: sessionId, inputBarState: viewModel.inputBarState)
        }
        .task {
            let ticket = taskCoordinator.beginLifecycle()
            taskCoordinator.replaceTask(.initialLoadWatchdog) { watchdogTicket in
                do {
                    try await Task.sleep(
                        for: .milliseconds(
                            ChatTranscriptRevealPolicy.initialShellLoadingBudgetMilliseconds
                        )
                    )
                } catch {
                    return
                }
                guard taskCoordinator.isCurrent(watchdogTicket),
                      !Task.isCancelled,
                      !viewModel.hasAuthoritativeHistory else { return }
                logger.info(
                    "[INIT] Initial reconstruction is still synchronizing after the shell loading budget",
                    category: .ui
                )
                if !initialLoadComplete {
                    viewModel.animationCoordinator.makeAllMessagesVisible(
                        count: viewModel.messages.count
                    )
                    initialLoadComplete = true
                }
            }
            if presentationMode == .interactiveSession,
               services.connection.connectionState.isConnected {
                viewModel.startSpeechTranscriptionMonitoring()
            }
            // PERFORMANCE OPTIMIZATION: Parallelize independent operations
            // and ensure UI is responsive immediately
            //
            // Critical order:
            // 1. Set manager reference first (sync, instant)
            // 2. Connect/resume and prefetch models run in parallel
            // 3. Sync/load messages runs after connect/resume completes
            //
            // Model prefetch is independent and doesn't block UI

            logger.debug("[INIT] task started, messages=\(viewModel.messages.count) scrollProxy=\(scrollProxy != nil) initialLoadComplete=\(initialLoadComplete)", category: .ui)
            viewModel.sessionLoadDiagnostics.recordShellPresented()

            let workspaceId = eventStoreManager.sessions.first { $0.id == sessionId }?.workspaceId ?? ""
            viewModel.setEventStoreManager(eventStoreManager, workspaceId: workspaceId)

            if await viewModel.restoreCachedTranscript() {
                guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
                await revealCachedTranscript(guardedBy: ticket)
                guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            }

            if presentationMode == .workerAudit {
                // Read-only transcripts still own a live suffix. The
                // coordinator subscribes before its durable snapshot and the
                // view model buffers frames until that snapshot commits.
                viewModel.startLiveEventStream()
                let historyWasProvisional = !viewModel.hasAuthoritativeHistory
                let initialReconstructionOutcome = await viewModel.reconstructReadOnlyTranscript()
                guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
                await settleTranscriptAfterReconstruction(
                    historyWasProvisional: historyWasProvisional,
                    outcome: initialReconstructionOutcome,
                    guardedBy: ticket
                )
                guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
                taskCoordinator.cancelTask(.initialLoadWatchdog)
                if initialReconstructionOutcome == .retryableFailure {
                    scheduleCoalescedRecoveryRefresh()
                }
                return
            }

            viewModel.startLiveEventStream()

            // Draft attachment I/O is independent of authoritative history.
            // Start it under the mounted lifecycle without delaying session
            // resume/reconstruction, and never overwrite typing that begins
            // before a slow draft read completes.
            viewModel.draftStore = dependencies.draftStore
            let initialDraftFingerprint = viewModel.inputBarState.draftFingerprint
            taskCoordinator.replaceTask(.draftRestore) { _ in
                _ = await dependencies.draftStore.loadDraft(
                    sessionId: sessionId,
                    into: viewModel.inputBarState,
                    ifUnchangedFrom: initialDraftFingerprint
                )
            }

            // Run model prefetch in parallel with connect/resume
            // This is a fire-and-forget operation that doesn't block session entry
            taskCoordinator.replaceTask(.modelPrefetch) { prefetchTicket in
                await prefetchModels(guardedBy: prefetchTicket)
            }

            // Connect, resume, and reconstruct session state in one flow
            logger.debug("[INIT] starting connectAndReconstruct", category: .ui)
            let recoveryGenerationBeforeReconstruction = viewModel.streamRecoveryRequestGeneration
            let historyWasProvisional = !viewModel.hasAuthoritativeHistory
            let initialReconstructionOutcome = await viewModel.connectAndReconstruct()
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            logger.debug("[INIT] connectAndReconstruct done, messages=\(viewModel.messages.count)", category: .ui)

            // Resolve initial visibility through the same owner used by a later
            // continuity retry. It sets `initialLoadComplete` only after the
            // viewport/deep-link work needed by the outcome has settled.
            await settleTranscriptAfterReconstruction(
                historyWasProvisional: historyWasProvisional,
                outcome: initialReconstructionOutcome,
                guardedBy: ticket
            )
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            taskCoordinator.cancelTask(.initialLoadWatchdog)
            logger.debug("[INIT] handleInitialMessageVisibility done, initialLoadComplete=\(initialLoadComplete)", category: .ui)
            if initialReconstructionOutcome == .retryableFailure
                || viewModel.streamRecoveryRequestGeneration != recoveryGenerationBeforeReconstruction {
                scheduleCoalescedRecoveryRefresh()
            }
        }
    }

    var body: some View {
        lifecycleContent
        .onChange(of: services.connection.continuity) { oldContinuity, newContinuity in
            if presentationMode == .interactiveSession {
                if newContinuity.isConnected {
                    viewModel.startSpeechTranscriptionMonitoring()
                } else {
                    viewModel.stopSpeechTranscriptionMonitoring()
                }
            }
            if initialLoadComplete,
               newContinuity.requiresReconciliation(after: oldContinuity) {
                scheduleReconstructionRefresh()
            }
            // Composer actions read this same session transport state directly;
            // successful reconstruction must not wait on a second readiness owner.
        }
        .onChange(of: viewModel.streamRecoveryRequestGeneration) { _, _ in
            guard presentationMode == .interactiveSession else { return }
            guard initialLoadComplete else { return }
            scheduleCoalescedRecoveryRefresh()
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            // Navigate back when session doesn't exist on server
            if shouldDismiss {
                logger.info("Session not found on server, navigating back to session list", category: .session)
                dismiss()
            }
        }
        .onChange(of: scrollTarget) { _, target in
            // Handle deep link scroll target
            guard let target = target else { return }

            // Wait for initial load to complete before scrolling
            guard initialLoadComplete else {
                // If not loaded yet, the target will be handled by handleInitialMessageVisibility
                return
            }

            taskCoordinator.replaceTask(.deepLinkScroll) { ticket in
                guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
                await performDeepLinkScroll(to: target, guardedBy: ticket)
                guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            }
        }
    }

    /// Connected edges and explicit stream-continuity markers share one
    /// cancel-and-replace reconstruction task owner.
    private func scheduleReconstructionRefresh() {
        taskCoordinator.replaceTask(.connectionRefresh) { ticket in
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            await restoreContinuity(guardedBy: ticket)
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
        }
    }

    /// A marker burst represents one outstanding continuity gap. Keep one
    /// follow-up behind any reconstruction already in flight instead of
    /// repeatedly cancelling the repair.
    private func scheduleCoalescedRecoveryRefresh() {
        taskCoordinator.coalesceTask(.connectionRefresh) { ticket in
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
            await restoreContinuity(guardedBy: ticket)
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }
        }
    }

    /// Keep one continuity repair outstanding while the socket remains
    /// connected. Retryable RPC failures retain the live-event buffer and use
    /// bounded backoff; disconnects stop this task and the next connected edge
    /// restarts it through the same keyed owner.
    private func restoreContinuity(guardedBy ticket: ChatViewTaskTicket) async {
        let retryDelays: [Duration] = [
            .milliseconds(250),
            .seconds(1),
            .seconds(2),
            .seconds(5),
            .seconds(10)
        ]
        var retryIndex = 0

        while taskCoordinator.isCurrent(ticket), !Task.isCancelled {
            let historyWasProvisional = !viewModel.hasAuthoritativeHistory
            let outcome = presentationMode == .workerAudit
                ? await viewModel.reconstructReadOnlyTranscript()
                : await viewModel.connectAndReconstruct()
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }

            await settleTranscriptAfterReconstruction(
                historyWasProvisional: historyWasProvisional,
                outcome: outcome,
                guardedBy: ticket
            )
            guard taskCoordinator.isCurrent(ticket), !Task.isCancelled else { return }

            switch outcome {
            case .completed, .terminalFailure, .cancelled:
                return
            case .retryableFailure:
                guard services.connection.connectionState.isConnected else { return }
                let delay = retryDelays[min(retryIndex, retryDelays.count - 1)]
                retryIndex += 1
                logger.warning(
                    "[RECONSTRUCT] Continuity repair failed; retrying after \(delay)",
                    category: .session
                )
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Chat Navigation Content (extracted to reduce body complexity for type-checker)

    private var chatNavigationContent: some View {
        chatCoreContent
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGestureEnabler())
        .toolbar {
            leadingToolbarItem
            principalToolbarItem
            trailingToolbarItem
        }
    }

    // MARK: - Chat Core Content (extracted to reduce body complexity for type-checker)

    @ViewBuilder
    private var chatCoreContent: some View {
        let content = transcriptScrollView
            .overlay {
                EmptyView()
            }
            .environment(\.textSelectionDisabled, isDisappearing)
            .background(
                NavigationWillDisappearObserver {
                    isDisappearing = true
                }
                .frame(width: 0, height: 0)
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if presentationMode == .interactiveSession {
                    inputAreaContent
                }
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)

        if presentationMode == .workerAudit {
            // A worker transcript is presented inside a detented sheet. Keep
            // its content transparent so the presentation owns the medium
            // Liquid Glass and large opaque surfaces.
            content
        } else {
            content.tronScreenBackground()
        }
    }
}

// MARK: - iOS 26 Menu Action Routing
// Menu button actions that mutate @State break gesture handling in iOS 26.
// Posting a notification lets the parent view mutate state from onReceive.

enum ChatMenuAction: String {
    case settings
}

extension Notification.Name {
    static let chatMenuAction = Notification.Name("chatMenuAction")
    static let navigationModeAction = Notification.Name("navigationModeAction")
    static let showSettingsAction = Notification.Name("showSettingsAction")
    static let pendingShareContent = Notification.Name("pendingShareContent")
    static let pendingShareMessage = Notification.Name("pendingShareMessage")
    static let switchToSession = Notification.Name("tron.switchToSession")
}
