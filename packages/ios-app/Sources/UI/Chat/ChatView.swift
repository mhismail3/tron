import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let sessionID: String
    private let initialEditorText: String?
    private let initialModel: ModelRef?
    private let initialHistoryEntryID: String?
    private let initialSearchResult: SessionSearchResult?
    private let onForkCreated: (AppModel.SessionNavigationRoute) -> Void
    private let displayFrameScheduler: DisplayFrameScheduler
    private let performanceSignposts: any PerformanceSignposting
    #if HOSTED_TEST
    let hostedProbe: ChatHostedProbe?
    #endif
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationActivityCoordinator) private var presentationCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var presentationSurfaceToken
    @State private var sessionPresentation: ChatSessionPresentation
    @State private var composerScope: ComposerDraftScope?
    @State private var initialModelSettled = true
    @State private var toolbarContainerWidth = ChatToolbarTitleLayout.defaultContainerWidth
    @State private var scrollCoordinator: ChatScrollCoordinator
    @State private var transcriptPresentation: ChatTranscriptPresentationStore
    @State private var performanceTracker: ChatPerformanceTracker
    @State private var transcriptScrollPosition = ScrollPosition(idType: String.self)
    @Namespace private var composerGlassNamespace
    // UITextView owns responder state; this mirrors its delegate callbacks for
    // placeholder and scroll presentation.
    @State private var composerFocused = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerHeightLedger = ChatComposerHeightLedger()
    @State private var interactionTraceLedger = ChatInteractionTraceLedger()
    @State private var composerResponder = ChatComposerResponder()
    @State private var keyboardObserver = ChatKeyboardObserver()
    @State private var layoutTransaction = ChatLayoutTransaction()
    @State private var installedComposerResourceCatalog: (
        source: ComposerResourceCatalogIdentity, catalog: ComposerResourceCatalog
    )?
    @State private var composerResourcePicker: ComposerResourcePickerSource?
    @State private var composerResourceResults: [ComposerResourceEntry] = []
    /// The exact installed frame from before a descendant began consuming live
    /// transcript data. Viewport work is rebased once on uncover rather than on
    /// every hidden tool-output update.
    @State private var deferredViewportProjectionBaseline: InstalledChatTranscript?
    @State private var hasDeferredViewportProjection = false
    @State private var floatingDisplayCompletionTracker = DisplayFloatingCompletionTracker()
    /// One native viewport activation can surface through scene, coverage, and
    /// reconciliation callbacks. They share this identity so physical evidence
    /// is rebased exactly once for the replacement tree.
    @State private var viewportActivation = 0

    #if HOSTED_TEST
    init(
        sessionID: String,
        initialEditorText: String? = nil,
        initialModel: ModelRef? = nil,
        initialHistoryEntryID: String? = nil,
        initialSearchResult: SessionSearchResult? = nil,
        onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
        hostedProbe: ChatHostedProbe? = nil,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.sessionID = sessionID
        self.initialEditorText = initialEditorText
        self.initialModel = initialModel
        self.initialHistoryEntryID = initialHistoryEntryID
        self.initialSearchResult = initialSearchResult
        self._initialModelSettled = State(initialValue: initialModel == nil)
        self.onForkCreated = onForkCreated
        self.hostedProbe = hostedProbe
        self.displayFrameScheduler = displayFrameScheduler
        self.performanceSignposts = performanceSignposts
        _composerScope = State(initialValue: nil)
        _scrollCoordinator = State(initialValue: ChatScrollCoordinator(frameScheduler: displayFrameScheduler))
        _transcriptPresentation = State(initialValue: ChatTranscriptPresentationStore(
            performanceSignposts: performanceSignposts,
            installationFrameScheduler: displayFrameScheduler
        ))
        _performanceTracker = State(initialValue: ChatPerformanceTracker(signposts: performanceSignposts))
        _sessionPresentation = State(initialValue: ChatSessionPresentation(sessionID: sessionID))
    }
    #else
    init(
        sessionID: String,
        initialEditorText: String? = nil,
        initialModel: ModelRef? = nil,
        initialHistoryEntryID: String? = nil,
        initialSearchResult: SessionSearchResult? = nil,
        onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.sessionID = sessionID
        self.initialEditorText = initialEditorText
        self.initialModel = initialModel
        self.initialHistoryEntryID = initialHistoryEntryID
        self.initialSearchResult = initialSearchResult
        self._initialModelSettled = State(initialValue: initialModel == nil)
        self.onForkCreated = onForkCreated
        self.displayFrameScheduler = displayFrameScheduler
        self.performanceSignposts = performanceSignposts
        _composerScope = State(initialValue: nil)
        _scrollCoordinator = State(initialValue: ChatScrollCoordinator(frameScheduler: displayFrameScheduler))
        _transcriptPresentation = State(initialValue: ChatTranscriptPresentationStore(
            performanceSignposts: performanceSignposts,
            installationFrameScheduler: displayFrameScheduler
        ))
        _performanceTracker = State(initialValue: ChatPerformanceTracker(signposts: performanceSignposts))
        _sessionPresentation = State(initialValue: ChatSessionPresentation(sessionID: sessionID))
    }
    #endif

    private var contentSurface: some View {
        transcript
            .overlay(alignment: .top) { topBlur }
            .overlay {
                // The inset and native navigation/keyboard layout propose the
                // same usable region to this overlay as to the transcript.
                // Do not subtract safe-area insets or mirror composer height.
                ChatFloatingDisplayHost(
                    route: $sessionPresentation.floatingDisplay,
                    onOpenSheet: { sessionPresentation.presentDisplay(.showSheet($0)) }
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The complete composer is the sole structural inset owner, so
                // the keyboard, multiline text, and attachment chips push the
                // native transcript viewport exactly once and reverse naturally.
                composer
                    #if HOSTED_TEST
                    .background {
                        ChatHostedNativeRowProbe(
                            physicalID: ChatHostedNativeRowProbe.composerID,
                            semanticID: ChatHostedNativeRowProbe.composerID,
                            identity: UUID()
                        )
                    }
                    #endif
            }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            toolbarContainerWidth = width
        }
        .background { Color.tronBackground.ignoresSafeArea(.all) }
        .environment(\.canonicalResourceSessionID, sessionID)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGestureEnabler())
        .tint(Color.tronEmerald)
        .toolbar {
            toolbar(titleWidth: ChatToolbarTitleLayout.width(containerWidth: toolbarContainerWidth))
        }
        .modifier(ChatRoutes(
            sessionID: sessionID,
            projectCWD: model.sessionContextPresentation(for: sessionID)?.cwd,
            initialHistoryEntryID: initialHistoryEntryID,
            onForkCreated: onForkCreated,
            showContext: $sessionPresentation.showContext,
            showSettings: $sessionPresentation.showSettings,
            queuedMessageEditor: $sessionPresentation.queuedMessageEditor,
            queueCommit: queueEditorCommit,
            mutatingQueuedMessageIDs: sessionPresentation.mutatingQueuedMessageIDs,
            onUpdateQueuedMessage: { commit, id, text, behavior in
                Task { await updateQueuedMessage(id, text: text, behavior: behavior, commit: commit) }
            },
            onRemoveQueuedMessage: { commit, id in Task { await removeQueuedMessage(id, commit: commit) } },
            cameraPresented: attachmentPresentationBinding(for: .camera),
            photosPresented: attachmentPresentationBinding(for: .photos),
            photos: $sessionPresentation.photos,
            onCameraImage: { image in Task { await importCameraImage(image) } },
            activityPresented: activityPresentationBinding,
            extensionContent: extensionRetainedContent,
            omittedExtensionContentCount: omittedExtensionContentCount,
            // Process rows come from the mounted SessionPresentation owner,
            // not a raw snapshot read that can bypass its anchor retention.
            processActivities: model.sessionProcessPresentation(for: sessionID)?.activities ?? [],
            interaction: interactionBinding,
            onInteractionClosed: closeInteractionPresentation,
            filesPresented: attachmentPresentationBinding(for: .files),
            onFileImport: { result in Task { await importFiles(result) } },
            editorRequest: editorRequestBinding,
            displaySheet: $sessionPresentation.displaySheet,
            onUseEditorRequest: { request in
                guard let target = presentationTarget else { return }
                model.disposeExtensionEditorRequest(request, disposition: .use, target: target)
            },
            onKeepEditorRequest: { request in
                guard let target = presentationTarget else { return }
                model.disposeExtensionEditorRequest(request, disposition: .keep, target: target)
            }
        ))
        .onChange(of: sessionPresentation.photos) { _, values in
            guard !values.isEmpty else { return }
            // PhotosPicker may deliver after its native presentation closes.
            // Clear the selection first so it cannot replay into another chat,
            // then bind this import to the current presentation authority.
            sessionPresentation.photos = []
            guard let target = presentationTarget else {
                sessionPresentation.cancelImports()
                return
            }
            sessionPresentation.photoImportTask?.cancel()
            sessionPresentation.photoImportTarget = target
            sessionPresentation.photoImportTask = Task { @MainActor in
                await importPhotos(values, target: target)
                guard !Task.isCancelled,
                      sessionPresentation.photoImportTarget == target else { return }
                sessionPresentation.photoImportTask = nil
                sessionPresentation.photoImportTarget = nil
            }
        }
        .onChange(of: attachmentMenuState) { previous, current in
            if previous.sessionID != current.sessionID {
                composerResourcePicker = nil
                cancelAttachmentPresentation(includingActive: true)
                sessionPresentation.cancelImports()
            } else if !current.actionsEnabled {
                composerResourcePicker = nil
                cancelAttachmentPresentation(includingActive: false)
                sessionPresentation.cancelImports()
            }
        }
        .onChange(of: queueEditorCommit) { _, commit in
            guard let editor = sessionPresentation.queuedMessageEditor,
                  commit?.items.contains(where: { $0.id == editor.id }) != true else { return }
            sessionPresentation.queuedMessageEditor = nil
        }
        .task(id: PresentationActivityTaskID(
            source: composerResourceCatalogIdentity,
            presentationActive: presentationActivity.allowsPresentationPublication && scenePhase == .active
        )) {
            let activity = composerCatalogActivity
            guard !Task.isCancelled, activity.allowsPresentationPublication, scenePhase == .active else { return }
            // Command authority continues under a sheet; only this composer's
            // disposable index pauses, retaining its last complete value.
            let identity = composerResourceCatalogIdentity
            let ownsCatalog = identity.catalogTarget != nil
                && identity.catalogTarget == identity.presentationTarget
            let commands = ownsCatalog
                ? identity.commands.filter { identity.supportsSkillPrompt || $0.source != .skill }
                : []
            #if HOSTED_TEST
            hostedProbe?.recordComposerCatalogBuild()
            defer { hostedProbe?.composerCatalogDidFinish?(commands) }
            #endif
            let build = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let catalog = ComposerResourceCatalog(commands: commands)
                try Task.checkCancellation()
                return catalog
            }
            let catalog: ComposerResourceCatalog
            do {
                catalog = try await withTaskCancellationHandler {
                    try await build.value
                } onCancel: {
                    build.cancel()
                }
            } catch {
                return
            }
            #if HOSTED_TEST
            await hostedProbe?.composerCatalogWillInstall?(catalog)
            #endif
            guard !Task.isCancelled, activity == composerCatalogActivity, scenePhase == .active,
                  identity == composerResourceCatalogIdentity else { return }
            installedComposerResourceCatalog = (identity, catalog)
            #if HOSTED_TEST
            hostedProbe?.recordComposerCatalogInstall(catalog)
            #endif
            if ownsCatalog, let composerScope {
                model.composerDrafts.reconcileSelectedResource(for: composerScope, commands: commands)
            }
            if let picker = composerResourcePicker {
                composerResourceResults = catalog.entries(for: picker)
            }
            reconcileComposerResourcePicker()
        }
        .onChange(of: composerText) { _, _ in reconcileComposerResourcePicker() }
        .onChange(of: composerSelection) { _, _ in reconcileComposerResourcePicker() }
        .onChange(of: composerFocused) { _, _ in
            keyboardObserver.setOwnerWindow(composerResponder.window)
        }
        .environment(\.pendingExtensionInteractionPresenter) { interaction in
            guard selectedAuthoritativeSnapshot?.extensionPresentation.pendingInteractions
                .contains(where: { ExtensionInteractionScope($0) == ExtensionInteractionScope(interaction) }) == true else { return }
            sessionPresentation.requestInteractionPresentation(interaction)
        }
        .environment(\.displayPresentationHandler) { command in
            sessionPresentation.presentDisplay(command)
        }
        .onChange(of: transcriptPresentation.installed?.tag) { _, _ in
            reconcileFloatingDisplayCompletion()
        }
        .onChange(of: presentationActivity) { _, activity in
            guard activity.allowsPresentationPublication else { return }
            admitPendingFloatingDisplay()
        }
        .task(id: "search-anchor:\(sessionID):\(initialHistoryEntryID ?? "")") {
            guard let entryID = initialHistoryEntryID,
                  let searchResult = initialSearchResult,
                  let profileID = model.profiles.selected?.id else { return }
            // The mounted presentation is the admission fence; the owning
            // scroll coordinator waits for the exact historical row's layout.
            guard let generation = model.sessionPresentationGeneration(for: sessionID) else { return }
            do {
                guard try await model.navigateToSearchResult(searchResult, profileID: profileID) else {
                    model.presentError(NSError(domain: "TronSearchNavigation", code: 1, userInfo: [NSLocalizedDescriptionKey: "The searched message could not be loaded. Try searching again."]))
                    return
                }
                guard generation == model.sessionPresentationGeneration(for: sessionID), !Task.isCancelled else { return }
                scrollCoordinator.requestHistoricalEntryScroll(semanticID: entryID, installed: transcriptPresentation.installed)
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled else { return }
                model.presentError(error)
            }
        }
    }

    private var completedDisplayPresentations: [DisplayProjection] {
        transcriptPresentation.installed?.completedDisplayPresentations ?? []
    }

    private func reconcileFloatingDisplayCompletion() {
        let current = transcriptPresentation.installed?.completedDisplayPresentations
        guard let transition = floatingDisplayCompletionTracker.transition(to: current) else {
            if current == nil { sessionPresentation.pendingFloatingDisplay = nil }
            return
        }
        admitNewFloatingDisplay(previous: transition.previous, current: transition.current)
    }

    private func admitNewFloatingDisplay(
        previous: [DisplayProjection],
        current: [DisplayProjection]
    ) {
        let admission = DisplayFloatingAdmissionPolicy.admission(
            previous: previous,
            current: current,
            sceneActive: scenePhase == .active,
            presentationReady: isTranscriptReady,
            allowsPresentation: presentationActivity.allowsPresentationPublication,
            hasFloatingDisplay: sessionPresentation.floatingDisplay != nil,
            consumedRevisionIDs: sessionPresentation.automaticallyPresentedDisplayIDs.ids
        )
        switch admission {
        case .none:
            break
        case .deferred(let display):
            if sessionPresentation.pendingFloatingDisplay == nil {
                sessionPresentation.pendingFloatingDisplay = DisplayRoute(sessionID: sessionID, display: display)
            }
        case .present(let display):
            let key = display.presentationIdentity
            sessionPresentation.automaticallyPresentedDisplayIDs.formUnion([key])
            sessionPresentation.floatingDisplay = DisplayRoute(sessionID: sessionID, display: display)
        }
    }

    private func admitPendingFloatingDisplay() {
        guard scenePhase == .active, isTranscriptReady,
              composerCatalogActivity.allowsPresentationPublication,
              sessionPresentation.floatingDisplay == nil,
              let route = sessionPresentation.pendingFloatingDisplay else {
            if scenePhase != .active { sessionPresentation.pendingFloatingDisplay = nil }
            return
        }
        guard completedDisplayPresentations.contains(where: {
            $0.presentationIdentity == route.display.presentationIdentity
        }) else {
            sessionPresentation.pendingFloatingDisplay = nil
            return
        }
        let key = route.display.presentationIdentity
        sessionPresentation.pendingFloatingDisplay = nil
        guard !sessionPresentation.automaticallyPresentedDisplayIDs.contains(key) else { return }
        sessionPresentation.automaticallyPresentedDisplayIDs.formUnion([key])
        sessionPresentation.floatingDisplay = route
    }

    var body: some View {
        contentSurface
        .onAppear {
            if floatingDisplayCompletionTracker.baseline == nil {
                _ = floatingDisplayCompletionTracker.transition(
                    to: transcriptPresentation.installed?.completedDisplayPresentations
                )
            }
            _ = ensureInteractionTraceContext()
            recordComposerAvailability()
            scrollCoordinator.viewportObservationChanged(
                isActive: presentationActivity.allowsViewportObservation
            )
            keyboardObserver.setOwnerWindow(composerResponder.window)
            keyboardObserver.start()
            reconcileSessionPresentationVisibility()
            layoutTransaction.configure(
                keyboard: keyboardObserver.transition,
                reduceMotion: reduceMotion
            )
        }
        .onChange(of: keyboardObserver.transition) { _, transition in
            layoutTransaction.configure(keyboard: transition, reduceMotion: reduceMotion)
            guard layoutTransaction.generation != nil else { return }
            let participant = layoutTransaction.joinParticipant(.keyboard)
            // UIKit owns the inset interpolation. Keep only the participant
            // lease on the frozen structural clock; an empty SwiftUI animation
            // is not physical keyboard-completion evidence.
            layoutTransaction.settleAfterResolvedClock(participant)
        }
        .onChange(of: reduceMotion) { _, enabled in
            layoutTransaction.configure(keyboard: keyboardObserver.transition, reduceMotion: enabled)
        }
        .onChange(of: layoutTransaction.terminalEventRevision) { _, _ in
            for event in layoutTransaction.consumeTerminalEvents() {
                switch event {
                case .settled(let generationID):
                    scrollCoordinator.layoutTransactionSettled(generationID)
                case .abandoned(let generationID):
                    scrollCoordinator.layoutTransactionAbandoned(generationID)
                case .overflow:
                    scrollCoordinator.cancel()
                }
            }
        }
        .onChange(of: scenePhase) { _, current in
            scenePhaseChanged(current)
        }
        .onChange(of: composerAvailability) { _, availability in
            guard let context = interactionTraceLedger.context,
                  interactionTraceLedger.ownsContext(context) else { return }
            model.chatInteractionTrace.availability(
                availability, context: context, state: interactionTraceState()
            )
        }
        .onChange(of: model.connectionState) { _, state in
            reconcileSessionPresentationVisibility()
            guard scenePhase == .active,
                  presentationActivity.allowsPresentationPublication,
                  state == .connected,
                  admitsAutomaticOpeningResume else { return }
            beginOpeningAfterForegroundWhenConnected()
        }
        .onChange(of: model.presentationTarget(for: sessionID)) { _, target in
            guard let target,
                  let generation = sessionPresentation.modelPresentationGeneration,
                  target.generation != generation else { return }
            beginOpeningAfterForegroundWhenConnected()
        }
        .onChange(of: model.foregroundReconciliationGeneration) { _, _ in
            foregroundReconciliationCompleted()
        }
        .onChange(of: presentationActivity) { previous, current in
            reconcileSessionPresentationVisibility(
                surfaceActive: current.allowsDataPublication
            )
            if previous.allowsContinuousAnimation,
               !current.allowsContinuousAnimation {
                abandonLayoutTransaction()
            }
            if previous.allowsViewportObservation,
               !current.allowsViewportObservation {
                viewportActivation &+= 1
                scrollCoordinator.viewportActivationChanged(viewportActivation)
                scrollCoordinator.viewportObservationChanged(isActive: false)
                if sessionPresentation.openingTask != nil {
                    // A covered transcript cannot publish the native geometry
                    // needed to finish positioning. Cancel the exact opening and
                    // scroll leases now so uncovering resumes with a fresh epoch;
                    // never let their deadlines mature behind another surface.
                    sessionPresentation.cancelOpeningTask()
                    scrollCoordinator.cancel()
                }
                if current.allowsDataPublication,
                   !hasDeferredViewportProjection {
                    deferredViewportProjectionBaseline = transcriptPresentation.installed
                    hasDeferredViewportProjection = true
                }
            }
            if previous.allowsPresentationPublication,
               !current.allowsPresentationPublication {
                // Retire a build/ready frame already admitted before cover, not
                // just future source callbacks. Descendant facts have their own
                // state selectors; the covered native transcript stays installed.
                transcriptPresentation.suspendPendingWork()
            }
            if !current.allowsDataPublication {
                deferredViewportProjectionBaseline = nil
                hasDeferredViewportProjection = false
            }
            if !previous.allowsViewportObservation,
               current.allowsViewportObservation {
                viewportActivation &+= 1
                scrollCoordinator.viewportActivationChanged(viewportActivation)
                scrollCoordinator.viewportObservationChanged(isActive: true)
                if scenePhase == .active,
                   !admitsAutomaticOpeningResume,
                   transcriptPresentation.installed != nil {
                    scrollCoordinator.foregroundViewportBecameActive(
                        activation: viewportActivation
                    )
                }
                reconcileDeferredViewportProjectionIfNeeded()
            }
        }
        .onChange(of: scrollCoordinator.defersAutomaticLiveProjectionIntake) { _, deferred in
            automaticLiveProjectionIntakeChanged(deferred: deferred)
        }
        .task(id: ChatOpeningSurfaceTaskID(
            surfaceActive: scenePhase == .active && presentationActivity.allowsPresentationPublication,
            openingTaskRevision: sessionPresentation.openingTaskRevision
        )) {
            switch ChatOpeningSurfacePolicy.action(
                surfaceActive: scenePhase == .active && presentationActivity.allowsPresentationPublication,
                hasOpeningTask: sessionPresentation.openingTask != nil,
                needsOpeningResume: admitsAutomaticOpeningResume
            ) {
            case .none:
                await recoverExtensionPresentationPublicationIfNeeded()
            case .begin:
                await beginOpeningPresentation()
            case .waitForCurrentThenBeginIfNeeded:
                guard let active = sessionPresentation.activeOpeningTaskLease else { return }
                await active.task.value
                _ = sessionPresentation.finishOpeningTask(active.generation)
                guard !Task.isCancelled,
                      scenePhase == .active,
                      composerCatalogActivity.allowsPresentationPublication,
                      admitsAutomaticOpeningResume else { return }
                await beginOpeningPresentation()
            }
        }
        .background { activeProjectionObservationDriver }
        .onChange(of: transcriptPresentation.installed?.tag) { previousTag, _ in
            let installed = transcriptPresentation.installed
            if ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
                commandIsPending: sessionPresentation.queueMutationCommandIsPending,
                expectedRevision: sessionPresentation.pendingQueueMutationRevision,
                installedRevision: installed?.queueRevision
            ) {
                clearSettledQueueMutationPresentationState()
            }
            if presentationActivity.allowsViewportObservation {
                if hasDeferredViewportProjection {
                    reconcileDeferredViewportProjectionIfNeeded()
                } else {
                    reconcileInstalledProjectionForViewport(
                        previousTag: previousTag,
                        installed: installed
                    )
                }
            }
            #if HOSTED_TEST
            if let installed {
                hostedProbe?.recordProjectionInstall(
                    rowCount: installed.timeline.items.count,
                    sourceOrdinal: installed.tag.timelineGeneration,
                    nextRenderedIDBySemanticID: installed.hostedRenderedIDBySemanticID
                )
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            transcriptPresentation.handleMemoryPressure()
        }
        .onDisappear(perform: retirePresentation)
    }

    @discardableResult
    private func ensureInteractionTraceContext() -> Int {
        if let context = interactionTraceLedger.context { return context }
        let context = model.chatInteractionTrace.beginContext(
            retainedPresentation: transcriptPresentation.installed != nil
        )
        interactionTraceLedger.installContext(context)
        scrollCoordinator.configureInteractionTrace(model.chatInteractionTrace, context: context)
        layoutTransaction.configureInteractionTrace(model.chatInteractionTrace, context: context)
        return context
    }

    private func interactionTraceState(
        installed: InstalledChatTranscript? = nil
    ) -> ChatInteractionTrace.State {
        let installed = installed ?? transcriptPresentation.installed
        let geometry = scrollCoordinator.latestGeometry
        let hasLifecycleRow: Bool? = installed.map { value in
            if case .none = value.handoff { return false }
            return true
        }
        return ChatInteractionTrace.State(
            presentationEpoch: sessionPresentation.open.epoch,
            layoutEpoch: scrollCoordinator.layoutEpoch,
            layoutGeneration: layoutTransaction.generation?.id,
            canonicalRows: installed?.timeline.items.count,
            runtimeRows: installed?.runtimeItems.count,
            queueRows: installed?.queuedMessages.count,
            hasLifecycleRow: hasLifecycleRow,
            viewportMode: scrollCoordinator.viewportMode,
            isUserInteracting: scrollCoordinator.isUserInteracting,
            isPositionedByUser: transcriptScrollPosition.isPositionedByUser,
            distanceFromBottom: geometry.isValid ? geometry.distanceFromBottom : nil,
            offsetY: geometry.isValid ? geometry.offsetY : nil,
            contentHeight: geometry.isValid ? geometry.contentHeight : nil,
            containerHeight: geometry.isValid ? geometry.containerHeight : nil,
            bottomInset: geometry.isValid ? geometry.bottomInset : nil,
            isPastBottomEdge: geometry.isValid ? geometry.isPastBottomEdge : nil,
            tailClassification: scrollCoordinator.physicalTailEvidence?.classification,
            tailDisplacement: scrollCoordinator.physicalTailEvidence?.signedDisplacement,
            hasCommand: scrollCoordinator.command != nil,
            hasAppliedTarget: scrollCoordinator.hasAppliedTargetLease,
            hasPendingRelease: scrollCoordinator.hasPendingTargetRelease
        )
    }

    private var totalInteractionTraceRows: Int {
        guard let installed = transcriptPresentation.installed else { return 0 }
        let lifecycleCount: Int = if case .none = installed.handoff { 0 } else { 1 }
        return installed.timeline.items.count
            + installed.runtimeItems.count
            + installed.queuedMessages.count
            + lifecycleCount
    }

    private func scheduleOpeningTraceCheckpoints(
        context: Int,
        epoch: Int,
        expectedVisibleRows: Int
    ) {
        Task { @MainActor in
            for delay in [Duration.milliseconds(350), .milliseconds(1_250)] {
                do { try await Task.sleep(for: delay); try Task.checkCancellation() }
                catch { return }
                guard interactionTraceLedger.ownsContext(context),
                      sessionPresentation.open.epoch == epoch,
                      sessionPresentation.open.phase == .ready else { return }
                let state = interactionTraceState()
                model.chatInteractionTrace.geometry(
                    .openingCheckpoint,
                    context: context,
                    state: state
                )
                if ChatInteractionAnomalyPolicy.lostProjection(
                    expectedRows: expectedVisibleRows,
                    currentRows: totalInteractionTraceRows
                ) {
                    model.chatInteractionTrace.anomaly(
                        .openingLostProjection,
                        context: context,
                        state: state
                    )
                    continue
                }
                if ChatInteractionAnomalyPolicy.displacedPinnedViewport(
                    expectedPinned: true,
                    currentMode: scrollCoordinator.viewportMode,
                    isUserInteracting: scrollCoordinator.isUserInteracting,
                    isPositionedByUser: transcriptScrollPosition.isPositionedByUser,
                    geometry: scrollCoordinator.latestGeometry,
                    tailClassification: scrollCoordinator.physicalTailEvidence?.classification
                ) {
                    model.chatInteractionTrace.anomaly(
                        .openingViewportDisplaced,
                        context: context,
                        state: state
                    )
                }
            }
        }
    }

    private func reconcileSessionPresentationVisibility(
        sceneActive: Bool? = nil,
        surfaceActive: Bool? = nil
    ) {
        guard let target = presentationTarget else { return }
        let hasMountedAuthority = model.connectionState == .connected
            && model.hasMountedSessionAuthority(target)
        model.setSessionPresentationVisible(
            target,
            visible: ChatSessionVisibilityPolicy.isVisible(
                sceneActive: sceneActive ?? (scenePhase == .active),
                surfaceActive: surfaceActive
                    ?? presentationActivity.allowsDataPublication,
                hasMountedAuthority: hasMountedAuthority
            )
        )
    }

    private func automaticLiveProjectionIntakeChanged(deferred: Bool) {
        guard sessionPresentation.open.phase == .ready,
              presentationActivity.allowsDataPublication else { return }
        let context = ensureInteractionTraceContext()
        if deferred {
            // Direct reader ownership retires any derivation admitted while the
            // view was pinned. Keep the last complete commit physically fixed;
            // canonical SessionPresentationStore authority continues advancing.
            transcriptPresentation.suspendPendingWork()
            transcriptPresentation.discardPendingEntrances()
            model.chatInteractionTrace.projection(
                .deferred,
                context: context,
                state: interactionTraceState()
            )
        } else {
            model.chatInteractionTrace.projection(
                .resumed,
                context: context,
                state: interactionTraceState()
            )
            intakeLatestTranscriptProjectionIfNeeded()
        }
    }

    private func scenePhaseChanged(_ current: ScenePhase) {
        reconcileSessionPresentationVisibility(sceneActive: current == .active)
        if current == .background {
            viewportActivation &+= 1
            scrollCoordinator.viewportActivationChanged(viewportActivation)
            abandonLayoutTransaction()
            // Retire page/opening/correction tasks and native target leases;
            // durable pinned/detached intent remains in the coordinator.
            scrollCoordinator.cancel()
            // Background suspension retires disposable presentation work while
            // AppModel retains accepted uploads and submissions.
            sessionPresentation.suspendForBackground()
        } else if current == .active,
                  presentationActivity.allowsPresentationPublication {
            if admitsAutomaticOpeningResume {
                // Foregrounding does not necessarily change connection state or
                // publish a reconciliation generation. Resume explicitly instead
                // of waiting for an unrelated model event.
                beginOpeningAfterForegroundWhenConnected()
            } else {
                scrollCoordinator.foregroundViewportBecameActive(
                    activation: viewportActivation
                )
                intakeLatestTranscriptProjectionIfNeeded()
            }
        }
    }

    private func foregroundReconciliationCompleted() {
        reconcileSessionPresentationVisibility()
        guard scenePhase == .active,
              presentationActivity.allowsPresentationPublication else { return }
        if admitsAutomaticOpeningResume {
            beginOpeningAfterForegroundWhenConnected()
        } else {
            scrollCoordinator.foregroundViewportBecameActive(
                activation: viewportActivation
            )
        }
    }

    private func retirePresentation() {
        let traceContext = interactionTraceLedger.context
        if let target = presentationTarget {
            model.setSessionPresentationVisible(target, visible: false)
            model.revokePresentationIntake(target)
        }
        sessionPresentation.suspendForBackground()
        scrollCoordinator.cancel()
        abandonLayoutTransaction()
        _ = composerResponder.resignFirstResponder()
        keyboardObserver.stop()
        transcriptPresentation.reset()
        sessionPresentation.earlierMessagesOperation.cancel()
        sessionPresentation.canonicalSubmissionHandoffs.removeAll()
        sessionPresentation.canonicalSubmissionAliases.removeAll()
        retireQueueMutationPresentationState()
        performanceTracker.cancelAll()
        if let generation = sessionPresentation.modelPresentationGeneration {
            Task { await model.closeSessionPresentation(sessionID, generation: generation) }
        }
        if let traceContext {
            model.chatInteractionTrace.endContext(traceContext)
            interactionTraceLedger.retire()
        }
    }

    private func abandonLayoutTransaction() {
        layoutTransaction.abandon()
    }

    private func dismissComposerForAdmittedSubmission() {
        let keyboardRevision = keyboardObserver.revision
        // UIKit is the responder authority. Its synchronous keyboard frame
        // notification joins this exact layout generation when available.
        _ = composerResponder.resignFirstResponder()
        composerFocused = false
        layoutTransaction.configure(
            keyboard: keyboardObserver.transition,
            reduceMotion: reduceMotion
        )
        if keyboardObserver.transitionArrived(after: keyboardRevision) {
            _ = layoutTransaction.join(.keyboard)
        }
        // Resolve one clock after the keyboard participant has had its
        // synchronous admission opportunity. Every submission height owner
        // reads this frozen value.
        _ = layoutTransaction.animation
    }

    /// Keep the pre-cover baseline until the latest complete source installs.
    /// Lazy estimates can otherwise leave a pinned uncover at an empty tail:
    /// suppressed entrances do not trigger ordinary new-row materialization.
    private func reconcileDeferredViewportProjectionIfNeeded() {
        guard hasDeferredViewportProjection else { return }
        let baseline = deferredViewportProjectionBaseline
        let installed = transcriptPresentation.installed
        if baseline?.tag == installed?.tag,
           let source = transcriptProjectionSource,
           source != installed?.tag { return }
        deferredViewportProjectionBaseline = nil
        hasDeferredViewportProjection = false
        guard baseline?.tag != installed?.tag else { return }
        if let baseline {
            scrollCoordinator.transcriptProjectionWillChange(from: baseline)
        }
        reconcileInstalledProjectionForViewport(
            previousTag: baseline?.tag,
            installed: installed
        )
        guard let installed, scrollCoordinator.canAutomaticallyFollow else { return }
        let rows = ChatPhysicalTranscriptRowPolicy.rows(
            installed: installed, canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
        )
        let previousTail = baseline.flatMap {
            ChatPhysicalTranscriptRowPolicy.rows(
                installed: $0, canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
            ).last
        }
        guard let tail = rows.last, tail.id != previousTail?.id else { return }
        // Reuse the exact native target/settlement lease; detached readers
        // never enter this path and no entrance animation is replayed.
        scrollCoordinator.discreteTailInserted(renderedID: tail.semanticID, physicalTargetID: tail.id)
    }

    private func reconcileInstalledProjectionForViewport(
        previousTag: ChatTranscriptProjectionTag?,
        installed: InstalledChatTranscript?
    ) {
        guard presentationActivity.allowsViewportObservation else { return }
        if let installed {
            for canonicalID in sessionPresentation.canonicalSubmissionHandoffs.ids
                where installed.containsDisplayedID(canonicalID) {
                transcriptPresentation.consumeTranscriptEntrance(id: canonicalID)
                if let physicalID = sessionPresentation.canonicalSubmissionAliases.aliases[canonicalID] {
                    scrollCoordinator.canonicalPromptAcknowledged(
                        physicalID: physicalID, semanticID: canonicalID
                    )
                }
            }
        }
        let semanticIDsByPhysicalID = installed.map {
            ChatPhysicalTranscriptRowPolicy.semanticIDsByPhysicalID(
                installed: $0,
                canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
            )
        } ?? [:]
        let physicalRowPositions: [String: Int] = installed.map {
            let rows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: $0,
                canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
            )
            let hasEarlierMessages = ($0.sourceWindow.originalStart ?? 0) > 0
            var positions = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                ($0.element.id, $0.offset + (hasEarlierMessages ? 1 : 0))
            })
            if hasEarlierMessages { positions["earlier-messages"] = 0 }
            return positions
        } ?? [:]
        let physicalTerminalPosition: Int? = installed.flatMap {
            let rows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: $0,
                canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
            )
            let leadingEarlierRow = ($0.sourceWindow.originalStart ?? 0) > 0 ? 1 : 0
            return rows.indices.last.map { $0 + leadingEarlierRow }
                ?? (leadingEarlierRow > 0 ? 0 : nil)
        }
        let terminalPhysicalID = installed.flatMap {
            let rows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: $0,
                canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
            )
            if let terminal = rows.last { return terminal.id }
            return ($0.sourceWindow.originalStart ?? 0) > 0 ? "earlier-messages" : nil
        }
        // Keep the native physical target while transferring its geometry
        // owner atomically with prompt/tool payload replacement.
        scrollCoordinator.reconcileMaterializationRows { physicalID in
            semanticIDsByPhysicalID[physicalID]
        }
        let projectionLayoutChanged = previousTag.map { previousTag in
            installed.map { !previousTag.matchesProjectionPayload(of: $0.tag) } ?? true
        } ?? true
        let physicalProjectionChanged = projectionLayoutChanged || (previousTag.map { previous in
            guard let installed else { return true }
            return previous.handoffIdentity != installed.tag.handoffIdentity
        } ?? true)
        if physicalProjectionChanged {
            // The coordinator advances its semantic epoch only when this
            // installed commit changes the physical row spine. Streaming text
            // and shallow tool-state updates keep current hosts and evidence.
            scrollCoordinator.projectionInstalled(
                structure: installed?.physicalRowSpineIdentity,
                terminalPhysicalID: terminalPhysicalID,
                projectionTag: installed?.tag,
                physicalRowPositions: physicalRowPositions,
                physicalTerminalPosition: physicalTerminalPosition
            )
        }
        if projectionLayoutChanged {
            scrollCoordinator.installedTranscriptChanged(installed)
        }
    }

    private func settleTranscriptEntrance(renderedID: String) {
        guard let active = layoutTransaction.generation,
              active.joined.contains(.transcriptGrowth),
              !active.settled.contains(.transcriptGrowth),
              let generation = scrollCoordinator.layoutTransactionForSettledEntrance(
                renderedID: renderedID
              ) else { return }
        layoutTransaction.settle(generation, source: .transcriptGrowth)
    }

    private func composerHeightChanged(_ height: CGFloat) {
        guard height.isFinite, height >= 0 else { return }
        // Live structural animation samples must not invalidate the entire
        // transcript tree. The non-observable ledger is read only by bounded
        // layout settlement and submission admission callbacks.
        composerHeightLedger.install(height)
        #if HOSTED_TEST
        hostedProbe?.recordComposerHeight(height)
        #endif
    }

    private func composerHeightSettled(_ height: CGFloat) {
        guard height.isFinite, height >= 0,
              let generation = layoutTransaction.generation?.id else { return }
        Task { @MainActor in
            do { try await displayFrameScheduler.nextFrame() }
            catch { return }
            guard layoutTransaction.generation?.id == generation,
                  abs(composerHeightLedger.current - height)
                    <= ChatComposerStructuralTransitionPolicy.heightEpsilon else { return }
            layoutTransaction.settle(generation, source: .submission)
        }
    }

    private func rememberCanonicalSubmissionHandoffs(_ ids: Set<String>) {
        sessionPresentation.canonicalSubmissionHandoffs.formUnion(ids)
    }

    private func rememberCanonicalSubmissionAlias(
        canonicalID: String,
        presentationID: String
    ) {
        guard sessionPresentation.canonicalSubmissionAliases.insert(
            canonicalID: canonicalID,
            presentationID: presentationID
        ), let context = interactionTraceLedger.context,
           interactionTraceLedger.ownsContext(context) else { return }
        var state = interactionTraceState()
        state.physicalRowToken = model.chatInteractionTrace.identityToken(presentationID)
        state.semanticRowToken = model.chatInteractionTrace.identityToken(canonicalID)
        model.chatInteractionTrace.lease(
            .canonicalHandoff, context: context, token: nil,
            reason: .canonicalAcknowledgement, state: state
        )
    }

    /// Keeps the installed queue boundary visible while a local queue command
    /// decides whether a simultaneous canonical row consumed that operation or
    /// is unrelated. Once deferral starts, newer complete captures coalesce here
    /// until the one in-flight command resolves.
    @MainActor
    private func deferQueueMutationProjectionIfNeeded(
        _ capture: ChatTranscriptProjectionCapture
    ) -> Bool {
        guard sessionPresentation.queueMutationCommandIsPending,
              !sessionPresentation.locallyMutatedQueueOperationIDs.isEmpty else { return false }
        if sessionPresentation.deferredQueueMutationProjection != nil {
            sessionPresentation.deferredQueueMutationProjection = capture
            return true
        }
        guard let installed = transcriptPresentation.installed else { return false }
        let snapshot = capture.snapshot
        let receiptOperationID = presentationTarget.flatMap { target in
            model.composerDrafts.canonicalSubmissionHandoff(target: target).flatMap { receipt in
                snapshot.transcript.contains(where: { $0.id == receipt.canonicalID })
                    ? receipt.operationID
                    : nil
            }
        }
        let fallbackWithoutExclusions = ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: installed.queuedMessages,
            incomingQueue: snapshot.displayedQueuedMessages,
            previousCanonicalIDs: previousCanonicalIDs(in: installed),
            previousSourceWindow: installed.sourceWindow,
            incomingSourceWindow: .init(snapshot: snapshot),
            incomingTranscript: snapshot.transcript
        )
        let fallbackWithExclusions = ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
            previousQueue: installed.queuedMessages,
            incomingQueue: snapshot.displayedQueuedMessages,
            excludedOperationIDs: sessionPresentation.locallyMutatedQueueOperationIDs,
            previousCanonicalIDs: previousCanonicalIDs(in: installed),
            previousSourceWindow: installed.sourceWindow,
            incomingSourceWindow: .init(snapshot: snapshot),
            incomingTranscript: snapshot.transcript
        )
        guard ChatQueueMutationProjectionPolicy.shouldDefer(
            affectedOperationIDs: sessionPresentation.locallyMutatedQueueOperationIDs,
            receiptOperationID: receiptOperationID,
            fallbackHandoffWithoutExclusions: fallbackWithoutExclusions,
            fallbackHandoffWithExclusions: fallbackWithExclusions
        ) else { return false }
        sessionPresentation.deferredQueueMutationProjection = capture
        return true
    }

    @MainActor
    private func resolveDeferredQueueMutationProjection() {
        guard let capture = sessionPresentation.deferredQueueMutationProjection else { return }
        sessionPresentation.deferredQueueMutationProjection = nil
        guard capture.tag.presentationGeneration == sessionPresentation.modelPresentationGeneration,
              transcriptProjectionSource == capture.tag else { return }
        intakeTranscriptProjection(capture, permitsQueueMutationDeferral: false)
    }

    @MainActor
    private func clearSettledQueueMutationPresentationState() {
        sessionPresentation.pendingQueueMutationRevision = nil
        sessionPresentation.mutatingQueuedMessageIDs.removeAll()
        sessionPresentation.locallyMutatedQueueOperationIDs.removeAll()
    }

    @MainActor
    private func retireQueueMutationPresentationState() {
        sessionPresentation.queueMutationResolution.retire()
        sessionPresentation.mutatingQueuedMessageIDs.removeAll()
        sessionPresentation.pendingQueueMutationRevision = nil
        sessionPresentation.locallyMutatedQueueOperationIDs.removeAll()
        sessionPresentation.deferredQueueMutationProjection = nil
        sessionPresentation.queueMutationCommandIsPending = false
    }

    @MainActor
    private func intakeTranscriptProjection(
        _ capture: ChatTranscriptProjectionCapture,
        permitsQueueMutationDeferral: Bool = true
    ) {
        guard presentationActivity.allowsPresentationPublication,
              !scrollCoordinator.defersAutomaticLiveProjectionIntake,
              !scrollCoordinator.isPrependingHistory,
              capture.tag.presentationGeneration == sessionPresentation.modelPresentationGeneration,
              transcriptProjectionSource == capture.tag else { return }
        if permitsQueueMutationDeferral,
           deferQueueMutationProjectionIfNeeded(capture) {
            return
        }

        let currentSource = capture.tag
        let snapshot = capture.snapshot
        if let target = presentationTarget {
            var canonicalHandoffIDs = model.composerDrafts.canonicalSubmissionIDs(
                target: target,
                canonicalTranscript: snapshot.transcript
            )
            if canonicalHandoffIDs.count == 1,
               let canonicalID = canonicalHandoffIDs.first {
                seedCanonicalMediaPreviews(
                    from: CanonicalSubmissionHandoffReceipt(
                        canonicalID: canonicalID,
                        attachments: model.composerDrafts.submittedAttachments(for: target)
                            .map { $0.frozenForHandoff() }
                    ),
                    in: snapshot
                )
            }
            if let pendingReceipt = model.composerDrafts.canonicalSubmissionHandoff(target: target),
               snapshot.transcript.contains(where: { $0.id == pendingReceipt.canonicalID }),
               pendingReceipt.operationID.map({ sessionPresentation.locallyMutatedQueueOperationIDs.contains($0) }) != true,
               let receipt = model.composerDrafts.consumeCanonicalSubmissionHandoff(target: target) {
                canonicalHandoffIDs.insert(receipt.canonicalID)
                if let alias = ChatCanonicalSubmissionAliasPolicy.alias(
                    for: receipt,
                    in: snapshot.transcript
                ) {
                    rememberCanonicalSubmissionAlias(
                        canonicalID: alias.canonicalID,
                        presentationID: alias.presentationID
                    )
                }
                seedCanonicalMediaPreviews(from: receipt, in: snapshot)
            }
            rememberCanonicalSubmissionHandoffs(canonicalHandoffIDs)
        }
        let installedBeforeSubmission = transcriptPresentation.installed
        if let installedBeforeSubmission,
           let canonicalHandoffID = ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
               previousQueue: installedBeforeSubmission.queuedMessages,
               incomingQueue: snapshot.displayedQueuedMessages,
               excludedOperationIDs: sessionPresentation.locallyMutatedQueueOperationIDs,
               previousCanonicalIDs: previousCanonicalIDs(in: installedBeforeSubmission),
               previousSourceWindow: installedBeforeSubmission.sourceWindow,
               incomingSourceWindow: .init(snapshot: snapshot),
               incomingTranscript: snapshot.transcript
           ) {
            rememberCanonicalSubmissionHandoffs([canonicalHandoffID])
        }
        if let previousPending = installedBeforeSubmission?.handoff.pendingPromptPresentation {
            // Match the installed pending handoff against incoming canonical
            // facts so replacement consumes the original entrance entitlement.
            let pendingCanonicalIDs = ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
                for: previousPending,
                in: snapshot.transcript
            )
            rememberCanonicalSubmissionHandoffs(pendingCanonicalIDs)
            if let canonicalID = ChatPendingCanonicalSuppressionPolicy.exactCanonicalID(
                for: previousPending,
                in: snapshot.transcript
            ) {
                rememberCanonicalSubmissionAlias(
                    canonicalID: canonicalID,
                    presentationID: "pending-prompt-\(previousPending.id)"
                )
            }
            if previousPending.promptBehavior.isQueuedKind,
               ChatPromptLifecycleTransitionPolicy.suppressesQueueReplacement(
                   pendingOperationID: previousPending.id,
                   authoritativeQueueIDs: Set(snapshot.displayedQueuedMessages.map(\.id))
               ) {
                rememberCanonicalSubmissionHandoffs(["queued-message-\(previousPending.id)"])
            }
        }
        // Projection intake remains live during prepend. The scroll owner
        // preserves the exact anchor, while this store coalesces to the newest
        // complete desired commit.
        if !presentationActivity.allowsViewportObservation,
           !hasDeferredViewportProjection {
            deferredViewportProjectionBaseline = installedBeforeSubmission
            hasDeferredViewportProjection = true
        }
        let startedWork = transcriptPresentation.submit(
            snapshot: snapshot,
            handoff: capture.handoff,
            queuePresentationIDByOperationID: capture.queuePresentationIDByOperationID,
            tag: currentSource
        )
        if startedWork, presentationActivity.allowsViewportObservation {
            scrollCoordinator.transcriptProjectionWillChange(from: installedBeforeSubmission)
        }
        #if HOSTED_TEST
        hostedProbe?.recordProjectionSubmit(startedWork: startedWork)
        #endif
    }

    private func seedCanonicalMediaPreviews(
        from receipt: CanonicalSubmissionHandoffReceipt,
        in snapshot: SessionSnapshot
    ) {
        guard let canonicalItem = snapshot.transcript.first(where: {
            $0.id == receipt.canonicalID
        }) else { return }
        for seed in ChatCanonicalMediaPreviewPolicy.seeds(
            attachments: receipt.attachments,
            canonicalItem: canonicalItem
        ) {
            guard let identity = model.chatMediaIdentity(blobID: seed.blobID),
                  let prepared = seed.attachment.preparedThumbnail else { continue }
            try? model.chatMedia.seedPreparedThumbnail(prepared, for: identity)
        }
    }

    private func previousCanonicalIDs(in installed: InstalledChatTranscript) -> Set<String> {
        Set(installed.timeline.items.compactMap { item in
            switch item {
            case .transcript(let transcript): return transcript.id
            case .message(let message): return message.semanticID
            case .toolRun, .notification: return nil
            }
        })
    }

    private var topBlur: some View {
        TronTopBlurOverlay(style: .chat)
    }

    private var transcript: some View {
        ChatTranscriptScrollView(
            transcriptPresentation: transcriptPresentation,
            scrollCoordinator: scrollCoordinator,
            performanceTracker: performanceTracker,
            installed: transcriptPresentation.installed,
            canonicalSubmissionIDs: sessionPresentation.canonicalSubmissionHandoffs.ids,
            canonicalSubmissionAliases: sessionPresentation.canonicalSubmissionAliases.aliases,
            isReady: isTranscriptReady,
            hasSettledOpeningOffset: hasSettledOpeningOffset,
            permitsAsynchronousContent: scrollCoordinator.permitsAsynchronousTranscriptContent,
            frameScheduler: displayFrameScheduler,
            reduceMotion: reduceMotion,
            presentationEpoch: sessionPresentation.open.epoch,
            viewportActivation: viewportActivation,
            presentationPhase: sessionPresentation.open.phase,
            admitsGeometryCallbacks: admitsScrollGeometryCallbacks,
            admitsNativeCallbacks: admitsNativeScrollCallbacks,
            responseState: responseState,
            mutatingQueuedMessageIDs: sessionPresentation.mutatingQueuedMessageIDs,
            scrollPosition: $transcriptScrollPosition,
            earlierRow: { installed in earlierMessagesChip(installed: installed) },
            openingSurface: { openingSurface },
            onEditQueuedMessage: { sessionPresentation.queuedMessageEditor = .init(id: $0) },
            onClearQueuedMessages: { Task { await clearQueuedMessages() } },
            onMoveQueuedMessage: { id, offset in
                Task { await moveQueuedMessage(id, offset: offset) }
            },
            onEntranceSettled: settleTranscriptEntrance,
            onAbandonLayout: abandonLayoutTransaction,
            onExecuteCommand: executePendingScrollCommand,
            onReleaseCommandTarget: releaseScrollPositionTarget,
            onApplyViewportMode: applyViewportMode,
            onAutomaticProjectionIntakeAvailable: intakeLatestTranscriptProjectionIfNeeded,
            hostedRecorder: transcriptHostedRecorder
        )
    }

    private var transcriptHostedRecorder: (any ChatTranscriptHostedRecording)? {
        #if HOSTED_TEST
        hostedProbe
        #else
        nil
        #endif
    }

    @ViewBuilder
    private var activeProjectionObservationDriver: some View {
        ZStack {
            if presentationActivity.allowsPresentationPublication {
                Color.clear
                    .onChange(of: pendingInteractionScopes, initial: true) { _, _ in
                        reconcileInteractionDraftsIfAuthoritative()
                        sessionPresentation.reconcileInteractionPresentation(
                            with: selectedAuthoritativeSnapshot?.extensionPresentation.pendingInteractions ?? []
                        )
                    }
                    .onChange(of: initialModelSettled) { _, _ in
                        reconcileInteractionDraftsIfAuthoritative()
                    }
                    .onChange(of: model.connectionState) { _, _ in
                        reconcileInteractionDraftsIfAuthoritative()
                    }
            }
            if presentationActivity.allowsPresentationPublication,
               !scrollCoordinator.defersAutomaticLiveProjectionIntake {
                Color.clear
                    .onChange(of: transcriptProjectionSource, initial: true) { _, source in
                        guard sessionPresentation.permitsExtensionInteractionPresentation else {
                            // Opening installs one complete captured source directly.
                            // Churn is coalesced after the first ready frame instead
                            // of repeatedly superseding the opaque opening build.
                            return
                        }
                        guard !scrollCoordinator.isPrependingHistory else {
                            // The exact page window owns this projection transaction.
                            // Current authority remains available and is coalesced
                            // immediately when semantic restoration terminates.
                            return
                        }
                        guard let capture = transcriptProjectionCapture else {
                            // A recycled same-session owner can briefly have no exact
                            // generation while the retained canonical snapshot is still
                            // valid. Keep the mounted projection until its replacement
                            // installs; only a genuinely absent session clears the view.
                            if selectedAuthoritativeSnapshot == nil { transcriptPresentation.reset() }
                            return
                        }
                        // Ignore a callback captured before opening installed its mounted
                        // generation; the newer exact source owns submission.
                        guard source == capture.tag,
                              !scrollCoordinator.blocksAutomaticLiveProjectionIntake else { return }
                        intakeTranscriptProjection(capture)
                    }
            } else if presentationActivity.allowsDataPublication {
                // Detached readers observe only a scalar canonical revision.
                // The immutable installed commit remains untouched until manual
                // tail return or catch-up settlement re-enables projection intake.
                Color.clear
                    .onChange(of: deferredLiveProjectionRevision) { previous, current in
                        guard previous != nil, current != nil, previous != current else { return }
                        scrollCoordinator.semanticResponseArrived()
                    }
            }
        }
    }

    private var selectedAuthoritativeSnapshot: SessionSnapshot? {
        model.authoritativeSnapshot(for: sessionID)
    }

    /// Visible chrome advances with the exact immutable transcript commit.
    /// Command admission and draft ownership still read canonical owners.
    private var visibleSessionFacts: ChatVisibleSessionFacts? {
        transcriptPresentation.installed?.tag.layoutIdentity.visibleSessionFacts
    }

    private var showsAmbientWorkingBlur: Bool {
        guard let facts = visibleSessionFacts else { return false }
        return ChatRuntimeWorkingPresentation(
            phase: facts.phase
        )?.usesAmbientBottomIndicator == true
    }

    private var presentationTarget: AppModel.SessionPresentationTarget? {
        sessionPresentation.modelPresentationGeneration.map {
            AppModel.SessionPresentationTarget(sessionID: sessionID, generation: $0)
        }
    }

    /// A disconnected Gateway must not revoke the installed commit. Once a
    /// Gateway reports a capability again, its exact fact becomes part of the
    /// next desired commit and is published atomically with that transcript.
    private var queueManagementCapabilityForProjection: Bool {
        guard let gatewayInfo = model.gatewayInfo else {
            return transcriptPresentation.installed?.tag.queueManagementCapability ?? false
        }
        return gatewayInfo.capabilities.contains(QueuedMessageManagementPolicy.capability)
    }

    private struct DeferredLiveProjectionRevision: Equatable {
        let presentationGeneration: Int
        let timelineGeneration: Int
    }

    private var deferredLiveProjectionRevision: DeferredLiveProjectionRevision? {
        guard let generation = sessionPresentation.modelPresentationGeneration,
              let projection = model.chatProjectionGenerations(
                for: sessionID,
                presentationGeneration: generation
              ) else { return nil }
        return DeferredLiveProjectionRevision(
            presentationGeneration: generation,
            timelineGeneration: projection.timeline
        )
    }

    private var transcriptProjectionCapture: ChatTranscriptProjectionCapture? {
        // Foreground synchronization is one aggregate admission. Keep the last
        // complete projection visible until that aggregate succeeds or fails;
        // otherwise an intermediate unsuppressed snapshot can animate backlog.
        let freezesMountedAggregate = model.isReconcilingForeground
            && sessionPresentation.open.phase == .ready
        guard !freezesMountedAggregate,
              let snapshot = model.transcriptSnapshot(for: sessionID),
              let generation = sessionPresentation.modelPresentationGeneration,
              let projection = model.chatProjectionGenerations(
                for: sessionID,
                presentationGeneration: generation
              ),
              snapshot.sessionId == sessionID else { return nil }
        let authority = selectedAuthoritativeSnapshot
        let handoff = transcriptHandoffCommit(snapshot: snapshot)
        let queuePresentationIDs = presentationTarget.map { target in
            model.composerDrafts.queuedSubmissionPresentationIDs(
                target: target,
                queuedMessages: snapshot.displayedQueuedMessages
            )
        } ?? [:]
        let tag = ChatTranscriptProjectionTag(
            snapshot: snapshot,
            authoritySnapshot: authority,
            presentationGeneration: generation,
            canonicalGeneration: projection.canonical,
            timelineGeneration: projection.timeline,
            // Do not let the retained projection consume the foreground token
            // while reconciliation is still in flight. AppModel advances this
            // generation only after the mounted aggregate succeeds.
            entranceSuppressionGeneration: model.isReconcilingForeground
                || model.foregroundReconciliationGeneration == 0
                ? nil
                : model.foregroundReconciliationGeneration,
            queueManagementCapability: queueManagementCapabilityForProjection,
            handoff: handoff,
            queuePresentationIDByOperationID: queuePresentationIDs
        )
        return ChatTranscriptProjectionCapture(
            snapshot: snapshot,
            handoff: handoff,
            queuePresentationIDByOperationID: queuePresentationIDs,
            tag: tag
        )
    }

    private var transcriptProjectionSource: ChatTranscriptProjectionTag? {
        transcriptProjectionCapture?.tag
    }

    private enum TranscriptInstallConsistency {
        case exactCurrentSource
        case firstCompletePresentationCommit
        case firstCompleteTranscriptWindow
    }

    @MainActor
    private func installCurrentTranscriptProjection(
        presentationGeneration: Int,
        consistency: TranscriptInstallConsistency = .exactCurrentSource
    ) async throws -> InstalledChatTranscript {
        var attemptedInvalidProjectionRecovery = false
        while true {
            try Task.checkCancellation()
            guard sessionPresentation.modelPresentationGeneration == presentationGeneration,
                  let capture = transcriptProjectionCapture,
                  capture.tag.presentationGeneration == presentationGeneration else {
                throw CancellationError()
            }
            let snapshot = capture.snapshot
            let tag = capture.tag
            if deferQueueMutationProjectionIfNeeded(capture) {
                guard let token = sessionPresentation.queueMutationResolution.activeToken else { continue }
                let resolution = try await sessionPresentation.queueMutationResolution.wait(for: token)
                guard resolution == .commandCompleted else { throw CancellationError() }
                continue
            }
            guard presentationActivity.allowsPresentationPublication else {
                throw CancellationError()
            }
            do {
                let startedWork = transcriptPresentation.submit(
                    snapshot: snapshot,
                    handoff: capture.handoff,
                    queuePresentationIDByOperationID: capture.queuePresentationIDByOperationID,
                    tag: tag
                )
                guard startedWork || transcriptPresentation.hasInstallWork(for: tag) else {
                    // A rejected source cannot satisfy a waiter. Fail closed so
                    // this exact capture receives one bounded authoritative
                    // recovery instead of spinning on `.superseded`.
                    throw ChatTranscriptPresentationStoreError.invalidProjection
                }
                let installed = try await transcriptPresentation.waitForInstall(of: tag)
                guard presentationActivity.allowsPresentationPublication,
                      sessionPresentation.modelPresentationGeneration == presentationGeneration else {
                    throw CancellationError()
                }
                let desiredCapture = transcriptProjectionCapture
                if desiredCapture?.tag == tag,
                   desiredCapture?.handoff == capture.handoff {
                    return installed
                }
                if consistency == .firstCompletePresentationCommit,
                   ChatProjectionTransactionAdmissionPolicy.admitsOpening(
                       installed: tag,
                       desired: desiredCapture?.tag
                   ) {
                    // Authority may stream while opening. The first complete
                    // same-presentation/runtime commit is safe to reveal; the
                    // newest source is submitted after the first ready frame.
                    return installed
                }
                if consistency == .firstCompleteTranscriptWindow,
                   ChatProjectionTransactionAdmissionPolicy.admitsTranscriptWindow(
                       installed: tag,
                       desired: desiredCapture?.tag,
                       desiredTranscript: desiredCapture?.snapshot.transcript
                   ) {
                    return installed
                }
            } catch ChatTranscriptPresentationStoreError.superseded {
                continue
            } catch ChatTranscriptPresentationStoreError.invalidProjection {
                guard !attemptedInvalidProjectionRecovery else {
                    throw ChatTranscriptPresentationStoreError.invalidProjection
                }
                attemptedInvalidProjectionRecovery = true
                try await model.resynchronizeSessionPresentation(
                    sessionID,
                    generation: presentationGeneration
                )
                continue
            }
        }
    }

    private func installedCommitBelongsToCurrentPresentation(
        _ installed: InstalledChatTranscript,
        generation: Int
    ) -> Bool {
        guard installed.tag.sessionID == sessionID,
              installed.tag.presentationGeneration == generation else { return false }
        return ChatProjectionTransactionAdmissionPolicy.admitsOpening(
            installed: installed.tag,
            desired: transcriptProjectionSource
        )
    }

    private var composerText: String {
        composerScope.map(model.composerDrafts.text(for:)) ?? ""
    }

    private var composerTextBinding: Binding<String> {
        Binding(
            get: { composerText },
            set: { value in
                guard let composerScope else { return }
                model.composerDrafts.setText(value, for: composerScope)
                if selectedAuthoritativeSnapshot?.extensionPresentation.hostEpoch.isEmpty == false,
                   let presentationTarget {
                    model.scheduleExtensionEditorUpdate(target: presentationTarget, text: value)
                }
            }
        )
    }

    /// Read-through owner version used by the UIKit bridge during callback-turn
    /// races. Unlike a rendered Int value, this binding observes the coordinator
    /// synchronously before SwiftUI has produced the next representable update.
    private var composerTextRevisionBinding: Binding<ComposerTextAuthority> {
        // Capture the State location and coordinator reference, not this render's
        // scalar scope/revision values. A delegate callback that precedes the
        // next updateUIView therefore still reads the current draft owner.
        let liveScope = $composerScope
        let drafts = model.composerDrafts
        return Binding(
            get: {
                let scope = liveScope.wrappedValue
                return ComposerTextAuthority(
                    scope: scope,
                    revision: scope.map { drafts.revision(for: $0) } ?? 0
                )
            },
            set: { _ in }
        )
    }

    private var pendingAttachments: [PendingAttachment] {
        guard let target = presentationTarget else { return [] }
        let submittedIDs = Set(
            model.composerDrafts.submittedAttachments(for: target).map(\.id)
        )
        return model.composerDrafts.pendingAttachments(for: target)
            .filter { !submittedIDs.contains($0.id) }
    }

    private func reconcileInteractionDraftsIfAuthoritative() {
        guard initialModelSettled,
              model.connectionState == .connected,
              let snapshot = selectedAuthoritativeSnapshot else { return }
        model.extensionInteractionDrafts.reconcile(
            sessionID: sessionID,
            pendingInteractions: snapshot.extensionPresentation.pendingInteractions
        )
    }

    private var submittedAttachments: [PendingAttachment] {
        presentationTarget.map(model.composerDrafts.submittedAttachments(for:)) ?? []
    }

    private var selectedComposerResource: ComposerResourceEntry? {
        guard let composerScope,
              let command = model.composerDrafts.selectedResource(for: composerScope) else { return nil }
        return ComposerResourceEntry(command: command)
    }

    private var candidatePresentedInteraction: ExtensionInteraction? {
        ChatExtensionInteractionPolicy.presentedInteraction(
            selectedAuthoritativeSnapshot?.extensionPresentation.pendingInteractions ?? [],
            requested: sessionPresentation.requestedInteractionScope,
            suppressing: sessionPresentation.suppressedInteractionScope
        )
    }

    private var candidateEditorRequest: ComposerEditorRequest? {
        guard let target = presentationTarget else { return nil }
        return model.composerDrafts.editorRequest(for: target)
    }

    private var extensionForegroundPresentation: ChatExtensionForegroundPresentation {
        ChatExtensionPresentationArbiter.presentation(
            modelSettled: initialModelSettled,
            presentationReady: sessionPresentation.permitsExtensionInteractionPresentation,
            hasInteraction: candidatePresentedInteraction != nil,
            hasEditorRequest: candidateEditorRequest != nil
        )
    }

    /// Interactive extension prompts and editors retain foreground priority.
    /// The unified activity sheet resumes after those leased routes settle and
    /// owns both process and retained-extension presentation.
    /// Foreground extension interactions retain priority over this read-only route.
    private var activityPresentationBinding: Binding<Bool> {
        Binding(
            get: { sessionPresentation.showActivity && extensionForegroundPresentation == .none },
            set: { presented in
                if !presented { sessionPresentation.showActivity = false }
            }
        )
    }

    /// Retained extension content is derived from the authoritative snapshot on
    /// every render; it never polls and never opens provider work. The sheet
    /// receives this value, so widget updates replace its content in place
    /// without recreating the sheet or resetting its scroll position.
    private var extensionRetainedContent: ExtensionRetainedContent {
        let presentation = selectedAuthoritativeSnapshot?.extensionPresentation
        return ExtensionRetainedContentPolicy.content(
            widgets: presentation?.semanticState.widgets,
            surfaces: presentation?.surfaces,
            statuses: presentation?.semanticState.statuses,
            statusOwners: presentation?.semanticState.statusOwners
        )
    }

    /// A partial projection must say so rather than implying completeness.
    private var omittedExtensionContentCount: Int {
        let presentation = selectedAuthoritativeSnapshot?.extensionPresentation
        guard presentation?.projection?.complete == false else { return 0 }
        let omitted = presentation?.projection?.omitted ?? []
        return omitted.isEmpty ? 0 : omitted.count
    }

    private var pendingPresentedInteraction: ExtensionInteraction? {
        extensionForegroundPresentation == .interaction ? candidatePresentedInteraction : nil
    }

    private var routedEditorRequest: ComposerEditorRequest? {
        extensionForegroundPresentation == .editorRequest ? candidateEditorRequest : nil
    }

    private var sending: Bool {
        presentationTarget.map(model.composerDrafts.isSending(target:)) ?? false
    }

    private var hasActiveComposerUploads: Bool {
        presentationTarget.map(model.composerDrafts.hasActiveUploads(for:)) ?? false
    }

    /// Cheap rendered admission shared with the send action. The action repeats
    /// the authority checks after capturing invocation intent before mutation.
    private var admitsLiveSessionCommands: Bool {
        // openingTask is intentionally ignored by Observation; its revision is
        // the published fence that re-evaluates this rendered admission.
        _ = sessionPresentation.openingTaskRevision
        guard !model.isReconcilingForeground,
              sessionPresentation.openingTask == nil,
              sessionPresentation.open.phase == .ready,
              scrollCoordinator.admitsSubmission,
              scrollCoordinator.command == nil,
              !submissionPending,
              let target = presentationTarget,
              let installed = transcriptPresentation.installed,
              installed.tag.sessionID == sessionID,
              model.chatProjectionGenerations(for: sessionID, presentationGeneration: target.generation) != nil,
              model.authoritativeSnapshot(for: sessionID)?.sessionId == sessionID,
              sessionPresentation.modelPresentationGeneration == target.generation else { return false }
        return model.admitsLiveSessionCommands(target)
    }

    private var composerAvailability: ChatInteractionTrace.Availability {
        _ = sessionPresentation.openingTaskRevision
        let target = presentationTarget
        let activity = composerCatalogActivity
        return ChatInteractionTrace.Availability(
            connected: model.connectionState == .connected,
            reconciling: model.isReconcilingForeground,
            mountedAuthority: target.map(model.hasMountedSessionAuthority) ?? false,
            projectionAvailable: target.map {
                transcriptPresentation.installed?.tag.sessionID == sessionID
                    && model.chatProjectionGenerations(for: sessionID, presentationGeneration: $0.generation) != nil
            } ?? false,
            openingTask: sessionPresentation.openingTask != nil,
            transcriptReady: isTranscriptReady,
            scrollAllowsSubmission: scrollCoordinator.admitsSubmission,
            scrollCommand: scrollCoordinator.command != nil,
            submissionPending: submissionPending,
            uploading: hasActiveComposerUploads,
            sending: sending,
            commandReady: admitsLiveSessionCommands,
            attachmentsReady: attachmentActionsEnabled,
            sceneActive: scenePhase == .active,
            viewportActive: activity.allowsViewportObservation,
            publicationActive: activity.allowsPresentationPublication
        )
    }

    private func recordComposerAvailability(blockedAction: Bool = false) {
        guard let context = interactionTraceLedger.context,
              interactionTraceLedger.ownsContext(context) else { return }
        model.chatInteractionTrace.availability(
            composerAvailability, context: context, blockedAction: blockedAction,
            state: interactionTraceState()
        )
    }

    /// Builds the complete handoff exactly once with the canonical snapshot.
    /// The resulting immutable value, not the live composer, is what enters the
    /// projection worker and the installed transcript.
    private func transcriptHandoffCommit(snapshot: SessionSnapshot) -> ChatTranscriptHandoffCommit {
        if let target = presentationTarget,
           let submission = model.composerDrafts.outgoingSubmission(for: target) {
            // Extension commands have no canonical user message. Their sole
            // transcript identity is the Gateway invocation-start receipt;
            // never hand the outgoing submission to the ordinary prompt graft,
            // even after the first projection has been skipped.
            if submission.resourceInvocation?.isExtensionCommand == true { return .none }
            let canonicalIDs = model.composerDrafts.canonicalSubmissionIDs(
                target: target,
                canonicalTranscript: snapshot.transcript
            )
            if canonicalIDs.isEmpty {
                if model.composerDrafts.hasQueuedSubmission(
                    target: target,
                    queuedMessages: snapshot.displayedQueuedMessages
                ) {
                    return .none
                }
                let attachments = model.composerDrafts.submittedAttachments(for: target)
                    .filter { attachment in
                        attachment.gatewayUploadID.map(submission.attachmentIDs.contains) == true
                    }
                    .prefix(ComposerAttachmentPolicy.maximumCount)
                    .map { $0.frozenForHandoff() }
                let preflightCompacting = snapshot.pendingPrompt.map {
                    model.composerDrafts.matchesPendingPrompt(target: target, pending: $0)
                        && (snapshot.phase == .compacting
                            || snapshot.operation?.kind == .compaction)
                } ?? false
                return .outgoing(
                    presentation: ChatOutgoingSubmissionPresentation(
                        snapshot: submission,
                        transportActive: model.composerDrafts.isSending(target: target),
                        preflightCompacting: preflightCompacting
                    ),
                    attachments: Array(attachments)
                )
            }
            return .none
        }
        guard let pending = snapshot.pendingPrompt,
              !hasCanonicalPendingPrompt(pending, in: snapshot) else { return .none }
        return .pending(ChatPendingPromptPresentation(
            snapshot: pending,
            isCompacting: snapshot.phase == .compacting
                || snapshot.operation?.kind == .compaction
        ))
    }

    private func hasCanonicalPendingPrompt(
        _ pending: SessionSnapshot.PendingPrompt,
        in snapshot: SessionSnapshot
    ) -> Bool {
        ChatPendingCanonicalSuppressionPolicy.suppresses(pending, in: snapshot.transcript)
    }

    private var submissionPending: Bool {
        presentationTarget.map(model.composerDrafts.hasPendingSubmission(target:)) ?? false
    }

    private var responseState: ChatResponseState? {
        transcriptPresentation.installed?.tag.responseState
    }

    private var isTranscriptReady: Bool { sessionPresentation.open.phase == .ready }

    private var admitsAutomaticOpeningResume: Bool {
        !ChatOpeningAttemptPolicy.isFailed(sessionPresentation.open.phase)
            && (!retainsDetachedPresentationCut || currentMountedPresentationTarget != nil)
            && (sessionPresentation.needsOpeningResume
                || transcriptPresentation.installed == nil
                || model.presentationTarget(for: sessionID) != presentationTarget)
    }

    private var hasSettledOpeningOffset: Bool {
        switch sessionPresentation.open.phase {
        case .revealing, .presenting, .presented, .ready:
            true
        case .opening, .positioning, .failed:
            false
        }
    }

    private var isLoadingEarlierMessages: Bool {
        ChatEarlierMessagesOperationPolicy.isLoading(
            owner: sessionPresentation.earlierMessagesOperation,
            modelLoading: model.loadingEarlierTranscript,
            scrollLoading: scrollCoordinator.isPrependingHistory
        )
    }

    private var transcriptRevealAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26)
    }

    private var admitsScrollGeometryCallbacks: Bool {
        presentationActivity.allowsViewportObservation
            && (sessionPresentation.open.phase == .positioning
                || sessionPresentation.open.phase == .revealing
                || sessionPresentation.open.phase == .presenting
                || sessionPresentation.open.phase == .presented
                || sessionPresentation.open.phase == .ready)
    }

    private var admitsNativeScrollCallbacks: Bool {
        guard presentationActivity.allowsViewportObservation else { return false }
        #if HOSTED_TEST
        return hostedProbe?.admitsNativeScrollCallbacks != false
        #else
        return true
        #endif
    }

    @ViewBuilder private var openingSurface: some View {
        switch sessionPresentation.open.phase {
        case .opening, .positioning, .revealing, .presenting:
            ZStack {
                if ChatOpeningSurfacePolicy.showsOpaqueCover(phase: sessionPresentation.open.phase) {
                    Color.tronBackground
                }
                TronPulseLoadingIndicator(accent: .tronEmerald, size: 44)
                    .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Opening conversation")
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.tronError)
                Text("Conversation unavailable")
                    .font(TronTypography.body)
                Text(message)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await beginOpeningPresentation(retryingFailure: true) } }
                    .buttonStyle(.plain)
                    .chatTranscriptPill()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
        case .presented, .ready:
            EmptyView()
        }
    }

    @MainActor
    private func recoverExtensionPresentationPublicationIfNeeded() async {
        let activation = viewportActivation
        guard presentationActivity.allowsPresentationPublication,
              !sessionPresentation.permitsExtensionInteractionPresentation,
              sessionPresentation.open.phase == .ready,
              transcriptPresentation.installed != nil,
              sessionPresentation.modelPresentationGeneration != nil else { return }
        do { try await displayFrameScheduler.nextFrame() }
        catch { return }
        guard !Task.isCancelled,
              composerCatalogActivity.allowsPresentationPublication,
              viewportActivation == activation,
              admitCurrentOpeningCommit(),
              sessionPresentation.open.phase == .ready,
              transcriptPresentation.installed != nil,
              sessionPresentation.modelPresentationGeneration != nil else { return }
        sessionPresentation.permitsExtensionInteractionPresentation = true
    }

    @MainActor
    private func beginOpeningAfterForegroundWhenConnected() {
        guard scenePhase == .active,
              presentationActivity.allowsPresentationPublication,
              model.admitsSessionPresentationOpen else { return }
        Task { await beginOpeningPresentation() }
    }

    @MainActor
    private func beginOpeningPresentation(retryingFailure: Bool = false) async {
        if let active = sessionPresentation.activeOpeningTaskLease {
            await active.task.value
            _ = sessionPresentation.finishOpeningTask(active.generation)
            guard !Task.isCancelled,
                  scenePhase == .active,
                  presentationActivity.allowsPresentationPublication,
                  model.admitsSessionPresentationOpen,
                  (sessionPresentation.shouldBeginOpening(retryingFailure: retryingFailure)
                    || admitsAutomaticOpeningResume) else { return }
            // Retry and foreground resume serialize behind the exact drained
            // lease. Re-entering also coalesces multiple waiters on any newer
            // task installed by an earlier waiter.
            await beginOpeningPresentation(retryingFailure: retryingFailure)
            return
        }
        let task = Task { @MainActor in
            await performOpeningPresentation()
        }
        guard let generation = sessionPresentation.installOpeningTask(task) else {
            task.cancel()
            await beginOpeningPresentation(retryingFailure: retryingFailure)
            return
        }
        let deadlineTask = Task { @MainActor in
            do {
                try await Task.sleep(for: ChatOpeningAttemptPolicy.deadline)
                try Task.checkCancellation()
            } catch { return }
            guard sessionPresentation.expireOpeningTask(generation) else { return }
            transcriptPresentation.suspendPendingWork()
            scrollCoordinator.cancel()
            guard scenePhase == .active,
                  presentationActivity.allowsPresentationPublication,
                  model.admitsSessionPresentationOpen,
                  ChatOpeningAttemptPolicy.isUnsettled(sessionPresentation.open.phase) else {
                // Coverage/background/navigation cancellation is resumable and
                // must not publish a delayed timeout behind another surface.
                return
            }
            model.chatInteractionTrace.opening(
                .failed,
                context: ensureInteractionTraceContext(),
                state: interactionTraceState()
            )
            _ = sessionPresentation.open.fail(
                sessionID: sessionID,
                epoch: sessionPresentation.open.epoch,
                message: ChatOpeningAttemptPolicy.timeoutMessage
            )
        }
        await task.value
        let childWasCancelled = sessionPresentation.openingTaskWasCancelled(generation)
        let completedOwnedTask = sessionPresentation.finishOpeningTask(generation)
        deadlineTask.cancel()
        guard ChatOpeningAttemptPolicy.shouldFailUnsettledAttempt(
            completedOwnedTask: completedOwnedTask,
            taskCancelled: Task.isCancelled || childWasCancelled,
            sceneActive: scenePhase == .active,
            presentationActive: presentationActivity.allowsPresentationPublication,
            modelAdmitsOpen: model.admitsSessionPresentationOpen,
            phase: sessionPresentation.open.phase
        ) else { return }
        // Only a still-current foreground owner may turn an unexplained return
        // into a visible failure. Cancellation, route coverage, and background
        // retirement leave the opening phase resumable instead.
        model.chatInteractionTrace.opening(
            .failed,
            context: ensureInteractionTraceContext(),
            state: interactionTraceState()
        )
        _ = sessionPresentation.open.fail(
            sessionID: sessionID,
            epoch: sessionPresentation.open.epoch,
            message: ChatOpeningAttemptPolicy.unsettledMessage
        )
    }

    @MainActor
    private func performOpeningPresentation() async {
        sessionPresentation.permitsExtensionInteractionPresentation = false
        // Retiring/restarting presentation authority cancels any local page
        // admission; late model/scroll completions are token-gated.
        sessionPresentation.earlierMessagesOperation.cancel()
        retireQueueMutationPresentationState()
        if composerScope == nil, let profileID = model.profiles.selected?.id {
            composerScope = model.composerDrafts.prepareDraft(
                profileID: profileID,
                sessionID: sessionID,
                initialText: initialEditorText
            )
        }
        #if HOSTED_TEST
        if let hostedProbe { installHostedControls(probe: hostedProbe) }
        defer { hostedProbe?.recordReadyFrameCompletion() }
        #endif
        performanceTracker.discardScroll()
        let retainsAuthority = currentMountedPresentationTarget != nil
            && currentMountedPresentationTarget == presentationTarget
        let retainsInstalledPresentation = retainsCurrentInstalledPresentation
        let retainsDetachedCut = retainsDetachedPresentationCut
        let retainsVisiblePresentation = (retainsInstalledPresentation || retainsDetachedCut)
            && sessionPresentation.open.phase == .ready
        if !retainsInstalledPresentation && !retainsDetachedCut {
            if !retainsAuthority { sessionPresentation.modelPresentationGeneration = nil }
            transcriptPresentation.reset()
        }
        // A retained pinned surface, including an interrupted unfinished open,
        // revalidates its native viewport against the same installed authority.
        // A retained detached reader remains ready and anchored; it must never
        // be repinned by resume reconciliation.
        let retainedPinnedRevalidation = retainsInstalledPresentation
            && (scrollCoordinator.viewportMode == .pinned
                || ChatOpeningAttemptPolicy.isUnsettled(sessionPresentation.open.phase))
        let epoch = sessionPresentation.open.begin(
            retainingVisiblePresentation: retainsVisiblePresentation
                && !retainedPinnedRevalidation
        )
        model.chatInteractionTrace.opening(
            .attemptBegan,
            context: ensureInteractionTraceContext(),
            retainedPresentation: retainsVisiblePresentation,
            state: interactionTraceState()
        )
        scrollCoordinator.resetForPresentation(
            epoch,
            retainingVisibleViewport: retainsVisiblePresentation
        )
        if (retainsInstalledPresentation || retainsDetachedCut), let retained = transcriptPresentation.installed {
            let rows = ChatPhysicalTranscriptRowPolicy.rows(
                installed: retained,
                canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
            )
            let terminalID = rows.last?.id
                ?? ((retained.sourceWindow.originalStart ?? 0) > 0 ? "earlier-messages" : nil)
            let hasEarlierMessages = (retained.sourceWindow.originalStart ?? 0) > 0
            var physicalPositions = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                ($0.element.id, $0.offset + (hasEarlierMessages ? 1 : 0))
            })
            if hasEarlierMessages { physicalPositions["earlier-messages"] = 0 }
            let leadingEarlierRow = hasEarlierMessages ? 1 : 0
            scrollCoordinator.projectionInstalled(
                structure: retained.physicalRowSpineIdentity,
                terminalPhysicalID: terminalID,
                projectionTag: retained.tag,
                physicalRowPositions: physicalPositions,
                physicalTerminalPosition: rows.indices.last.map { $0 + leadingEarlierRow }
                    ?? (leadingEarlierRow > 0 ? 0 : nil)
            )
        }
        let interval = performanceSignposts.begin(.firstReadyFrame)
        var openedGeneration: Int?
        do {
            let generation: Int
            if retainsAuthority || retainsDetachedCut,
               let target = currentMountedPresentationTarget {
                // Authority is bound independently of the immutable display cut.
                // A replacement may already be synchronized by the model owner.
                generation = target.generation
                sessionPresentation.modelPresentationGeneration = generation
            } else {
                generation = try await openModelPresentation()
                openedGeneration = generation
                if let initialModel {
                    defer { initialModelSettled = true }
                    if let snapshot = model.authoritativeSnapshot(for: sessionID),
                       snapshot.model?.provider != initialModel.provider || snapshot.model?.id != initialModel.id {
                        do {
                            try await model.setModel(initialModel, sessionID: sessionID)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            model.postNotice("The selected model could not be applied; this session will use its current model.")
                        }
                    }
                }
                guard !Task.isCancelled,
                      model.authoritativeSnapshot(for: sessionID)?.sessionId == sessionID else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    return
                }
                sessionPresentation.modelPresentationGeneration = generation
            }
            openedGeneration = generation
            model.chatInteractionTrace.opening(
                .authorityOpened,
                context: ensureInteractionTraceContext(),
                retainedPresentation: retainsVisiblePresentation,
                state: interactionTraceState()
            )
            model.diagnosticCapture.recordCausal(
                name: "opening.authority", profileID: model.profiles.selected?.id,
                connectionID: model.diagnosticConnectionID
            )
            // Presence follows exact synchronized route authority, not scroll
            // positioning. The composer can admit work before a large retained
            // transcript reaches its first ready frame.
            reconcileSessionPresentationVisibility()
            if retainsVisiblePresentation && !retainedPinnedRevalidation {
                // A detached reader keeps the already-installed immutable cut.
                // Rebinding canonical authority must not format or mount a live
                // tail behind the user's viewport; returning to the tail admits
                // one newest cut for this new presentation generation.
                guard !Task.isCancelled,
                      transcriptPresentation.installed != nil,
                      sessionPresentation.open.epoch == epoch,
                      sessionPresentation.open.phase == .ready else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await retireOpeningGeneration(
                        generation,
                        retainingVisiblePresentation: true
                    )
                    return
                }
                if await completeFirstReadyFrame(interval, epoch: epoch) {
                    openedGeneration = nil
                } else {
                    await retireOpeningGeneration(generation, retainingVisiblePresentation: true)
                }
                return
            }
            let installed: InstalledChatTranscript
            if retainsInstalledPresentation || retainsDetachedCut {
                guard let retained = transcriptPresentation.installed else {
                    throw CancellationError()
                }
                installed = retained
            } else {
                installed = try await installCurrentTranscriptProjection(
                    presentationGeneration: generation,
                    consistency: .firstCompletePresentationCommit
                )
            }
            model.chatInteractionTrace.opening(
                .projectionInstalled,
                context: ensureInteractionTraceContext(),
                retainedPresentation: retainsVisiblePresentation,
                state: interactionTraceState(installed: installed)
            )
            model.diagnosticCapture.recordCausal(
                name: "opening.projection", count: installed.sourceWindow.ids.count,
                profileID: model.profiles.selected?.id, connectionID: model.diagnosticConnectionID
            )
            if retainedPinnedRevalidation {
                guard !Task.isCancelled,
                      installedCommitBelongsToCurrentPresentation(
                          installed,
                          generation: generation
                      ),
                      sessionPresentation.open.installAuthoritativeBaseline(
                          sessionID: sessionID,
                          epoch: epoch
                      ) else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await retireOpeningGeneration(
                        generation,
                        retainingVisiblePresentation: true
                    )
                    return
                }
                model.chatInteractionTrace.opening(
                    .baselineInstalled,
                    context: ensureInteractionTraceContext(),
                    retainedPresentation: true,
                    state: interactionTraceState(installed: installed)
                )
                guard await completePositionedOpening(
                    installed: installed,
                    interval: interval,
                    epoch: epoch
                ) == .ready else {
                    await retireOpeningGeneration(
                        generation,
                        retainingVisiblePresentation: true
                    )
                    return
                }
                openedGeneration = nil
                return
            }
            guard !Task.isCancelled,
                  installedCommitBelongsToCurrentPresentation(
                      installed,
                      generation: generation
                  ),
                  sessionPresentation.open.installAuthoritativeBaseline(sessionID: sessionID, epoch: epoch) else {
                performanceSignposts.end(interval, result: .discarded, metrics: .none)
                await retireOpeningGeneration(
                    generation,
                    retainingVisiblePresentation: true
                )
                return
            }
            model.chatInteractionTrace.opening(
                .baselineInstalled,
                context: ensureInteractionTraceContext(),
                retainedPresentation: false,
                state: interactionTraceState(installed: installed)
            )
            let completion = await completePositionedOpening(
                installed: installed,
                interval: interval,
                epoch: epoch
            )
            guard completion == .ready else {
                if case .positioningFailed(let reasons) = completion {
                    let traceContext = ensureInteractionTraceContext()
                    model.chatInteractionTrace.opening(
                        .failed,
                        context: traceContext,
                        positioningSucceeded: false,
                        state: interactionTraceState()
                    )
                    model.chatInteractionTrace.openingFailure(
                        reasons,
                        context: traceContext,
                        state: interactionTraceState()
                    )
                    model.diagnosticCapture.recordCausal(
                        name: "opening.failed", outcome: "settlement",
                        count: reasons.count,
                        profileID: model.profiles.selected?.id, connectionID: model.diagnosticConnectionID
                    )
                    for reason in reasons {
                        model.diagnosticCapture.recordCausal(
                            name: "opening.failure.\(reason.rawValue)", outcome: "settlement",
                            profileID: model.profiles.selected?.id, connectionID: model.diagnosticConnectionID
                        )
                    }
                    _ = sessionPresentation.open.fail(
                        sessionID: sessionID,
                        epoch: epoch,
                        message: "The conversation layout did not settle. Please retry."
                    )
                }
                await retireOpeningGeneration(
                    generation,
                    retainingVisiblePresentation: true
                )
                return
            }
            openedGeneration = nil
        } catch {
            let result = PerformanceResult.forFailure(error)
            let retainCommittedPresentation = result == .cancelled
            if let generation = openedGeneration {
                await retireOpeningGeneration(
                    generation,
                    retainingVisiblePresentation: retainCommittedPresentation
                )
            }
            performanceSignposts.end(interval, result: result, metrics: .none)
            if result == .cancelled { return }
            model.chatInteractionTrace.opening(
                .failed,
                context: ensureInteractionTraceContext(),
                retainedPresentation: retainsVisiblePresentation,
                state: interactionTraceState()
            )
            _ = sessionPresentation.open.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func openModelPresentation() async throws -> Int {
        #if HOSTED_TEST
        // Native-only fixtures substitute the open dependency, never the
        // opening/cover/retirement lifecycle. RPC regressions leave this nil.
        if let open = hostedProbe?.fixtureOpenPresentation { return try await open() }
        #endif
        return try await model.openSessionPresentation(sessionID, composerScope: composerScope)
    }

    @MainActor
    private func retireOpeningGeneration(
        _ generation: Int,
        retainingVisiblePresentation: Bool
    ) async {
        // Command authority and the immutable reader cut have distinct owners.
        // A cancelled reconciliation must not close a valid new subscription
        // merely because the detached display still bears its old generation.
        let retainsReaderCut = retainsDetachedPresentationCut
        let retainsAuthority = retainingVisiblePresentation
            && !ChatOpeningAttemptPolicy.isFailed(sessionPresentation.open.phase)
            && sessionPresentation.modelPresentationGeneration == generation
            && currentMountedPresentationTarget == presentationTarget
            && currentMountedPresentationTarget != nil
            && (scenePhase != .active || !composerCatalogActivity.allowsViewportObservation
                || !currentInstalledCommitMatchesTarget)
        if retainsAuthority { return }
        await model.closeSessionPresentation(sessionID, generation: generation)
        guard sessionPresentation.modelPresentationGeneration == generation else { return }
        model.chatInteractionTrace.opening(
            .retired,
            context: ensureInteractionTraceContext(),
            retainedPresentation: retainsReaderCut,
            state: interactionTraceState()
        )
        sessionPresentation.modelPresentationGeneration = nil
        if !retainsReaderCut { transcriptPresentation.reset() }
    }

    #if HOSTED_TEST
    @MainActor
    private func installHostedControls(probe: ChatHostedProbe) {
        probe.openingPhase = { sessionPresentation.open.phase }
        probe.extensionPublicationAllowed = { sessionPresentation.permitsExtensionInteractionPresentation }
        probe.installedRuntime = { transcriptPresentation.installed?.tag.runtimeGeneration }
        probe.importCameraImage = { await importCameraImage($0) }
        probe.composerPickerEntries = {
            presentedComposerResourcePicker == nil ? [] : composerResourceResults
        }
        probe.composerResourceSelection = { selectComposerResource($0) }
        probe.installScrollControls(
            geometry: { previous, current, viewport in
                if viewport {
                    scrollCoordinator.viewportChanged(previous: previous, current: current)
                } else {
                    scrollCoordinator.geometryChanged(previous: previous, current: current)
                }
            },
            phase: { old, new, geometry in
                scrollCoordinator.scrollPhaseChanged(from: old, to: new, finalGeometry: geometry)
            },
            native: { owned in
                scrollCoordinator.scrollPositionChanged(isPositionedByUser: owned)
            },
            catchUp: { reduceMotion in
                scrollCoordinator.requestCatchUp(reduceMotion: reduceMotion)
            },
            semanticResponse: {
                scrollCoordinator.semanticResponseArrived()
            },
            submitPrompt: {
                send()
            },
            presentDisplay: { sessionPresentation.presentDisplay($0) },
            frame: {
                try await displayFrameScheduler.nextFrame()
            },
            state: {
                ChatHostedScrollState(
                    isDetached: scrollCoordinator.userScrolledAway,
                    hasUnread: scrollCoordinator.hasUnreadContent,
                    isWaitingForPrependSemanticFrame: scrollCoordinator.isWaitingForPrependSemanticFrame
                )
            },
            prepend: {
                guard !isLoadingEarlierMessages,
                      scrollCoordinator.canRequestHistoryPage,
                      let generation = sessionPresentation.modelPresentationGeneration,
                      let operationToken = sessionPresentation.earlierMessagesOperation.begin() else { return false }
                let anchor = transcriptPresentation.installed
                    .flatMap { installed in
                        installed.tag == transcriptProjectionSource
                            ? scrollCoordinator.semanticAnchor(in: installed.timeline)
                            : nil
                    }
                return scrollCoordinator.beginHistoryPageLoad(
                    anchor: anchor,
                    load: { admittedAnchor in
                        do { try await probe.waitForPrependPageRelease() }
                        catch { return .failed }
                        // The hosted boundary owns no Gateway transport. Model
                        // exact canonical installation; semantic restoration is
                        // emitted only when the coordinator admitted its anchor.
                        guard sessionPresentation.modelPresentationGeneration == generation else {
                            return .failed
                        }
                        guard let admittedAnchor,
                              let current = transcriptPresentation.installed,
                              current.tag == transcriptProjectionSource,
                              let renderedID = current.timeline
                                .renderedIDBySemanticID[admittedAnchor.semanticID] else {
                            return .installed(nil)
                        }
                        let installedLayout = scrollCoordinator.beginInstalledLayoutEpoch()
                        return .installed(ChatPrependPage(
                            renderedAnchorID: renderedID,
                            installedLayout: installedLayout
                        ))
                    },
                    completion: { result in
                        probe.recordPrependCompletion(result)
                        self.settleEarlierMessagesOperation(operationToken)
                        self.intakeLatestTranscriptProjectionIfNeeded()
                    }
                )
            },
            reapplyPinnedPosition: {
                scrollCoordinator.foregroundViewportBecameActive()
            },
            invalidatePresentation: {
                scrollCoordinator.resetForPresentation()
            },
            reopenPresentation: {
                await beginOpeningPresentation()
            },
            cancelPresentation: {
                scrollCoordinator.cancel()
            }
        )
    }
    #endif

    @MainActor
    private func revealPositionedTranscript(epoch: Int) -> Bool {
        model.chatInteractionTrace.opening(
            .revealBegan,
            context: ensureInteractionTraceContext(),
            state: interactionTraceState()
        )
        // Resolve the physical positioning lift atomically while it is still
        // covered. The single user-visible animation is owned later, after
        // marker settlement, so two animation clocks cannot race geometry.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        let began = withTransaction(transaction) {
            sessionPresentation.open.beginPositionedReveal(sessionID: sessionID, epoch: epoch)
        }
        if began { scrollCoordinator.openingRevealCompleted() }
        return began
    }

    @MainActor
    private func revealSettledTranscript(epoch: Int) async -> Bool {
        let activation = viewportActivation
        do {
            // Commit the initial opacity/offset while the opaque surface still
            // owns presentation. This prevents an unanimated ready frame when
            // settlement and reveal are coalesced in one SwiftUI update.
            try await displayFrameScheduler.nextFrame()
        } catch {
            return false
        }
        guard !Task.isCancelled,
              sessionPresentation.open.epoch == epoch,
              sessionPresentation.open.phase == .presenting,
              viewportActivation == activation,
              composerCatalogActivity.allowsViewportObservation,
              admitCurrentOpeningCommit() else { return false }
        // The cosmetic fade starts at presented; only a current physical frame
        // may commit ready. No animation-completion callback owns readiness.
        let began = withAnimation(transcriptRevealAnimation) {
            sessionPresentation.open.beginVisibleReveal(sessionID: sessionID, epoch: epoch)
        }
        if began, let context = interactionTraceLedger.context {
            model.chatInteractionTrace.opening(
                .visibleRevealBegan, context: context, state: interactionTraceState()
            )
        }
        return began
    }

    @MainActor
    private func completeFirstReadyFrame(_ interval: PerformanceInterval, epoch: Int) async -> Bool {
        if let context = interactionTraceLedger.context {
            model.chatInteractionTrace.opening(
                .readyFrameAwaited, context: context, state: interactionTraceState()
            )
        }
        let activation = viewportActivation
        do {
            try await displayFrameScheduler.nextFrame()
            guard !Task.isCancelled,
                  sessionPresentation.open.epoch == epoch,
                  viewportActivation == activation,
                  scenePhase == .active,
                  composerCatalogActivity.allowsViewportObservation,
                  composerCatalogActivity.allowsPresentationPublication,
                  admitCurrentOpeningCommit(),
                  (sessionPresentation.open.phase == .ready
                    || sessionPresentation.open.installReadyViewport(sessionID: sessionID, epoch: epoch)) else {
                performanceSignposts.end(interval, result: .discarded, metrics: .none)
                return false
            }
            performanceSignposts.end(interval, result: .success, metrics: .none)
            let context = ensureInteractionTraceContext()
            model.chatInteractionTrace.opening(
                .readyFrame,
                context: context,
                state: interactionTraceState()
            )
            model.diagnosticCapture.recordCausal(
                name: "opening.first-ready", outcome: "success",
                profileID: model.profiles.selected?.id, connectionID: model.diagnosticConnectionID
            )
            scheduleOpeningTraceCheckpoints(
                context: context,
                epoch: epoch,
                expectedVisibleRows: totalInteractionTraceRows
            )
            // The validated current frame releases opening ownership. The
            // cosmetic fade may still run; it owns no intake/command lease.
            scrollCoordinator.completeVisibleOpeningReveal()
            reconcileSessionPresentationVisibility()
            // Publish leased interaction/editor routes only after chat opening
            // has crossed a real ready frame. Otherwise their sheet can cover
            // the parent, cancel opening, and create a present/dismiss loop.
            sessionPresentation.permitsExtensionInteractionPresentation = true
            intakeLatestTranscriptProjectionIfNeeded()
            admitPendingFloatingDisplay()
            #if HOSTED_TEST
            hostedProbe?.markReady()
            let geometry = scrollCoordinator.latestGeometry
            if geometry.isAtCatchUpBoundary {
                hostedProbe?.recordScrollSettle(distanceFromBottom: geometry.distanceFromBottom)
            }
            #endif
            return true
        } catch {
            performanceSignposts.end(
                interval,
                result: PerformanceResult.forFailure(error),
                metrics: .none
            )
            return false
        }
    }

    private func intakeLatestTranscriptProjectionIfNeeded() {
        guard scenePhase != .background,
              sessionPresentation.permitsExtensionInteractionPresentation,
              !scrollCoordinator.blocksAutomaticLiveProjectionIntake,
              !scrollCoordinator.isPrependingHistory,
              let capture = transcriptProjectionCapture,
              transcriptPresentation.installed?.tag != capture.tag else { return }
        intakeTranscriptProjection(capture)
    }

    private func physicalOpeningTailID(for installed: InstalledChatTranscript) -> String {
        let rows = ChatPhysicalTranscriptRowPolicy.rows(
            installed: installed,
            canonicalAliases: sessionPresentation.canonicalSubmissionAliases.aliases
        )
        // Target the current physical terminal row so lazy content realizes its
        // natural tail. The marker remains the separate settlement oracle.
        if let terminal = rows.last { return terminal.id }
        if (installed.sourceWindow.originalStart ?? 0) > 0 { return "earlier-messages" }
        return "transcript-bottom"
    }

    private enum PositionedOpeningCompletion: Equatable {
        case ready
        case positioningFailed([ChatInteractionTrace.OpeningFailureReason])
        case discarded
    }

    /// Shared production/hosted post-authority path. Authority setup differs,
    /// but baseline positioning, reveal, and first-frame proof must not drift.
    @MainActor
    private func completePositionedOpening(
        installed: InstalledChatTranscript,
        interval: PerformanceInterval,
        epoch: Int
    ) async -> PositionedOpeningCompletion {
        let positioned = await positionLatestTail(
            epoch: epoch,
            targetRenderedID: "transcript-bottom",
            physicalTargetID: physicalOpeningTailID(for: installed)
        )
        guard admitCurrentOpeningCommit(), positioned else {
            let isCurrentFailure = sessionPresentation.open.epoch == epoch
                && ChatOpeningAttemptPolicy.shouldFailUnsettledAttempt(
                    completedOwnedTask: true,
                    taskCancelled: Task.isCancelled,
                    sceneActive: scenePhase == .active,
                    presentationActive: presentationActivity.allowsPresentationPublication,
                    modelAdmitsOpen: model.admitsSessionPresentationOpen,
                    phase: sessionPresentation.open.phase
                )
            performanceSignposts.end(
                interval,
                result: isCurrentFailure ? .failure : .discarded,
                metrics: .none
            )
            return isCurrentFailure
                ? .positioningFailed(scrollCoordinator.openingFailureReasons())
                : .discarded
        }
        guard !Task.isCancelled, revealPositionedTranscript(epoch: epoch) else {
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return .discarded
        }
        let activation = viewportActivation
        let settlement = await scrollCoordinator.waitForOpeningTailSettlement()
        #if HOSTED_TEST
        await hostedProbe?.openingSettlementReturned?(settlement)
        #endif
        // A deadline owns physical settlement, not authority. Fence failures
        // as well as successes before either can publish or retire a runtime.
        guard !Task.isCancelled,
              sessionPresentation.open.epoch == epoch,
              viewportActivation == activation,
              scenePhase == .active,
              composerCatalogActivity.allowsViewportObservation,
              composerCatalogActivity.allowsPresentationPublication,
              admitCurrentOpeningCommit() else {
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return .discarded
        }
        switch settlement {
        case .cancelled:
            performanceSignposts.end(interval, result: .cancelled, metrics: .none)
            return .discarded
        case .failed(let reasons):
            performanceSignposts.end(interval, result: .failure, metrics: .none)
            return .positioningFailed(reasons)
        case .settled:
            break
        }
        guard sessionPresentation.open.installSettledViewport(
            sessionID: sessionID,
            epoch: epoch
        ) else {
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return .discarded
        }
        let revealed = await revealSettledTranscript(epoch: epoch)
        guard revealed, admitCurrentOpeningCommit() else {
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return .discarded
        }
        return await completeFirstReadyFrame(interval, epoch: epoch) ? .ready : .discarded
    }

    @MainActor
    private func positionLatestTail(
        epoch: Int,
        targetRenderedID: String?,
        physicalTargetID: String
    ) async -> Bool {
        // The opening surface remains opaque until the exact physical marker
        // after transcript and queue rows intersects a plausible bottom viewport.
        guard !Task.isCancelled,
              sessionPresentation.open.epoch == epoch,
              sessionPresentation.open.phase == .positioning else { return false }
        let context = ensureInteractionTraceContext()
        model.chatInteractionTrace.opening(
            .positioningBegan,
            context: context,
            state: interactionTraceState()
        )
        model.diagnosticCapture.recordCausal(
            name: "opening.positioning-began", profileID: model.profiles.selected?.id,
            connectionID: model.diagnosticConnectionID
        )
        let positioned = await scrollCoordinator.positionOpeningTail(
            targetRenderedID: targetRenderedID,
            physicalTargetID: physicalTargetID
        )
        model.chatInteractionTrace.opening(
            .positioningEnded,
            context: context,
            positioningSucceeded: positioned,
            state: interactionTraceState()
        )
        model.diagnosticCapture.recordCausal(
            name: "opening.positioning-ended", outcome: positioned ? "success" : "failure",
            profileID: model.profiles.selected?.id, connectionID: model.diagnosticConnectionID
        )
        if positioned { performanceTracker.settleScroll() }
        return positioned
            && !Task.isCancelled
            && sessionPresentation.open.epoch == epoch
            && sessionPresentation.open.phase == .positioning
    }

    @MainActor
    private func executePendingScrollCommand() {
        guard presentationActivity.allowsViewportObservation,
              scrollCoordinator.admitsViewportCallback(capturedActivation: viewportActivation),
              let command = scrollCoordinator.command else { return }
        performanceTracker.beginScrollCommand()
        let update = {
            switch command.destination {
            case .tail where command.origin == .physicalTailRepair:
                installStableTailTarget()
            case .materialize(let renderedID):
                var target = ScrollPosition(idType: String.self)
                target.scrollTo(id: renderedID, anchor: .bottom)
                transcriptScrollPosition = target
            case .openingTail(let renderedID):
                var target = ScrollPosition(idType: String.self)
                target.scrollTo(id: renderedID, anchor: .bottom)
                transcriptScrollPosition = target
            case .tail:
                transcriptScrollPosition.scrollTo(edge: .bottom)
            case .offsetY(let offsetY):
                transcriptScrollPosition.scrollTo(y: offsetY)
            }
        }
        switch command.animation {
        case .disabled:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        case .smooth(let duration):
            if reduceMotion {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, update)
            } else {
                withAnimation(.smooth(duration: duration), update)
            }
        }
        #if HOSTED_TEST
        hostedProbe?.recordScrollCommand(
            isAutomatic: false,
            isSmooth: command.animation != .disabled,
            origin: command.origin
        )
        #endif
        // The coordinator keeps this exact token installed through its native
        // opening/catch-up/semantic settlement, then publishes a leased release.
        // Clearing the binding in this same update could cancel the
        // scrollTo before SwiftUI applies it.
        _ = scrollCoordinator.commandApplied(command)
    }

    @MainActor
    private func installStableTailTarget() {
        // A fresh value forces SwiftUI to apply the marker target after drift.
        var target = ScrollPosition(idType: String.self)
        target.scrollTo(id: "transcript-bottom", anchor: .bottom)
        transcriptScrollPosition = target
    }

    @MainActor
    private func releaseScrollPositionTarget() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transcriptScrollPosition = ScrollPosition(idType: String.self)
        }
        #if HOSTED_TEST
        hostedProbe?.recordTargetRelease()
        #endif
    }

    @MainActor
    private func applyViewportMode(_ mode: ChatViewportMode) {
        guard mode == .anchored || scrollCoordinator.canInstallPersistentBottomPosition else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transcriptScrollPosition = ScrollPosition(idType: String.self)
        }
    }

    @MainActor
    private func catchUpToTail() {
        transcriptPresentation.discardPendingEntrances()
        scrollCoordinator.requestCatchUp(reduceMotion: reduceMotion)
    }

    @MainActor
    private func settleEarlierMessagesOperation(_ token: ChatEarlierMessagesOperationOwner.Token) {
        sessionPresentation.earlierMessagesOperation.settle(token)
    }

    private func earlierMessagesChip(installed: InstalledChatTranscript) -> some View {
        TronPaginationButton(label: "Load earlier messages", loadingLabel: "Loading earlier…", icon: "arrow.up", isLoading: isLoadingEarlierMessages, isEnabled: scrollCoordinator.canRequestHistoryPage, accent: .tronAccentText) {
            guard !isLoadingEarlierMessages,
                  scrollCoordinator.canRequestHistoryPage,
                  let presentationGeneration = sessionPresentation.modelPresentationGeneration,
                  let operationToken = sessionPresentation.earlierMessagesOperation.begin() else { return }
            let sessionID = installed.tag.sessionID
            let capturedAnchor = transcriptPresentation.installed.map {
                scrollCoordinator.semanticAnchor(in: $0.timeline)
            } ?? nil
            _ = scrollCoordinator.beginHistoryPageLoad(
                anchor: capturedAnchor,
                load: { @MainActor admittedAnchor in
                    let result = await model.loadEarlierTranscript(
                        sessionID: sessionID,
                        presentationGeneration: presentationGeneration
                    )
                    guard result == .installed,
                          sessionPresentation.modelPresentationGeneration == presentationGeneration,
                          let installed = try? await installCurrentTranscriptProjection(
                              presentationGeneration: presentationGeneration,
                              consistency: .firstCompleteTranscriptWindow
                          ) else { return .failed }
                    guard let admittedAnchor,
                          let renderedID = installed.timeline
                            .renderedIDBySemanticID[admittedAnchor.semanticID] else {
                        return .installed(nil)
                    }
                    let installedLayout = scrollCoordinator.beginInstalledLayoutEpoch()
                    return .installed(ChatPrependPage(
                        renderedAnchorID: renderedID,
                        installedLayout: installedLayout
                    ))
                },
                completion: { _ in
                    self.settleEarlierMessagesOperation(operationToken)
                    self.intakeLatestTranscriptProjectionIfNeeded()
                }
            )
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .overlay(alignment: .bottom) {
            if case let .failed(message) = model.transcriptLoadState {
                Text(message)
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 42)
            }
        }
    }

    private var composer: some View {
        ChatComposerView(
            sessionFacts: visibleSessionFacts,
            processOverview: selectedAuthoritativeSnapshot?.processOverview,
            processActivities: model.sessionProcessPresentation(for: sessionID)?.activities,
            extensionRetainedContent: extensionRetainedContent,
            pendingAttachments: pendingAttachments,
            selectedResource: selectedComposerResource,
            resourcePicker: presentedComposerResourcePicker,
            resourceResults: presentedComposerResourcePicker == nil ? [] : composerResourceResults,
            submissionTransitionID: layoutTransaction.activeSubmissionGenerationID,
            submissionAnimation: layoutTransaction.resolvedAnimation,
            reduceMotion: reduceMotion,
            showsCatchUp: scrollCoordinator.shouldShowCatchUpButton,
            showsAmbientWorkingBlur: showsAmbientWorkingBlur,
            keyboardVisible: keyboardObserver.isVisible,
            text: composerTextBinding,
            textRevision: composerTextRevisionBinding,
            isFocused: Binding(
                get: { composerFocused },
                set: { composerFocused = $0 }
            ),
            selection: $composerSelection,
            responder: composerResponder,
            isEditable: ChatComposerPolicy.isTextEditable(isTranscriptReady: isTranscriptReady),
            keyboardAppearance: colorScheme == .dark ? .dark : .light,
            contextProgress: contextProgressPresentation,
            trailingMode: composerTrailingMode,
            isSending: sending,
            submissionPending: submissionPending,
            hasActiveUploads: hasActiveComposerUploads,
            isTranscriptReady: isTranscriptReady,
            isCommandReady: admitsLiveSessionCommands,
            attachmentMenuState: attachmentMenuState,
            attachmentActionsEnabled: attachmentActionsEnabled,
            resourcePickerAvailable: resourcePickerAvailable,
            commandPickerAvailable: currentComposerResourceCatalog != nil,
            promptPickerAvailable: currentComposerResourceCatalog != nil,
            glassNamespace: composerGlassNamespace,
            onActivityTap: {
                sessionPresentation.showActivity = true
            },
            onRemoveAttachment: { id in
                guard let target = presentationTarget else { return }
                model.composerDrafts.removeAttachment(id, target: target)
            },
            onRemoveResource: {
                guard let composerScope else { return }
                model.composerDrafts.removeSelectedResource(for: composerScope)
            },
            onSelectResource: selectComposerResource,
            onDismissResourcePicker: dismissComposerResourcePicker,
            onShowContext: { sessionPresentation.showContext = true },
            onSend: { behavior in send(behavior: behavior) },
            onAbort: {
                // Command identity is canonical authority, not delayed render state.
                let operation = selectedAuthoritativeSnapshot?.operation
                let kind = ChatComposerPolicy.abortKind(operation: operation)
                Task {
                    await model.abort(
                        sessionID: sessionID,
                        kind: kind,
                        operationID: operation?.id
                    )
                }
            },
            onSelectAttachmentDestination: requestAttachmentPresentation,
            onPasteImages: importPastedImages,
            onCatchUp: catchUpToTail,
            onComposerHeight: composerHeightChanged,
            onComposerHeightSettled: composerHeightSettled
        )
    }

    private var composerTrailingMode: ComposerTrailingMode? {
        ChatComposerPolicy.trailingMode(
            phase: visibleSessionFacts?.phase,
            hasContent: ChatComposerPolicy.hasSendableContent(
                text: composerText,
                attachmentCount: pendingAttachments.count,
                hasResource: selectedComposerResource != nil
            ),
            isSending: sending
        )
    }

    private var contextProgressPresentation: SessionContextProgressPresentation {
        let snapshot = selectedAuthoritativeSnapshot
        return SessionContextProgressPolicy.presentation(
            isTranscriptReady: isTranscriptReady && snapshot != nil,
            contextPercentage: snapshot.map(contextPercentage),
            modelName: snapshot?.model?.displayDescription,
            isCompacting: visibleSessionFacts?.phase == .compacting
        )
    }

    private func contextPercentage(_ snapshot: SessionSnapshot) -> Int {
        if let percent = snapshot.contextUsage?.percent { return min(max(Int(percent.rounded()), 0), 100) }
        guard let usage = snapshot.contextUsage, usage.contextWindow > 0, let tokens = usage.tokens else { return 0 }
        return min(max(Int((Double(tokens) / Double(usage.contextWindow) * 100).rounded()), 0), 100)
    }

    private var chatTitle: String {
        selectedAuthoritativeSnapshot?.name
            ?? model.sessions.first { $0.id == sessionID }?.title
            ?? "Session"
    }

    @ToolbarContentBuilder private func toolbar(titleWidth: CGFloat) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Back")
        }
        ToolbarItem(placement: .principal) {
            Text(chatTitle)
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronEmerald)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: titleWidth)
                .clipped()
                .accessibilityLabel(chatTitle)
        }
        if model.isShowingHistoricalTranscript {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { _ = await model.loadHistoricalEarlierTranscript(sessionID: sessionID) } } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Load older history")
                Button { Task { _ = await model.loadHistoricalLaterTranscript(sessionID: sessionID) } } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Load newer history")
                Button { model.returnToLatestTranscript(sessionID: sessionID) } label: {
                    Image(systemName: "arrow.uturn.down")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(Color.tronEmerald)
                }
                .accessibilityLabel("Return to latest messages")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { sessionPresentation.showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Settings")
        }
    }

    private var pendingInteractionScopes: [ExtensionInteractionScope] {
        selectedAuthoritativeSnapshot?.extensionPresentation.pendingInteractions.map(ExtensionInteractionScope.init) ?? []
    }

    private var interactionBinding: Binding<ExtensionInteraction?> {
        Binding(
            get: { pendingPresentedInteraction },
            set: { presented in
                guard presented == nil, let interaction = pendingPresentedInteraction else { return }
                closeInteractionPresentation(interaction)
            }
        )
    }

    private func closeInteractionPresentation(_ interaction: ExtensionInteraction) {
        sessionPresentation.closeInteractionPresentation(interaction)
    }

    private var editorRequestBinding: Binding<ComposerEditorRequest?> {
        Binding(
            get: { initialModelSettled ? routedEditorRequest : nil },
            set: { presented in
                guard presented == nil,
                      let request = routedEditorRequest,
                      let target = presentationTarget else { return }
                model.disposeExtensionEditorRequest(request, disposition: .keep, target: target)
            }
        )
    }

    private var currentMountedPresentationTarget: AppModel.SessionPresentationTarget? {
        guard composerScope.map({ $0.profileID == model.profiles.selected?.id }) ?? true,
              let target = model.presentationTarget(for: sessionID),
              model.hasMountedSessionAuthority(target) else { return nil }
        return target
    }

    private var currentInstalledCommitMatchesTarget: Bool {
        guard let target = model.presentationTarget(for: sessionID),
              let installed = transcriptPresentation.installed,
              installed.tag.sessionID == target.sessionID,
              installed.tag.presentationGeneration == target.generation,
              sessionPresentation.modelPresentationGeneration == target.generation,
              let snapshot = model.authoritativeSnapshot(for: sessionID),
              snapshot.sessionId == sessionID,
              installed.tag.runtimeGeneration == snapshot.runtimeGeneration,
              !ChatOpeningAttemptPolicy.isFailed(sessionPresentation.open.phase) else {
            return false
        }
        return true
    }

    private var retainsCurrentInstalledPresentation: Bool {
        guard currentMountedPresentationTarget == presentationTarget,
              currentMountedPresentationTarget != nil,
              currentInstalledCommitMatchesTarget else { return false }
        return true
    }

    private func admitCurrentOpeningCommit() -> Bool {
        guard currentMountedPresentationTarget != nil,
              currentMountedPresentationTarget == presentationTarget else { return false }
        // Only an already-ready anchored reader may display an older identity.
        if retainsDetachedPresentationCut { return true }
        guard let installed = transcriptPresentation.installed,
              let generation = sessionPresentation.modelPresentationGeneration else { return false }
        let current = installedCommitBelongsToCurrentPresentation(installed, generation: generation)
        if !current {
            // Runtime replacement is resumable against the model's new mounted
            // authority, not a layout failure or a reason to reopen transport.
            sessionPresentation.cancelOpeningTask()
            scrollCoordinator.cancel()
        }
        return current
    }

    /// A ready detached reader may keep its immutable cut while a new target is
    /// being reconciled. That cut is display-only: it never admits mutations or
    /// gets relabeled with the replacement target's canonical metadata.
    private var retainsDetachedPresentationCut: Bool {
        guard sessionPresentation.open.phase == .ready,
              scrollCoordinator.viewportMode == .anchored,
              let installed = transcriptPresentation.installed,
              installed.tag.sessionID == sessionID,
              composerScope.map({ $0.profileID == model.profiles.selected?.id }) ?? true else { return false }
        return true
    }

    private var attachmentMenuState: ChatAttachmentMenuState {
        let target = presentationTarget
        return ChatAttachmentMenuState(
            sessionID: sessionID,
            phase: visibleSessionFacts?.phase ?? selectedAuthoritativeSnapshot?.phase,
            hasMountedAuthority: target.map(model.admitsLiveSessionUploads) ?? false
        )
    }

    private var attachmentActionsEnabled: Bool {
        attachmentMenuState.actionsEnabled
    }

    private var supportsSkillPrompt: Bool {
        model.gatewayInfo?.capabilities.contains("skill-prompt.v1") == true
    }

    private var resourcePickerAvailable: Bool {
        supportsSkillPrompt && currentComposerResourceCatalog != nil
    }

    private var currentComposerResourceCatalog: ComposerResourceCatalog? {
        guard let presentationTarget, model.commandCatalogTarget == presentationTarget,
              let installed = installedComposerResourceCatalog,
              installed.source == composerResourceCatalogIdentity else { return nil }
        return installed.catalog
    }

    private var presentedComposerResourcePicker: ComposerResourcePickerSource? {
        guard let picker = composerResourcePicker, currentComposerResourceCatalog != nil,
              picker.kind != .skill || supportsSkillPrompt else { return nil }
        return picker
    }

    private var composerCatalogActivity: PresentationSurfaceActivity {
        // Read the retained topology owner after awaits, not only the activity
        // value captured by the task's last SwiftUI environment update.
        presentationCoordinator?.activity(for: presentationSurfaceToken) ?? presentationActivity
    }

    private var composerResourceCatalogIdentity: ComposerResourceCatalogIdentity {
        ComposerResourceCatalogIdentity(
            commands: model.commands,
            catalogTarget: model.commandCatalogTarget,
            presentationTarget: presentationTarget,
            supportsSkillPrompt: supportsSkillPrompt
        )
    }

    private func requestAttachmentPresentation(_ destination: ChatAttachmentDestination) {
        guard attachmentActionsEnabled else { return }
        if destination.isComposerResource {
            let kind: ComposerResourceEntry.Kind = switch destination {
            case .skills: .skill
            case .prompts: .prompt
            case .commands: .command
            default: preconditionFailure("non-resource attachment destination")
            }
            guard currentComposerResourceCatalog != nil,
                  kind != .skill || supportsSkillPrompt else { return }
            sessionPresentation.attachmentPresentationTask?.cancel()
            sessionPresentation.queuedAttachmentDestination = nil
            sessionPresentation.attachmentPresentationTask = Task { @MainActor in
                // Let the native menu complete dismissal before inserting the
                // inline child. The UITextView remains the responder owner.
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled, attachmentActionsEnabled,
                      let catalog = currentComposerResourceCatalog,
                      kind != .skill || supportsSkillPrompt else { return }
                let picker = ComposerResourcePickerSource.menu(kind)
                composerResourceResults = catalog.entries(kind: kind, query: "")
                composerResourcePicker = picker
            }
            return
        }
        dismissComposerResourcePicker()
        // Keep the composer responder intent intact while the native menu
        // settles. UIKit may temporarily cover the keyboard for a system picker,
        // but selecting an attachment must not explicitly end the draft's focus.

        // A native Menu is still dismissing when its action runs. Presenting a
        // sheet or system picker synchronously can collide with that transient
        // presentation controller on physical iOS. Queue one destination, force
        // a fresh presentation edge, and activate it after dismissal settles.
        sessionPresentation.attachmentPresentationTask?.cancel()
        sessionPresentation.attachmentDestination = nil
        sessionPresentation.queuedAttachmentDestination = destination
        sessionPresentation.attachmentPresentationTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard !Task.isCancelled,
                  sessionPresentation.queuedAttachmentDestination == destination,
                  attachmentActionsEnabled else { return }
            sessionPresentation.queuedAttachmentDestination = nil
            sessionPresentation.attachmentDestination = destination
        }
    }

    private func cancelAttachmentPresentation(includingActive: Bool) {
        sessionPresentation.attachmentPresentationTask?.cancel()
        sessionPresentation.attachmentPresentationTask = nil
        sessionPresentation.queuedAttachmentDestination = nil
        if includingActive { sessionPresentation.attachmentDestination = nil }
    }

    private func attachmentPresentationBinding(
        for destination: ChatAttachmentDestination
    ) -> Binding<Bool> {
        precondition(!destination.isComposerResource)
        return Binding(
            get: { sessionPresentation.attachmentDestination == destination },
            set: { isPresented in
                if isPresented {
                    guard attachmentActionsEnabled else { return }
                    sessionPresentation.attachmentDestination = destination
                } else if sessionPresentation.attachmentDestination == destination {
                    sessionPresentation.attachmentDestination = nil
                }
            }
        )
    }

    private func reconcileComposerResourcePicker() {
        guard let catalog = currentComposerResourceCatalog else { return }
        if let token = ComposerSuggestionTriggerPolicy.activeToken(
            in: composerText,
            selection: composerSelection
        ), token.kind != .skill || resourcePickerAvailable {
            sessionPresentation.attachmentPresentationTask?.cancel()
            sessionPresentation.attachmentPresentationTask = nil
            if composerResourcePicker != .token(token) {
                composerResourceResults = catalog.entries(for: .token(token))
                composerResourcePicker = .token(token)
            }
        } else if case .token = composerResourcePicker {
            dismissComposerResourcePicker()
        }
    }

    private func selectComposerResource(_ entry: ComposerResourceEntry) {
        guard let composerScope, let catalog = currentComposerResourceCatalog,
              catalog.entries(kind: entry.kind, query: "").contains(entry) else { return }
        switch entry.kind {
        case .skill:
            var replacement = (text: composerText, selection: composerSelection)
            if case .token(let token) = composerResourcePicker,
               let tokenReplacement = ComposerSuggestionTriggerPolicy.replacing(
                    text: replacement.text,
                    range: token.replacementRange,
                    with: ""
               ) {
                replacement = tokenReplacement
            }
            replacement = ComposerCommandCompletionPolicy.removingLeadingCommand(
                text: replacement.text,
                selection: replacement.selection,
                commands: catalog.slashEntries(query: "")
            )
            applyComposerReplacement(replacement)
            model.composerDrafts.selectResource(entry.commandInfo, for: composerScope)
        case .command, .prompt:
            let replacement: (text: String, selection: NSRange)
            if case .token(let token) = composerResourcePicker {
                guard let tokenReplacement = ComposerSuggestionTriggerPolicy.replacing(
                    text: composerText,
                    range: token.replacementRange,
                    with: ""
                ) else { return }
                replacement = tokenReplacement
            } else {
                // A selected command/template is represented by the chip; its
                // editable arguments remain ordinary composer text without a
                // leading slash or trigger token.
                replacement = ComposerCommandCompletionPolicy.removingLeadingCommand(
                    text: composerText,
                    selection: composerSelection,
                    commands: catalog.slashEntries(query: "")
                )
            }
            model.composerDrafts.selectResource(entry.commandInfo, for: composerScope)
            applyComposerReplacement(replacement)
        }
        dismissComposerResourcePicker()
    }

    private func applyComposerReplacement(_ replacement: (text: String, selection: NSRange)) {
        composerSelection = replacement.selection
        composerTextBinding.wrappedValue = replacement.text
    }

    private func dismissComposerResourcePicker() {
        composerResourcePicker = nil
        composerResourceResults = []
    }

    private var queueEditorCommit: QueuedMessageManagementCommit? {
        let installed = QueuedMessageManagementPolicy.installedCommit(for: transcriptPresentation.installed)
        guard sessionPresentation.queuedMessageEditor != nil else { return installed }
        guard queueManagementCapabilityForProjection else { return nil }
        guard let queue = model.sessionQueuePresentation(for: sessionID) else { return installed }
        guard queue.runtimeGeneration == transcriptPresentation.installed?.tag.runtimeGeneration else { return nil }
        return QueuedMessageManagementCommit(expectedRevision: queue.revision, items: queue.items)
    }

    @MainActor
    private func updateQueuedMessage(
        _ id: String,
        text: String,
        behavior: SessionSnapshot.QueuedMessage.Behavior,
        commit: QueuedMessageManagementCommit
    ) async {
        await mutateQueue(affectedID: id, presentedCommit: commit) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw CancellationError()
            }
            items[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            items[index].behavior = behavior
        }
    }

    @MainActor
    private func removeQueuedMessage(_ id: String, commit: QueuedMessageManagementCommit) async {
        await mutateQueue(affectedID: id, presentedCommit: commit) { items in
            guard items.contains(where: { $0.id == id }) else { throw CancellationError() }
            items.removeAll { $0.id == id }
        }
    }

    @MainActor
    private func clearQueuedMessages() async {
        await mutateQueue(affectedID: "queue-clear-all") { items in
            items.removeAll(keepingCapacity: false)
        }
    }

    @MainActor
    private func moveQueuedMessage(_ id: String, offset: Int) async {
        await mutateQueue(affectedID: id) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw CancellationError()
            }
            let destination = index + offset
            guard items.indices.contains(destination) else { return }
            items.swapAt(index, destination)
        }
    }

    @MainActor
    private func convergeQueueMutation(
        expectedRevision: Int,
        target: SessionPresentationIdentity,
        presentationGeneration: Int
    ) async -> Bool {
        if let queue = model.sessionQueuePresentation(for: sessionID),
           queue.revision > expectedRevision { return true }
        guard await model.restoreMountedPresentationAfterReconnect(),
              presentationTarget == target,
              sessionPresentation.modelPresentationGeneration == presentationGeneration else {
            return false
        }
        guard let queue = model.sessionQueuePresentation(for: sessionID),
              queue.revision > expectedRevision else { return false }
        // Receipt reconciliation continues behind the editor; installing a chat
        // frame waits for the native viewport's uncover, not for command success.
        if presentationActivity.allowsPresentationPublication {
            _ = try? await installCurrentTranscriptProjection(presentationGeneration: presentationGeneration)
        }
        return true
    }

    @MainActor
    private func mutateQueue(
        affectedID: String,
        presentedCommit: QueuedMessageManagementCommit? = nil,
        mutation: (inout [SessionSnapshot.QueuedMessage]) throws -> Void
    ) async {
        guard sessionPresentation.mutatingQueuedMessageIDs.isEmpty,
              let target = presentationTarget,
              let presentationGeneration = sessionPresentation.modelPresentationGeneration else { return }
        let commit: QueuedMessageManagementCommit
        let previousItems: [SessionSnapshot.QueuedMessage]
        do {
            guard let source = presentedCommit ?? QueuedMessageManagementPolicy.installedCommit(for: transcriptPresentation.installed) else { return }
            previousItems = source.items
            var items = source.items
            try mutation(&items)
            commit = QueuedMessageManagementCommit(expectedRevision: source.expectedRevision, items: items)
        } catch {
            return
        }
        let changedOperationIDs = QueuedMessageManagementPolicy.changedOperationIDs(
            from: previousItems,
            to: commit.items
        )
        guard let mutationToken = sessionPresentation.queueMutationResolution.begin() else { return }
        sessionPresentation.mutatingQueuedMessageIDs.insert(affectedID)
        sessionPresentation.locallyMutatedQueueOperationIDs.formUnion(changedOperationIDs)
        sessionPresentation.queueMutationCommandIsPending = true
        sessionPresentation.pendingQueueMutationRevision = commit.expectedRevision
        do {
            try await model.replaceQueue(
                sessionID: sessionID,
                expectedRevision: commit.expectedRevision,
                items: commit.items
            )
            guard sessionPresentation.queueMutationResolution.isActive(mutationToken),
                  sessionPresentation.modelPresentationGeneration == presentationGeneration,
                  presentationTarget == target else {
                _ = sessionPresentation.queueMutationResolution.resolve(mutationToken, as: .retired)
                return
            }
            model.composerDrafts.invalidateSettledQueueHandoff(
                target: target,
                affectedOperationIDs: changedOperationIDs
            )
            sessionPresentation.locallyMutatedQueueOperationIDs.formUnion(
                ChatQueueMutationProjectionPolicy.exclusions(
                    for: .success,
                    affectedOperationIDs: changedOperationIDs
                )
            )
            sessionPresentation.queueMutationCommandIsPending = false
            resolveDeferredQueueMutationProjection()
            _ = sessionPresentation.queueMutationResolution.resolve(mutationToken, as: .commandCompleted)
            let converged = await convergeQueueMutation(
                expectedRevision: commit.expectedRevision,
                target: target,
                presentationGeneration: presentationGeneration
            )
            // A confirmed response is not canonical. The bounded mounted
            // resynchronization above either installs the newer queue revision
            // or retires the local mutation so controls cannot remain disabled.
            clearSettledQueueMutationPresentationState()
            if !converged {
                model.presentComposerActionError(
                    "The queue changed remotely. Please try again.",
                    target: target
                )
            }
        } catch {
            guard sessionPresentation.queueMutationResolution.isActive(mutationToken),
                  sessionPresentation.modelPresentationGeneration == presentationGeneration,
                  presentationTarget == target else {
                _ = sessionPresentation.queueMutationResolution.resolve(mutationToken, as: .retired)
                return
            }
            sessionPresentation.queueMutationCommandIsPending = false
            clearSettledQueueMutationPresentationState()
            // Failure restores the pre-command interpretation before the held
            // canonical boundary installs, preserving its consumed entrance.
            resolveDeferredQueueMutationProjection()
            _ = sessionPresentation.queueMutationResolution.resolve(mutationToken, as: .commandCompleted)
            model.presentComposerActionError(error, target: target)
        }
    }

    private func composerResourceInvocation() -> ComposerResourceInvocation? {
        let value = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        // The staged chip is the sole invocation authority. A slash typed into
        // its argument text is data, not an opportunity to replace the chip.
        if let scope = composerScope,
           let resource = model.composerDrafts.selectedResource(for: scope),
           let entry = ComposerResourceEntry(command: resource) {
            return entry.invocation(arguments: value)
        }
        return ComposerResourceInvocationPolicy.leadingInvocation(in: value, commands: model.commands)
    }

    @MainActor
    private func send(behavior explicitBehavior: String? = nil) {
        guard admitsLiveSessionCommands,
              let target = presentationTarget,
              let installed = transcriptPresentation.installed,
              let source = transcriptProjectionCapture,
              source.tag.presentationGeneration == target.generation else {
            recordComposerAvailability(blockedAction: true)
            return
        }
        // Recheck exact authority after capturing the current projection and
        // again inside the mutation coordinator; display admission is not a receipt.
        let snapshotAcceptsQueuedPrompts = selectedAuthoritativeSnapshot.map {
            $0.acceptsQueuedPrompts ?? ($0.phase == .running)
        } ?? false
        // A stale context-menu closure cannot force queue semantics after the
        // authoritative capability changes; the prompt becomes ordinary.
        let behavior = ChatComposerPolicy.submissionBehavior(
            acceptsQueuedPrompts: snapshotAcceptsQueuedPrompts
        ).map { explicitBehavior ?? $0 }
        guard !hasActiveComposerUploads else {
            model.presentComposerActionError(
                "Wait for attachments to finish uploading before sending.",
                target: target
            )
            return
        }
        // Capture invocation intent exactly once before any presentation state
        // changes. The same value is validated, staged, rendered, and sent.
        let resourceInvocation = composerResourceInvocation()
        if let resourceInvocation {
            guard model.commandCatalogTarget == target else {
                model.presentComposerActionError(
                    "Resources are still loading for this session.",
                    target: target
                )
                return
            }
            let source: CommandInfo.Source = switch resourceInvocation.source {
            case .skill: .skill
            case .prompt: .prompt
            case .extension: .extension
            }
            let catalogName = source == .skill
                ? "skill:\(resourceInvocation.name)"
                : resourceInvocation.name
            let matches = model.commands.filter {
                $0.source == source && $0.name == catalogName
            }
            let shadowed = source != .extension && model.commands.contains {
                $0.source == .extension && $0.name == catalogName
            }
            guard matches.count == 1, !shadowed else {
                if let composerScope {
                    model.composerDrafts.removeSelectedResource(for: composerScope)
                }
                model.presentComposerActionError(
                    "That resource is no longer available for this session.",
                    target: target
                )
                return
            }
        }
        let traceContext = ensureInteractionTraceContext()
        let traceToken = interactionTraceLedger.beginSubmission()
        let submissionBeganPinned = scrollCoordinator.viewportMode == .pinned
        let expectedVisibleRows = max(1, totalInteractionTraceRows)
        model.chatInteractionTrace.submission(
            .began,
            context: traceContext,
            state: interactionTraceState(installed: installed)
        )
        do {
            // Admission and the local lifecycle graft are atomic. A locally
            // knowable rejection must occur before viewport, responder, layout,
            // draft, or row-presentation state changes.
            let installedBeforeSubmission = installed
            let freezesDetachedProjection = scrollCoordinator
                .defersAutomaticLiveProjectionIntake
            // A neutral root transaction preserves descendant-scoped composer
            // and flight animations.
            let admission = try withTransaction(Transaction()) {
                let submission = try model.beginComposerSubmission(
                    target: target,
                    behavior: behavior,
                    resourceInvocation: resourceInvocation,
                    canonicalTranscript: model.transcriptSnapshot(for: sessionID)?.transcript ?? [],
                    queuedMessages: selectedAuthoritativeSnapshot?.displayedQueuedMessages ?? [],
                    runtimeGeneration: selectedAuthoritativeSnapshot?.runtimeGeneration
                )
                composerResourcePicker = nil
                // Transfer an applied sentinel lease directly to the outgoing
                // row while preserving detached-reader ownership.
                scrollCoordinator.submitted()
                // Submission, composer height, row admission, and keyboard
                // changes join one settlement generation only after admission.
                let layoutGeneration = layoutTransaction.join(.submission)
                _ = layoutTransaction.join(.transcriptGrowth)
                let submittedAttachments = model.composerDrafts.submittedAttachments(for: target)
                    .filter { attachment in
                        attachment.gatewayUploadID.map(submission.attachmentIDs.contains) == true
                    }
                    .prefix(ComposerAttachmentPolicy.maximumCount)
                    .map { $0.frozenForHandoff() }
                let isExtensionCommand = submission.resourceInvocation?.isExtensionCommand == true
                // UIKit publishes its keyboard clock synchronously when
                // available before the already-sized outgoing row is grafted.
                dismissComposerForAdmittedSubmission()
                // Exact extension commands do not create a canonical user
                // message in Pi. Never graft a prompt bubble that can become a
                // phantom row; the canonical invocation receipt owns its row.
                let grafted = isExtensionCommand
                    || !presentationActivity.allowsPresentationPublication
                    || freezesDetachedProjection
                    ? false
                    : transcriptPresentation.graftLocalLifecycle(
                    handoff: .outgoing(
                        presentation: ChatOutgoingSubmissionPresentation(
                            snapshot: submission,
                            transportActive: true
                        ),
                        attachments: Array(submittedAttachments)
                    ),
                    queuePresentationIDByOperationID:
                        installedBeforeSubmission.queuePresentationIDByOperationID
                )
                let materializationAdmitted = grafted && (
                    ChatPromptBehavior(rawValue: submission.behavior) == .ordinary
                        ? scrollCoordinator.fullHeightTailInserted(
                            renderedID: submission.presentationID,
                            layoutTransactionID: layoutGeneration
                        )
                        : scrollCoordinator.discreteTailInserted(
                            renderedID: submission.presentationID,
                            layoutTransactionID: layoutGeneration
                        )
                )
                if materializationAdmitted,
                   scrollCoordinator.consumePreAdmissionEntranceSettlement(
                       renderedID: submission.presentationID,
                       layoutTransactionID: layoutGeneration
                   ) {
                    layoutTransaction.settle(layoutGeneration, source: .transcriptGrowth)
                } else if !materializationAdmitted {
                    layoutTransaction.settle(layoutGeneration, source: .transcriptGrowth)
                }
                return (
                    submission: submission,
                    grafted: grafted,
                    materialized: materializationAdmitted
                )
            }
            let submission = admission.submission
            model.chatInteractionTrace.submission(
                .lifecycleGrafted,
                context: traceContext,
                grafted: admission.grafted,
                materialized: admission.materialized,
                state: interactionTraceState()
            )
            if let capture = transcriptProjectionCapture {
                var stableTransaction = Transaction()
                stableTransaction.disablesAnimations = true
                withTransaction(stableTransaction) {
                    intakeTranscriptProjection(capture)
                }
                model.chatInteractionTrace.submission(
                    .projectionSubmitted,
                    context: traceContext,
                    state: interactionTraceState()
                )
            }
            // ComposerDraftCoordinator retains accepted transport across route
            // changes and target-gates late presentation effects.
            Task { @MainActor in
                do {
                    try await model.sendComposer(submission)
                    model.chatInteractionTrace.submission(
                        .transportSucceeded,
                        context: traceContext,
                        state: interactionTraceState()
                    )
                    if selectedAuthoritativeSnapshot?.extensionPresentation.hostEpoch.isEmpty == false {
                        model.scheduleExtensionEditorUpdate(target: target, text: "")
                    }
                } catch {
                    model.chatInteractionTrace.submission(
                        .transportFailed,
                        context: traceContext,
                        state: interactionTraceState()
                    )
                    model.presentComposerActionError(error, target: target)
                }
            }
            scheduleSubmissionTraceCheckpoints(
                context: traceContext,
                token: traceToken,
                beganPinned: submissionBeganPinned,
                expectedVisibleRows: expectedVisibleRows
            )
        } catch {
            model.chatInteractionTrace.submission(
                .admissionFailed,
                context: traceContext,
                state: interactionTraceState()
            )
            interactionTraceLedger.endSubmission(traceToken)
            abandonLayoutTransaction()
            model.presentComposerActionError(error, target: target)
        }
    }

    private func scheduleSubmissionTraceCheckpoints(
        context: Int,
        token: Int,
        beganPinned: Bool,
        expectedVisibleRows: Int
    ) {
        Task { @MainActor in
            defer { interactionTraceLedger.endSubmission(token) }
            for delay in [
                Duration.milliseconds(250),
                .milliseconds(750),
                .milliseconds(1_250)
            ] {
                do { try await Task.sleep(for: delay); try Task.checkCancellation() }
                catch { return }
                guard interactionTraceLedger.ownsContext(context),
                      interactionTraceLedger.ownsSubmission(token) else { return }
                let state = interactionTraceState()
                model.chatInteractionTrace.submission(
                    .checkpoint,
                    context: context,
                    state: state
                )
                model.chatInteractionTrace.geometry(
                    .submissionCheckpoint,
                    context: context,
                    state: state
                )
                if ChatInteractionAnomalyPolicy.lostProjection(
                    expectedRows: expectedVisibleRows,
                    currentRows: totalInteractionTraceRows
                ) {
                    model.chatInteractionTrace.anomaly(
                        .submissionLostProjection,
                        context: context,
                        state: state
                    )
                    continue
                }
                if ChatInteractionAnomalyPolicy.displacedPinnedViewport(
                    expectedPinned: beganPinned,
                    currentMode: scrollCoordinator.viewportMode,
                    isUserInteracting: scrollCoordinator.isUserInteracting,
                    isPositionedByUser: transcriptScrollPosition.isPositionedByUser,
                    geometry: scrollCoordinator.latestGeometry,
                    tailClassification: scrollCoordinator.physicalTailEvidence?.classification
                ) {
                    model.chatInteractionTrace.anomaly(
                        .submissionLostTail,
                        context: context,
                        state: state
                    )
                }
            }
        }
    }

    private func importCameraImage(_ image: UIImage) async {
        guard let target = presentationTarget else { return }
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            model.presentComposerActionError(
                "The captured photo could not be prepared.",
                target: target
            )
            return
        }
        do {
            try await model.upload(
                name: "photo.jpg",
                mimeType: "image/jpeg",
                data: data,
                target: target
            )
        }
        catch { model.presentComposerActionError(error, target: target) }
    }

    private func importPastedImages(_ providers: [NSItemProvider]) {
        guard attachmentActionsEnabled, let target = presentationTarget else { return }
        guard providers.count <= ChatAttachmentImportPolicy.maximumPhotoSelection else {
            model.presentComposerActionError(ComposerPastedImages.ImportError.tooLarge, target: target)
            return
        }
        // Repeated pastes are independent accepted selections, not replacements
        // for an earlier paste. Bound preparation work and retire it with its chat.
        guard sessionPresentation.pastedImageImports.count < ChatAttachmentImportPolicy.maximumPhotoSelection else {
            model.presentComposerActionError("Wait for the copied images to finish loading.", target: target)
            return
        }
        let id = UUID()
        sessionPresentation.pastedImageImports[id] = Task { @MainActor in
            defer { sessionPresentation.pastedImageImports[id] = nil }
            var candidates: [ComposerAttachmentUploadCandidate] = []
            var bytes = 0
            for provider in providers.prefix(ChatAttachmentImportPolicy.maximumPhotoSelection) {
                guard !Task.isCancelled, presentationTarget == target else { return }
                do {
                    let candidate = try await ComposerPastedImages.load(
                        provider, maximumBytes: ChatAttachmentImportPolicy.maximumFileBytes - bytes
                    )
                    guard !Task.isCancelled, presentationTarget == target else { return }
                    bytes += candidate.data.count
                    candidates.append(candidate)
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, presentationTarget == target else { return }
                    model.presentComposerActionError(error, target: target)
                }
            }
            guard !candidates.isEmpty, !Task.isCancelled, presentationTarget == target else { return }
            // Once admitted, the draft coordinator owns upload receipts/removal.
            // Covering the chat must not cancel already-published attachment chips.
            sessionPresentation.pastedImageImports[id] = nil
            do { try await model.uploadBatch(candidates, target: target) }
            catch is CancellationError { return }
            catch { model.presentComposerActionError(error, target: target) }
        }
    }

    private func importPhotos(_ values: [PhotosPickerItem], target: SessionPresentationIdentity) async {
        guard !values.isEmpty, presentationTarget == target else { return }
        var candidates: [ComposerAttachmentUploadCandidate] = []
        var candidateBytes = 0
        candidates.reserveCapacity(min(values.count, ChatAttachmentImportPolicy.maximumPhotoSelection))
        for item in values.prefix(ChatAttachmentImportPolicy.maximumPhotoSelection) {
            guard !Task.isCancelled, presentationTarget == target else { return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    model.presentComposerActionError(
                        "The selected photo could not be prepared.",
                        target: target
                    )
                    continue
                }
                let (nextBytes, overflow) = candidateBytes.addingReportingOverflow(data.count)
                guard !overflow,
                      data.count > 0,
                      nextBytes <= ChatAttachmentImportPolicy.maximumFileBytes else {
                    model.presentComposerActionError(
                        "Attach at most 10 files totaling 25 MiB.",
                        target: target
                    )
                    break
                }
                candidateBytes = nextBytes
                let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                let filename = "photo.\(UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "jpg")"
                candidates.append(.init(name: filename, mimeType: mimeType, data: data))
            } catch is CancellationError {
                guard !Task.isCancelled, presentationTarget == target else { return }
                continue
            } catch {
                model.presentComposerActionError(error, target: target)
            }
        }
        guard !candidates.isEmpty, !Task.isCancelled,
              presentationTarget == target else { return }
        do {
            try await model.uploadBatch(candidates, target: target)
        } catch is CancellationError {
            return
        } catch {
            model.presentComposerActionError(error, target: target)
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard let target = presentationTarget else { return }
        guard case .success(let urls) = result else {
            if case .failure(let error) = result {
                model.presentComposerActionError(error, target: target)
            }
            return
        }
        for url in urls.prefix(ChatAttachmentImportPolicy.maximumFileSelection) {
            do { try await model.uploadFile(url, target: target) }
            catch is CancellationError { return }
            catch { model.presentComposerActionError(error, target: target) }
        }
    }
}
