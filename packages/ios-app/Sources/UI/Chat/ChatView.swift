import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let sessionID: String
    private let initialEditorText: String?
    private let initialModel: ModelRef?
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
    @State private var composerResponder = ChatComposerResponder()
    @State private var keyboardObserver = ChatKeyboardObserver()
    @State private var layoutTransaction = ChatLayoutTransaction()
    @State private var morphRegistry = ChatMorphFrameRegistry()
    @State private var composerResourceCatalog = ComposerResourceCatalog(commands: [])
    @State private var composerResourcePicker: ComposerResourcePickerSource?
    @State private var composerResourceResults: [ComposerResourceEntry] = []
    /// The exact installed frame from before a descendant began consuming live
    /// transcript data. Viewport work is rebased once on uncover rather than on
    /// every hidden tool-output update.
    @State private var deferredViewportProjectionBaseline: InstalledChatTranscript?
    @State private var hasDeferredViewportProjection = false

    #if HOSTED_TEST
    init(
        sessionID: String,
        initialEditorText: String? = nil,
        initialModel: ModelRef? = nil,
        onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
        hostedProbe: ChatHostedProbe? = nil,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.sessionID = sessionID
        self.initialEditorText = initialEditorText
        self.initialModel = initialModel
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
        onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.sessionID = sessionID
        self.initialEditorText = initialEditorText
        self.initialModel = initialModel
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
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The complete composer is the sole structural inset owner, so
                // the keyboard, multiline text, and attachment chips push the
                // native transcript viewport exactly once and reverse naturally.
                composer
            }
            .overlay(alignment: .top) { topBlur }
            .overlay {
                ChatMorphFlightLayer(
                    registry: morphRegistry,
                    layoutTransaction: layoutTransaction,
                    reduceMotion: reduceMotion
                )
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
            projectCWD: model.authoritativeSnapshot(for: sessionID)?.cwd,
            onForkCreated: onForkCreated,
            showContext: $sessionPresentation.showContext,
            showSettings: $sessionPresentation.showSettings,
            queuedMessageEditor: $sessionPresentation.queuedMessageEditor,
            installed: transcriptPresentation.installed,
            mutatingQueuedMessageIDs: sessionPresentation.mutatingQueuedMessageIDs,
            onUpdateQueuedMessage: { id, text, behavior in
                Task { await updateQueuedMessage(id, text: text, behavior: behavior) }
            },
            onRemoveQueuedMessage: { id in Task { await removeQueuedMessage(id) } },
            cameraPresented: attachmentPresentationBinding(for: .camera),
            photosPresented: attachmentPresentationBinding(for: .photos),
            photos: $sessionPresentation.photos,
            onCameraImage: { image in Task { await importCameraImage(image) } },
            processesPresented: processPresentationBinding,
            interaction: interactionBinding,
            onInteractionClosed: closeInteractionPresentation,
            filesPresented: attachmentPresentationBinding(for: .files),
            onFileImport: { result in Task { await importFiles(result) } },
            editorRequest: editorRequestBinding,
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
        .onChange(of: transcriptPresentation.installed) { _, installed in
            guard sessionPresentation.queuedMessageEditor != nil,
                  QueuedMessageManagementPolicy.installedCommit(for: installed) == nil else { return }
            sessionPresentation.queuedMessageEditor = nil
        }
        .task(id: composerResourceCatalogIdentity) {
            let identity = composerResourceCatalogIdentity
            let ownsCatalog = identity.catalogTarget != nil
                && identity.catalogTarget == identity.presentationTarget
            let commands = ownsCatalog
                ? identity.commands.filter { identity.supportsSkillPrompt || $0.source != .skill }
                : []
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
            guard !Task.isCancelled else { return }
            composerResourceCatalog = catalog
            if ownsCatalog, let composerScope {
                model.composerDrafts.reconcileSelectedResource(for: composerScope, commands: commands)
            }
            if let picker = composerResourcePicker {
                composerResourceResults = catalog.entries(kind: picker.kind, query: picker.query)
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
    }

    var body: some View {
        contentSurface
        .onAppear {
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
            guard let animation = layoutTransaction.animation else {
                layoutTransaction.settle(participant)
                return
            }
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                // UIKit owns the inset interpolation. This participant keeps its
                // settlement on the same resolved generation clock.
            } completion: {
                layoutTransaction.settle(participant)
            }
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
        .onChange(of: model.connectionState) { _, state in
            reconcileSessionPresentationVisibility()
            guard scenePhase == .active,
                  presentationActivity.allowsPresentationPublication,
                  state == .connected,
                  (sessionPresentation.needsOpeningResume
                    || transcriptPresentation.installed == nil) else { return }
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
               !current.allowsViewportObservation,
               current.allowsDataPublication,
               !hasDeferredViewportProjection {
                deferredViewportProjectionBaseline = transcriptPresentation.installed
                hasDeferredViewportProjection = true
            }
            if previous.allowsDataPublication,
               !current.allowsDataPublication {
                transcriptPresentation.suspendPendingWork()
                deferredViewportProjectionBaseline = nil
                hasDeferredViewportProjection = false
            }
            if !previous.allowsViewportObservation,
               current.allowsViewportObservation {
                reconcileDeferredViewportProjectionIfNeeded()
                if scenePhase == .active,
                   !sessionPresentation.needsOpeningResume,
                   transcriptPresentation.installed != nil {
                    scrollCoordinator.foregroundViewportBecameActive()
                }
            }
        }
        .task(id: presentationActivity.allowsPresentationPublication) {
            switch ChatOpeningSurfacePolicy.action(
                surfaceActive: presentationActivity.allowsPresentationPublication,
                hasOpeningTask: sessionPresentation.openingTask != nil,
                needsOpeningResume: sessionPresentation.needsOpeningResume
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
                      presentationActivity.allowsPresentationPublication,
                      sessionPresentation.needsOpeningResume else { return }
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
                reconcileInstalledProjectionForViewport(
                    previousTag: previousTag,
                    installed: installed
                )
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

    private func scenePhaseChanged(_ current: ScenePhase) {
        reconcileSessionPresentationVisibility(sceneActive: current == .active)
        if current == .background {
            abandonLayoutTransaction()
            // Retire page/opening/correction tasks and native target leases;
            // durable pinned/detached intent remains in the coordinator.
            scrollCoordinator.cancel()
            // Background suspension retires disposable presentation work while
            // AppModel retains accepted uploads and submissions.
            sessionPresentation.suspendForBackground()
        } else if current == .active,
                  presentationActivity.allowsPresentationPublication,
                  !sessionPresentation.needsOpeningResume,
                  transcriptPresentation.installed != nil {
            intakeLatestTranscriptProjectionIfNeeded()
            scrollCoordinator.foregroundViewportBecameActive()
        }
    }

    private func foregroundReconciliationCompleted() {
        reconcileSessionPresentationVisibility()
        guard scenePhase == .active,
              presentationActivity.allowsPresentationPublication else { return }
        if sessionPresentation.needsOpeningResume
            || transcriptPresentation.installed == nil {
            beginOpeningAfterForegroundWhenConnected()
        } else {
            scrollCoordinator.foregroundViewportBecameActive()
        }
    }

    private func retirePresentation() {
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
    }

    private func abandonLayoutTransaction() {
        morphRegistry.abandon()
        layoutTransaction.abandon()
    }

    /// Projection data can advance while a descendant sheet is visible, but
    /// the covered transcript must not mutate scroll, morph, or layout owners.
    /// Reconcile the newest complete installation once the viewport is active.
    private func reconcileDeferredViewportProjectionIfNeeded() {
        guard hasDeferredViewportProjection else { return }
        let baseline = deferredViewportProjectionBaseline
        deferredViewportProjectionBaseline = nil
        hasDeferredViewportProjection = false
        let installed = transcriptPresentation.installed
        guard baseline?.tag != installed?.tag else { return }
        if let baseline {
            scrollCoordinator.transcriptProjectionWillChange(from: baseline)
        }
        reconcileInstalledProjectionForViewport(
            previousTag: baseline?.tag,
            installed: installed
        )
    }

    private func reconcileInstalledProjectionForViewport(
        previousTag: ChatTranscriptProjectionTag?,
        installed: InstalledChatTranscript?
    ) {
        guard presentationActivity.allowsViewportObservation else { return }
        scrollCoordinator.reconcileMaterializationRows { renderedID in
            installed?.containsPhysicalRowID(renderedID) == true
        }
        if presentationActivity.allowsContinuousAnimation {
            let outgoingPresentation = installed?.handoff.outgoingPresentation
            if let generation = morphRegistry.reconcile(
                installedLifecycleID: outgoingPresentation?.id,
                permitsFlight: outgoingPresentation?.usesQueuedCardVisual != true
            ) {
                layoutTransaction.settle(generation, source: .morphFlight)
            }
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
                structure: installed?.physicalRowSpineIdentity
            )
        }
        if projectionLayoutChanged {
            scrollCoordinator.installedTranscriptChanged(installed)
        }
    }

    private func settleTranscriptEntrance(renderedID: String) {
        guard let generation = scrollCoordinator.layoutTransactionForSettledEntrance(
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

    private func settleUnchangedComposerAfterDisplayFrames(
        generation: Int,
        baselineHeight: CGFloat
    ) {
        Task { @MainActor in
            do {
                try await displayFrameScheduler.nextFrame()
                try Task.checkCancellation()
                try await displayFrameScheduler.nextFrame()
                try Task.checkCancellation()
            } catch { return }
            guard layoutTransaction.generation?.id == generation,
                  abs(composerHeightLedger.current - baselineHeight)
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
        _ = sessionPresentation.canonicalSubmissionAliases.insert(
            canonicalID: canonicalID,
            presentationID: presentationID
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
        guard presentationActivity.allowsDataPublication,
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
        GeometryReader { viewport in
            transcriptContent(
                minimumUnderflowContentHeight: ChatTranscriptUnderflowLayoutPolicy.minimumContentHeight(
                    containerHeight: viewport.size.height,
                    bottomInset: viewport.safeAreaInsets.bottom
                )
            )
        }
    }

    private func transcriptContent(minimumUnderflowContentHeight: CGFloat) -> some View {
        ChatTranscriptScrollView(
            transcriptPresentation: transcriptPresentation,
            scrollCoordinator: scrollCoordinator,
            performanceTracker: performanceTracker,
            installed: transcriptPresentation.installed,
            canonicalSubmissionIDs: sessionPresentation.canonicalSubmissionHandoffs.ids,
            canonicalSubmissionAliases: sessionPresentation.canonicalSubmissionAliases.aliases,
            isReady: isTranscriptReady,
            minimumUnderflowContentHeight: minimumUnderflowContentHeight,
            reduceMotion: reduceMotion,
            presentationEpoch: sessionPresentation.open.epoch,
            presentationPhase: sessionPresentation.open.phase,
            admitsGeometryCallbacks: admitsScrollGeometryCallbacks,
            admitsNativeCallbacks: admitsNativeScrollCallbacks,
            responseState: responseState,
            mutatingQueuedMessageIDs: sessionPresentation.mutatingQueuedMessageIDs,
            morphRegistry: morphRegistry,
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
            if presentationActivity.allowsDataPublication {
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
                        guard source == capture.tag else { return }
                        intakeTranscriptProjection(capture)
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
            phase: facts.phase,
            retry: facts.retry
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
            transcriptPresentation.submit(
                snapshot: snapshot,
                handoff: capture.handoff,
                queuePresentationIDByOperationID: capture.queuePresentationIDByOperationID,
                tag: tag
            )
            do {
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
    /// A process-sheet intent resumes after those leased routes settle.
    private var processPresentationBinding: Binding<Bool> {
        Binding(
            get: { sessionPresentation.showProcesses && extensionForegroundPresentation == .none },
            set: { presented in
                if !presented { sessionPresentation.showProcesses = false }
            }
        )
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

    private var admitsLiveSessionCommands: Bool {
        guard !model.isReconcilingForeground,
              scrollCoordinator.admitsSubmission,
              let target = presentationTarget else { return false }
        return model.admitsLiveSessionCommands(target)
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
            && (sessionPresentation.open.phase == .positioning || sessionPresentation.open.phase == .ready)
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
        case .opening, .positioning:
            ZStack {
                TronPulseLoadingIndicator(accent: .tronEmerald, size: 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Opening conversation")
            .transition(.opacity)
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
                Button("Retry") { Task { await beginOpeningPresentation() } }
                    .buttonStyle(.plain)
                    .chatTranscriptPill()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
        case .ready:
            EmptyView()
        }
    }

    @MainActor
    private func recoverExtensionPresentationPublicationIfNeeded() async {
        guard presentationActivity.allowsPresentationPublication,
              !sessionPresentation.permitsExtensionInteractionPresentation,
              sessionPresentation.open.phase == .ready,
              transcriptPresentation.installed != nil,
              sessionPresentation.modelPresentationGeneration != nil else { return }
        do { try await displayFrameScheduler.nextFrame() }
        catch { return }
        guard !Task.isCancelled,
              presentationActivity.allowsPresentationPublication,
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
    private func beginOpeningPresentation() async {
        if let active = sessionPresentation.activeOpeningTaskLease {
            await active.task.value
            _ = sessionPresentation.finishOpeningTask(active.generation)
            guard !Task.isCancelled,
                  scenePhase == .active,
                  presentationActivity.allowsPresentationPublication,
                  model.admitsSessionPresentationOpen,
                  sessionPresentation.needsOpeningResume else { return }
            // Retry and foreground resume serialize behind the exact drained
            // lease. Re-entering also coalesces multiple waiters on any newer
            // task installed by an earlier waiter.
            await beginOpeningPresentation()
            return
        }
        let task = Task { @MainActor in
            await performOpeningPresentation()
        }
        guard let generation = sessionPresentation.installOpeningTask(task) else {
            task.cancel()
            await beginOpeningPresentation()
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
            _ = sessionPresentation.open.fail(
                sessionID: sessionID,
                epoch: sessionPresentation.open.epoch,
                message: ChatOpeningAttemptPolicy.timeoutMessage
            )
        }
        await task.value
        let completedOwnedTask = sessionPresentation.finishOpeningTask(generation)
        deadlineTask.cancel()
        guard completedOwnedTask,
              ChatOpeningAttemptPolicy.isUnsettled(sessionPresentation.open.phase) else { return }
        // Every current foreground attempt must settle. Background/route
        // retirement invalidates the task generation above and remains silently
        // resumable; an exact task that simply returned cannot leave an opaque
        // opening surface with no owner.
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
        if let hostedProbe {
            await beginHostedPresentation(probe: hostedProbe)
            return
        }
        #endif
        performanceTracker.discardScroll()
        let retainsVisiblePresentation = selectedAuthoritativeSnapshot?.sessionId == sessionID
            && transcriptPresentation.installed != nil
            && sessionPresentation.open.phase == .ready
        if !retainsVisiblePresentation {
            sessionPresentation.modelPresentationGeneration = nil
            transcriptPresentation.reset()
        }
        // A retained pinned surface must revalidate its native viewport before
        // becoming visible again. A retained detached reader remains ready and
        // anchored; it must never be repinned by resume reconciliation.
        let retainedPinnedRevalidation = retainsVisiblePresentation
            && scrollCoordinator.viewportMode == .pinned
        let epoch = sessionPresentation.open.begin(
            retainingVisiblePresentation: retainsVisiblePresentation
                && !retainedPinnedRevalidation
        )
        scrollCoordinator.resetForPresentation(
            epoch,
            retainingVisibleViewport: retainsVisiblePresentation
        )
        let interval = performanceSignposts.begin(.firstReadyFrame)
        var openedGeneration: Int?
        do {
            let generation = try await model.openSessionPresentation(
                sessionID,
                composerScope: composerScope
            )
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
            // Presence follows exact synchronized route authority, not scroll
            // positioning. The composer can admit work before a large retained
            // transcript reaches its first ready frame.
            reconcileSessionPresentationVisibility()
            let installed = try await installCurrentTranscriptProjection(
                presentationGeneration: generation,
                consistency: .firstCompletePresentationCommit
            )
            if retainsVisiblePresentation && !retainedPinnedRevalidation {
                guard !Task.isCancelled,
                      installedCommitBelongsToCurrentPresentation(
                          installed,
                          generation: generation
                      ),
                      sessionPresentation.open.epoch == epoch,
                      sessionPresentation.open.phase == .ready else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await retireOpeningGeneration(
                        generation,
                        retainingVisiblePresentation: true
                    )
                    return
                }
                openedGeneration = nil
                _ = await completeFirstReadyFrame(interval, epoch: epoch)
                return
            }
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
                let positioned = await positionLatestTail(
                    epoch: epoch,
                    targetRenderedID: physicalOpeningTailID(for: installed)
                )
                guard positioned,
                      revealPositionedTranscript(epoch: epoch) else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await retireOpeningGeneration(
                        generation,
                        retainingVisiblePresentation: true
                    )
                    return
                }
                openedGeneration = nil
                _ = await completeFirstReadyFrame(interval, epoch: epoch)
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
                    retainingVisiblePresentation: false
                )
                return
            }
            let positioned = await positionLatestTail(
                epoch: epoch,
                targetRenderedID: physicalOpeningTailID(for: installed)
            )
            guard positioned else {
                let isCurrentTimeout = !Task.isCancelled
                    && sessionPresentation.open.epoch == epoch
                    && sessionPresentation.open.phase == .positioning
                performanceSignposts.end(
                    interval,
                    result: isCurrentTimeout ? .failure : .discarded,
                    metrics: .none
                )
                if isCurrentTimeout {
                    _ = sessionPresentation.open.fail(
                        sessionID: sessionID,
                        epoch: epoch,
                        message: "The conversation layout did not settle. Please retry."
                    )
                }
                await retireOpeningGeneration(
                    generation,
                    retainingVisiblePresentation: false
                )
                return
            }
            guard !Task.isCancelled,
                  revealPositionedTranscript(epoch: epoch) else {
                performanceSignposts.end(interval, result: .discarded, metrics: .none)
                await retireOpeningGeneration(
                    generation,
                    retainingVisiblePresentation: false
                )
                return
            }
            openedGeneration = nil
            _ = await completeFirstReadyFrame(interval, epoch: epoch)
        } catch {
            if let generation = openedGeneration {
                await retireOpeningGeneration(
                    generation,
                    retainingVisiblePresentation: retainsVisiblePresentation
                )
            }
            let result = PerformanceResult.forFailure(error)
            performanceSignposts.end(interval, result: result, metrics: .none)
            if result == .cancelled { return }
            _ = sessionPresentation.open.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func retireOpeningGeneration(
        _ generation: Int,
        retainingVisiblePresentation: Bool
    ) async {
        await model.closeSessionPresentation(sessionID, generation: generation)
        guard sessionPresentation.modelPresentationGeneration == generation else { return }
        sessionPresentation.modelPresentationGeneration = nil
        if !retainingVisiblePresentation {
            transcriptPresentation.reset()
        }
    }

    #if HOSTED_TEST
    @MainActor
    private func beginHostedPresentation(probe: ChatHostedProbe) async {
        performanceTracker.discardScroll()
        let retainsVisiblePresentation = selectedAuthoritativeSnapshot?.sessionId == sessionID
            && transcriptPresentation.installed != nil
            && sessionPresentation.open.phase == .ready
        if !retainsVisiblePresentation {
            transcriptPresentation.reset()
        }
        let retainedPinnedRevalidation = retainsVisiblePresentation
            && scrollCoordinator.viewportMode == .pinned
        let epoch = sessionPresentation.open.begin(
            retainingVisiblePresentation: retainsVisiblePresentation
                && !retainedPinnedRevalidation
        )
        let interval = performanceSignposts.begin(.firstReadyFrame)
        guard selectedAuthoritativeSnapshot != nil,
              let presentationGeneration = model.presentationGeneration(for: sessionID) else {
            performanceSignposts.end(interval, result: .failure, metrics: .none)
            _ = sessionPresentation.open.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: "Hosted authoritative snapshot unavailable"
            )
            return
        }
        sessionPresentation.modelPresentationGeneration = presentationGeneration
        scrollCoordinator.resetForPresentation(
            presentationGeneration,
            retainingVisibleViewport: retainsVisiblePresentation
        )
        let installed: InstalledChatTranscript
        do {
            installed = try await installCurrentTranscriptProjection(
                presentationGeneration: presentationGeneration,
                consistency: .firstCompletePresentationCommit
            )
        } catch {
            performanceSignposts.end(interval, result: PerformanceResult.forFailure(error), metrics: .none)
            _ = sessionPresentation.open.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: "Hosted transcript projection unavailable"
            )
            return
        }
        if !retainsVisiblePresentation || retainedPinnedRevalidation {
            guard sessionPresentation.open.installAuthoritativeBaseline(
                sessionID: sessionID,
                epoch: epoch
            ) else {
                performanceSignposts.end(interval, result: .discarded, metrics: .none)
                return
            }
        }
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
            cancelPresentation: {
                scrollCoordinator.cancel()
            }
        )
        if retainsVisiblePresentation && !retainedPinnedRevalidation {
            let presented = await completeFirstReadyFrame(interval, epoch: epoch)
            if presented { probe.markReady() }
            probe.recordReadyFrameCompletion()
            return
        }
        let positioned = await positionLatestTail(
            epoch: epoch,
            targetRenderedID: physicalOpeningTailID(for: installed)
        )
        guard positioned,
              revealPositionedTranscript(epoch: epoch) else {
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return
        }
        let presented = await completeFirstReadyFrame(interval, epoch: epoch)
        if presented {
            // Hosted readiness means the reveal has actually crossed one
            // presented frame, not merely that the phase flag changed.
            probe.markReady()
            let geometry = scrollCoordinator.latestGeometry
            if geometry.isAtCatchUpBoundary {
                probe.recordScrollSettle(distanceFromBottom: geometry.distanceFromBottom)
            }
            await scrollCoordinator.waitForOpeningTailSettlement()
        }
        probe.recordReadyFrameCompletion()
    }
    #endif

    @MainActor
    private func revealPositionedTranscript(epoch: Int) -> Bool {
        withAnimation(
            transcriptRevealAnimation,
            completionCriteria: .logicallyComplete
        ) {
            sessionPresentation.open.installPositionedViewport(sessionID: sessionID, epoch: epoch)
        } completion: {
            guard sessionPresentation.open.epoch == epoch,
                  sessionPresentation.open.phase == .ready else { return }
            scrollCoordinator.openingRevealCompleted()
        }
    }

    @MainActor
    private func completeFirstReadyFrame(_ interval: PerformanceInterval, epoch: Int) async -> Bool {
        do {
            try await displayFrameScheduler.nextFrame()
            guard !Task.isCancelled,
                  sessionPresentation.open.epoch == epoch,
                  sessionPresentation.open.phase == .ready else {
                performanceSignposts.end(interval, result: .discarded, metrics: .none)
                return false
            }
            performanceSignposts.end(interval, result: .success, metrics: .none)
            reconcileSessionPresentationVisibility()
            // Publish leased interaction/editor routes only after chat opening
            // has crossed a real ready frame. Otherwise their sheet can cover
            // the parent, cancel opening, and create a present/dismiss loop.
            sessionPresentation.permitsExtensionInteractionPresentation = true
            intakeLatestTranscriptProjectionIfNeeded()
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
              !scrollCoordinator.isPrependingHistory,
              let capture = transcriptProjectionCapture,
              transcriptPresentation.installed?.tag != capture.tag else { return }
        intakeTranscriptProjection(capture)
    }

    private func physicalOpeningTailID(for installed: InstalledChatTranscript) -> String? {
        // The marker is always mounted, including empty and queue-only
        // presentations, so opening never falls back to an implicit top offset.
        "transcript-bottom"
    }

    @MainActor
    private func positionLatestTail(epoch: Int, targetRenderedID: String?) async -> Bool {
        // The opening surface remains opaque until the exact physical marker
        // after transcript and queue rows intersects a plausible bottom viewport.
        guard !Task.isCancelled,
              sessionPresentation.open.epoch == epoch,
              sessionPresentation.open.phase == .positioning else { return false }
        let positioned = await scrollCoordinator.positionOpeningTail(
            targetRenderedID: targetRenderedID
        )
        if positioned { performanceTracker.settleScroll() }
        return positioned
            && !Task.isCancelled
            && sessionPresentation.open.epoch == epoch
            && sessionPresentation.open.phase == .positioning
    }

    @MainActor
    private func executePendingScrollCommand() {
        guard let command = scrollCoordinator.command else { return }
        performanceTracker.beginScrollCommand()
        let update = {
            switch command.destination {
            case .tail where command.origin == .physicalTailRepair
                    || command.origin == .tailMaterialization:
                installStableTailTarget()
            case .openingTail(let renderedID):
                // Chat opening targets the eager marker after all rendered rows.
                guard renderedID == "transcript-bottom" else { return }
                installStableTailTarget()
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
        Button {
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
        } label: {
            HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                ChatCompactPillLeadingIcon(
                    icon: "arrow.up",
                    accent: .tronAccentText,
                    showsProgress: isLoadingEarlierMessages
                )
                Text(
                    isLoadingEarlierMessages
                        ? "Loading earlier…"
                        : "Load earlier messages"
                )
            }
            .chatTranscriptPill()
        }
        .buttonStyle(.plain)
        .disabled(isLoadingEarlierMessages || !scrollCoordinator.canRequestHistoryPage)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityLabel(
            isLoadingEarlierMessages
                ? "Loading earlier messages"
                : "Load earlier messages"
        )
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
            processActivities: selectedAuthoritativeSnapshot?.processActivities,
            pendingAttachments: pendingAttachments,
            selectedResource: selectedComposerResource,
            resourcePicker: composerResourcePicker,
            resourceResults: composerResourceResults,
            morphRegistry: morphRegistry,
            reduceMotion: reduceMotion,
            showsCatchUp: scrollCoordinator.shouldShowCatchUpButton,
            showsAmbientWorkingBlur: showsAmbientWorkingBlur,
            keyboardVisible: keyboardObserver.isVisible,
            text: composerTextBinding,
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
            glassNamespace: composerGlassNamespace,
            onProcessesTap: {
                sessionPresentation.showProcesses = true
                #if HOSTED_TEST
                hostedProbe?.recordProcessRoute()
                #endif
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
            onCatchUp: catchUpToTail,
            onComposerHeight: composerHeightChanged,
            onComposerHeightSettled: composerHeightSettled
        )
    }

    private var composerTrailingMode: ComposerTrailingMode? {
        ChatComposerPolicy.trailingMode(
            phase: visibleSessionFacts?.phase,
            hasContent: !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingAttachments.isEmpty,
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

    private var attachmentMenuState: ChatAttachmentMenuState {
        ChatAttachmentMenuState(
            sessionID: sessionID,
            phase: selectedAuthoritativeSnapshot?.phase,
            isTranscriptReady: isTranscriptReady,
            isSending: sending
        )
    }

    private var attachmentActionsEnabled: Bool {
        attachmentMenuState.actionsEnabled && admitsLiveSessionCommands
    }

    private var supportsSkillPrompt: Bool {
        model.gatewayInfo?.capabilities.contains("skill-prompt.v1") == true
    }

    private var resourcePickerAvailable: Bool {
        guard let presentationTarget else { return false }
        return model.commandCatalogTarget == presentationTarget
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
            let kind: ComposerResourceEntry.Kind = destination == .skills ? .skill : .command
            sessionPresentation.attachmentPresentationTask?.cancel()
            sessionPresentation.queuedAttachmentDestination = nil
            sessionPresentation.attachmentPresentationTask = Task { @MainActor in
                // Let the native menu complete dismissal before inserting the
                // inline child. The UITextView remains the responder owner.
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled, attachmentActionsEnabled else { return }
                let picker = ComposerResourcePickerSource.menu(kind)
                composerResourceResults = composerResourceCatalog.entries(kind: kind, query: "")
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
        if let token = ComposerSuggestionTriggerPolicy.activeToken(
            in: composerText,
            selection: composerSelection
        ), token.kind != .skill || resourcePickerAvailable {
            sessionPresentation.attachmentPresentationTask?.cancel()
            sessionPresentation.attachmentPresentationTask = nil
            if composerResourcePicker != .token(token) {
                composerResourceResults = composerResourceCatalog.entries(kind: token.kind, query: token.query)
                composerResourcePicker = .token(token)
            }
        } else if case .token = composerResourcePicker {
            dismissComposerResourcePicker()
        }
    }

    private func selectComposerResource(_ entry: ComposerResourceEntry) {
        guard let composerScope else { return }
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
                commands: composerResourceCatalog.commands
            )
            applyComposerReplacement(replacement)
            model.composerDrafts.selectResource(entry.commandInfo, for: composerScope)
        case .command:
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
                    commands: composerResourceCatalog.commands
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

    @MainActor
    private func updateQueuedMessage(
        _ id: String,
        text: String,
        behavior: SessionSnapshot.QueuedMessage.Behavior
    ) async {
        await mutateQueue(affectedID: id) { items in
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                throw CancellationError()
            }
            items[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            items[index].behavior = behavior
        }
    }

    @MainActor
    private func removeQueuedMessage(_ id: String) async {
        await mutateQueue(affectedID: id) { items in
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
        guard transcriptPresentation.installed?.queueRevision.map({ $0 > expectedRevision }) != true else {
            return true
        }
        guard await model.restoreMountedPresentationAfterReconnect(),
              presentationTarget == target,
              sessionPresentation.modelPresentationGeneration == presentationGeneration else {
            return false
        }
        guard let installed = try? await installCurrentTranscriptProjection(
            presentationGeneration: presentationGeneration
        ) else { return false }
        return installed.queueRevision.map { $0 > expectedRevision } == true
    }

    @MainActor
    private func mutateQueue(
        affectedID: String,
        mutation: (inout [SessionSnapshot.QueuedMessage]) throws -> Void
    ) async {
        guard sessionPresentation.mutatingQueuedMessageIDs.isEmpty,
              let target = presentationTarget,
              let presentationGeneration = sessionPresentation.modelPresentationGeneration else { return }
        let commit: QueuedMessageManagementCommit
        let previousItems: [SessionSnapshot.QueuedMessage]
        do {
            guard let installed = transcriptPresentation.installed,
                  let prepared = try QueuedMessageManagementPolicy.mutationCommit(
                    for: installed,
                    mutation: mutation
                  ) else { return }
            previousItems = installed.queuedMessages
            commit = prepared
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
        if let scope = composerScope, let resource = model.composerDrafts.selectedResource(for: scope) {
            let source: ComposerResourceInvocation.Source = switch resource.source {
            case .skill: .skill
            case .prompt: .prompt
            case .extension: .extension
            }
            return ComposerResourceInvocation(
                source: source,
                name: source == .skill && resource.name.hasPrefix("skill:")
                    ? String(resource.name.dropFirst("skill:".count))
                    : resource.name,
                arguments: value
            )
        }
        return ComposerResourceInvocationPolicy.leadingInvocation(in: value, commands: model.commands)
    }

    @MainActor
    private func send(behavior explicitBehavior: String? = nil) {
        guard sessionPresentation.openingTask == nil,
              sessionPresentation.open.phase == .ready,
              !model.isReconcilingForeground,
              scrollCoordinator.admitsSubmission,
              scrollCoordinator.command == nil,
              let target = presentationTarget,
              model.admitsLiveSessionCommands(target),
              let installed = transcriptPresentation.installed,
              installed.tag.presentationGeneration == target.generation,
              let source = transcriptProjectionCapture,
              source.tag.presentationGeneration == target.generation else { return }
        let behavior = explicitBehavior
            ?? ChatComposerPolicy.submissionBehavior(phase: selectedAuthoritativeSnapshot?.phase)
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
        // Transfer an applied sentinel lease directly to the outgoing row while
        // preserving detached-reader ownership.
        scrollCoordinator.submitted()
        // Submission, row growth, composer height, morph, and keyboard changes
        // join one settlement generation.
        let layoutGeneration = layoutTransaction.join(.submission)
        _ = layoutTransaction.join(.transcriptGrowth)
        let composerHeightBeforeSubmission = composerHeightLedger.current
        let keyboardRevision = keyboardObserver.revision
        composerFocused = false
        _ = composerResponder.resignFirstResponder()
        layoutTransaction.configure(
            keyboard: keyboardObserver.transition,
            reduceMotion: reduceMotion
        )
        if keyboardObserver.transitionArrived(after: keyboardRevision) {
            _ = layoutTransaction.join(.keyboard)
        }
        do {
            // Admission and the local lifecycle graft are atomic. Row entrance
            // and morph views own their scoped animations.
            let installedBeforeSubmission = installed
            // A neutral root transaction preserves descendant-scoped composer
            // and flight animations.
            let submission = try withTransaction(Transaction()) {
                composerResourcePicker = nil
                let submission = try model.beginComposerSubmission(
                    target: target,
                    behavior: behavior,
                    resourceInvocation: resourceInvocation,
                    canonicalTranscript: model.transcriptSnapshot(for: sessionID)?.transcript ?? [],
                    queuedMessages: selectedAuthoritativeSnapshot?.displayedQueuedMessages ?? []
                )
                let submittedAttachments = model.composerDrafts.submittedAttachments(for: target)
                    .filter { attachment in
                        attachment.gatewayUploadID.map(submission.attachmentIDs.contains) == true
                    }
                    .prefix(ComposerAttachmentPolicy.maximumCount)
                    .map { $0.frozenForHandoff() }
                let isExtensionCommand = submission.resourceInvocation?.isExtensionCommand == true
                let morphGeneration = layoutTransaction.join(.morphFlight)
                let stagedMorph = morphRegistry.stage(
                    lifecycle: model.composerDrafts.submissionLifecycle(for: target),
                    generation: morphGeneration,
                    suppress: reduceMotion || scenePhase != .active
                )
                if !stagedMorph {
                    layoutTransaction.settle(morphGeneration, source: .morphFlight)
                }
                // Exact extension commands do not create a canonical user
                // message in Pi. Never graft a prompt bubble that can become a
                // phantom row; the canonical invocation receipt owns its row.
                let grafted = isExtensionCommand || !presentationActivity.allowsPresentationPublication
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
                let materializationAdmitted = grafted && scrollCoordinator.discreteTailInserted(
                    renderedID: submission.presentationID,
                    layoutTransactionID: layoutGeneration
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
                return submission
            }
            if let capture = transcriptProjectionCapture {
                var stableTransaction = Transaction()
                stableTransaction.disablesAnimations = true
                withTransaction(stableTransaction) {
                    intakeTranscriptProjection(capture)
                }
            }
            settleUnchangedComposerAfterDisplayFrames(
                generation: layoutGeneration,
                baselineHeight: composerHeightBeforeSubmission
            )
            // ComposerDraftCoordinator retains accepted transport across route
            // changes and target-gates late presentation effects.
            Task { @MainActor in
                do {
                    try await model.sendComposer(submission)
                    if selectedAuthoritativeSnapshot?.extensionPresentation.hostEpoch.isEmpty == false {
                        model.scheduleExtensionEditorUpdate(target: target, text: "")
                    }
                } catch {
                    model.presentComposerActionError(error, target: target)
                }
            }
        } catch {
            abandonLayoutTransaction()
            model.presentComposerActionError(error, target: target)
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
