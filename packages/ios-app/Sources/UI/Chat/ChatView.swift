import PhotosUI
import SwiftUI

struct ChatView: View {
    let sessionID: String
    private let initialEditorText: String?
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
    @State private var composerScope: ComposerDraftScope?
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentDestination: ChatAttachmentDestination?
    @State private var queuedAttachmentDestination: ChatAttachmentDestination?
    @State private var attachmentPresentationTask: Task<Void, Never>?
    @State private var showContext = false
    @State private var showSettings = false
    @State private var queuedMessageEditor: QueuedMessageEditorRoute?
    @State private var mutatingQueuedMessageIDs: Set<String> = []
    @State private var openPresentation: ChatOpenPresentationState
    @State private var openingTask: Task<Void, Never>?
    @State private var modelPresentationGeneration: Int?
    @State private var composerTextHeight: CGFloat = 20
    @State private var toolbarContainerWidth = ChatToolbarTitleLayout.defaultContainerWidth
    @State private var scrollCoordinator: ChatScrollCoordinator
    @State private var transcriptPresentation: ChatTranscriptPresentationStore
    @State private var performanceTracker: ChatPerformanceTracker
    @State private var transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var transcriptGeometry = ChatTranscriptGeometry.zero
    @Namespace private var composerGlassNamespace
    // UITextView is the responder owner. This mirrors delegate callbacks for
    // placeholder/scroll presentation; SwiftUI FocusState must not compete with
    // a UIViewRepresentable that has no `.focused` registration.
    @State private var composerFocused = false

    #if HOSTED_TEST
    init(
        sessionID: String,
        initialEditorText: String? = nil,
        onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
        hostedProbe: ChatHostedProbe? = nil,
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.sessionID = sessionID
        self.initialEditorText = initialEditorText
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
        _openPresentation = State(initialValue: ChatOpenPresentationState(sessionID: sessionID))
    }
    #else
    init(
        sessionID: String,
        initialEditorText: String? = nil,
        onForkCreated: @escaping (AppModel.SessionNavigationRoute) -> Void = { _ in },
        displayFrameScheduler: DisplayFrameScheduler = .displayLink,
        performanceSignposts: any PerformanceSignposting = SystemPerformanceSignposts.shared
    ) {
        self.sessionID = sessionID
        self.initialEditorText = initialEditorText
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
        _openPresentation = State(initialValue: ChatOpenPresentationState(sessionID: sessionID))
    }
    #endif

    var body: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The complete composer is the sole structural inset owner, so
                // the keyboard, multiline text, and attachment chips push the
                // native transcript viewport exactly once and reverse naturally.
                composer
            }
            .overlay(alignment: .top) { topBlur }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            toolbarContainerWidth = width
        }
        .background { Color.tronBackground.ignoresSafeArea(.all) }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGestureEnabler())
        .tint(Color.tronEmerald)
        .toolbar {
            toolbar(titleWidth: ChatToolbarTitleLayout.width(containerWidth: toolbarContainerWidth))
        }
        .sheet(isPresented: $showContext) {
            SessionContextSheet(sessionID: sessionID, onForkCreated: onForkCreated)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                scope: .project,
                projectSessionID: sessionID,
                projectCWD: model.authoritativeSnapshot(for: sessionID)?.cwd
            )
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $queuedMessageEditor) { route in
            if let message = selectedAuthoritativeSnapshot?.displayedQueuedMessages.first(
                where: { $0.id == route.id }
            ) {
                QueuedMessageEditorSheet(
                    message: message,
                    isSaving: mutatingQueuedMessageIDs.contains(message.id),
                    onSave: { text, behavior in
                        Task { await updateQueuedMessage(message.id, text: text, behavior: behavior) }
                    },
                    onDelete: {
                        Task { await removeQueuedMessage(message.id) }
                    }
                )
            } else {
                ContentUnavailableView(
                    "Message No Longer Queued",
                    systemImage: "text.badge.xmark",
                    description: Text("It was delivered or removed before the editor opened.")
                )
            }
        }
        .sheet(isPresented: attachmentPresentationBinding(for: .camera)) {
            CameraCaptureSheet { image in Task { await importCameraImage(image) } }
        }
        .photosPicker(
            isPresented: attachmentPresentationBinding(for: .photos),
            selection: $photos,
            maxSelectionCount: ChatAttachmentImportPolicy.maximumPhotoSelection,
            matching: .images
        )
        .sheet(item: interactionBinding) { interaction in
            ExtensionInteractionSheet(sessionID: sessionID, interaction: interaction)
        }
        .fileImporter(
            isPresented: attachmentPresentationBinding(for: .files),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .onChange(of: photos) { _, values in Task { await importPhotos(values) } }
        .onChange(of: attachmentMenuState) { previous, current in
            if previous.sessionID != current.sessionID {
                cancelAttachmentPresentation(includingActive: true)
            } else if !current.actionsEnabled {
                cancelAttachmentPresentation(includingActive: false)
            }
        }
        .confirmationDialog(ComposerEditorRequestPolicy.confirmationTitle, isPresented: Binding(
            get: { routedEditorRequest != nil },
            set: { isPresented in
                guard !isPresented,
                      let request = routedEditorRequest,
                      let target = presentationTarget else { return }
                model.composerDrafts.disposeEditorRequest(request, disposition: .keep, target: target)
            }
        )) {
            Button(ComposerEditorRequestPolicy.useActionTitle) {
                guard let request = routedEditorRequest,
                      let target = presentationTarget else { return }
                model.composerDrafts.disposeEditorRequest(request, disposition: .use, target: target)
            }
            Button(ComposerEditorRequestPolicy.keepActionTitle, role: .cancel) {
                guard let request = routedEditorRequest,
                      let target = presentationTarget else { return }
                model.composerDrafts.disposeEditorRequest(request, disposition: .keep, target: target)
            }
        } message: {
            Text(ComposerEditorRequestPolicy.confirmationMessage)
        }
        .task(id: sessionID) { await beginOpeningPresentation() }
        .onChange(of: transcriptProjectionSource, initial: true) { _, source in
            guard let currentSource = transcriptProjectionSource else {
                transcriptPresentation.reset()
                return
            }
            // Ignore a callback captured before opening installed its mounted
            // generation; the newer exact source owns submission.
            guard source == currentSource,
                  let snapshot = selectedAuthoritativeSnapshot,
                  snapshot.sessionId == currentSource.sessionID else { return }
            // Prepend owns the exact page projection/layout-epoch transaction.
            guard !scrollCoordinator.isPrependingHistory else { return }
            let startedWork = transcriptPresentation.submit(snapshot: snapshot, tag: currentSource)
            #if HOSTED_TEST
            hostedProbe?.recordProjectionSubmit(startedWork: startedWork)
            #endif
        }
        .onChange(of: scrollCoordinator.tailSettlementGeneration) { _, _ in
            guard let generation = modelPresentationGeneration else { return }
            model.discardLoadedTranscriptHistory(
                sessionID: sessionID,
                presentationGeneration: generation
            )
        }
        .onChange(of: transcriptPresentation.installed?.tag) { _, _ in
            let installed = transcriptPresentation.installed
            scrollCoordinator.installedTranscriptChanged(installed)
            #if HOSTED_TEST
            if let installed {
                hostedProbe?.recordProjectionInstall(
                    rowCount: installed.timeline.items.count,
                    sourceOrdinal: installed.tag.timelineGeneration
                )
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            transcriptPresentation.handleMemoryPressure()
        }
        .onDisappear {
            if let target = presentationTarget { model.revokePresentationIntake(target) }
            openingTask?.cancel()
            openingTask = nil
            scrollCoordinator.cancel()
            transcriptPresentation.reset()
            performanceTracker.cancelAll()
            cancelAttachmentPresentation(includingActive: true)
            if let generation = modelPresentationGeneration {
                Task { await model.closeSessionPresentation(sessionID, generation: generation) }
            }
        }
    }

    private var topBlur: some View {
        TronTopBlurOverlay(style: .chat)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let snapshot = selectedAuthoritativeSnapshot {
                    if (snapshot.transcriptStart ?? 0) > 0 {
                        stableTranscriptRow(
                            id: "earlier-messages",
                            installedTag: nil,
                            entranceState: .none
                        ) {
                            earlierMessagesChip(snapshot: snapshot)
                        }
                    }
                    if let installed = transcriptPresentation.installed {
                        ForEach(installed.displayedItems) { item in
                            let entranceState = transcriptPresentation.entranceState(for: item.id)
                            stableTranscriptRow(
                                id: item.id,
                                installedTag: installed.tag,
                                entranceState: entranceState
                            ) {
                                ChatTranscriptEntranceRow(
                                    state: entranceState,
                                    kind: .classify(item),
                                    reduceMotion: reduceMotion
                                ) {
                                    ChatTranscriptRenderRow(
                                        item: item,
                                        preparedText: installed.preparedText.slice(for: item),
                                        hiddenThinkingLabel: snapshot.extensionUI.hiddenThinkingLabel
                                    )
                                    .equatable()
                                }
                            }
                        }
                        queuedMessageRows(installed)
                    }
                }
                Color.clear
                    .frame(height: 12)
                    .id("transcript-bottom")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .scrollTargetLayout()
            .opacity(isTranscriptReady ? 1 : 0)
            .offset(y: isTranscriptReady || reduceMotion ? 0 : 8)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26), value: isTranscriptReady)
            .accessibilityHidden(!isTranscriptReady)
            .allowsHitTesting(isTranscriptReady)
        }
        // Initial overflow opens at the latest tail, but undersized/lazily
        // materializing content remains top-aligned. Bottom alignment here
        // re-anchors during keyboard animation and can manufacture blank space.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollPosition($transcriptScrollPosition)
        .tronScrollEdgeChrome()
        .onChange(of: transcriptScrollPosition.isPositionedByUser) { _, positionedByUser in
            guard admitsNativeScrollCallbacks else { return }
            if positionedByUser {
                performanceTracker.discardScroll()
                transcriptPresentation.discardPendingEntrances()
            }
            scrollCoordinator.scrollPositionChanged(isPositionedByUser: positionedByUser)
        }
        .onScrollGeometryChange(for: ChatTranscriptGeometry.self) { geometry in
            ChatTranscriptGeometry(geometry)
        } action: { previous, geometry in
            transcriptGeometry = geometry
            #if HOSTED_TEST
            hostedProbe?.updateGeometry(geometry)
            if isTranscriptReady, geometry.isAtCatchUpBoundary {
                hostedProbe?.recordScrollSettle(distanceFromBottom: geometry.distanceFromBottom)
            }
            #endif
            guard isTranscriptReady, admitsNativeScrollCallbacks else { return }
            if geometry.hasViewportChange(from: previous) {
                scrollCoordinator.viewportChanged(previous: previous, current: geometry)
            } else {
                scrollCoordinator.geometryChanged(previous: previous, current: geometry)
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            guard admitsNativeScrollCallbacks else { return }
            if newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating {
                performanceTracker.discardScroll()
                transcriptPresentation.discardPendingEntrances()
            }
            let finalGeometry = ChatTranscriptGeometry(context.geometry)
            scrollCoordinator.scrollPhaseChanged(
                from: oldPhase,
                to: newPhase,
                finalGeometry: finalGeometry
            )
        }
        .onChange(of: scrollCoordinator.commandRevision) { _, _ in
            executePendingScrollCommand()
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: responseState, initial: true) { previous, current in
            guard let current else { return }
            guard previous?.sessionID == current.sessionID else { return }
            if ChatUnreadResponsePolicy.shouldMarkUnread(
                previous: previous,
                current: current,
                userScrolledAway: scrollCoordinator.shouldTrackUnreadResponse
            ) {
                scrollCoordinator.semanticResponseArrived()
            }
        }
        .onChange(of: composerFocused) { _, _ in
            scrollCoordinator.composerViewportTransitionBegan()
        }
        .onChange(of: composerTextHeight) { _, _ in
            scrollCoordinator.composerViewportTransitionBegan()
        }
        .overlay { openingSurface }
    }

    @ViewBuilder
    private func queuedMessageRows(_ installed: InstalledChatTranscript) -> some View {
        let messages = installed.queuedMessages
        let managementAvailability = QueuedMessageManagementPolicy.availability(
            capabilities: model.gatewayInfo?.capabilities ?? [],
            queueRevision: installed.queueRevision,
            hasAuthoritativeItems: installed.supportsQueueManagement
        )
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            stableTranscriptRow(
                id: "queued-message-\(message.id)",
                installedTag: nil,
                entranceState: .none
            ) {
                ChatQueuedMessageEntranceRow(
                    animatesEntrance: isTranscriptReady,
                    reduceMotion: reduceMotion
                ) {
                    QueuedMessageRow(
                        message: message,
                        position: index + 1,
                        total: messages.count,
                        managementAvailability: managementAvailability,
                        isMutating: !mutatingQueuedMessageIDs.isEmpty,
                        onEdit: { queuedMessageEditor = .init(id: message.id) },
                        onClear: { Task { await clearQueuedMessages() } },
                        canMoveEarlier: index > 0 && messages[index - 1].behavior == message.behavior,
                        canMoveLater: index + 1 < messages.count && messages[index + 1].behavior == message.behavior,
                        onMove: { offset in
                            Task { await moveQueuedMessage(message.id, offset: offset) }
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func stableTranscriptRow<Content: View>(
        id: String,
        installedTag: ChatTranscriptProjectionTag?,
        entranceState: ChatTranscriptEntranceState,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        let entranceAdmissionTag = entranceState == .pending ? installedTag : nil
        let row = content()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(id)
        row.onGeometryChange(for: ChatSemanticFrameObservation.self) { geometry in
            ChatSemanticFrameObservation(
                layoutEpoch: rowLayoutEpoch,
                frame: geometry.frame(in: .scrollView(axis: .vertical)),
                entranceAdmissionTag: entranceAdmissionTag
            )
        } action: { sample in
            scrollCoordinator.semanticFrameChanged(
                renderedID: id,
                layoutEpoch: sample.layoutEpoch,
                frame: sample.frame
            )
            let installed = transcriptPresentation.installed
            let currentEntranceState = transcriptPresentation.entranceState(for: id)
            if ChatEntranceGeometryAdmissionPolicy.admits(
                observation: sample,
                installedTag: installed?.tag,
                installedContainsRenderedID: installed?.containsDisplayedID(id) == true,
                currentLayoutEpoch: scrollCoordinator.layoutEpoch,
                entranceState: currentEntranceState
            ), let entranceTag = sample.entranceAdmissionTag {
                let intersectsViewport = transcriptGeometry.isValid
                    && sample.frame.maxY > 0
                    && sample.frame.minY < transcriptGeometry.containerHeight
                // A realized tail insertion owned by a pinned reader is the
                // exact upcoming viewport target even when its first frame sits
                // just below the current edge. Detached readers require actual
                // intersection and never gain automatic authority here.
                let isVisible = intersectsViewport || scrollCoordinator.canAutomaticallyFollow
                let animated = transcriptPresentation.resolveEntrance(
                    id: id,
                    installationTag: entranceTag,
                    isVisible: isVisible
                )
                #if HOSTED_TEST
                hostedProbe?.recordEntranceResolution(
                    animated: animated,
                    sourceOrdinal: entranceTag.timelineGeneration
                )
                #endif
                if animated { scrollCoordinator.discreteContentInserted(renderedID: id) }
            }
            #if HOSTED_TEST
            hostedProbe?.updateRowFrame(id: id, frame: sample.frame)
            hostedProbe?.recordMaximumSemanticExcursion(scrollCoordinator.maximumPrependSemanticExcursion)
            #endif
        }
    }

    private var selectedAuthoritativeSnapshot: SessionSnapshot? {
        model.authoritativeSnapshot(for: sessionID)
    }

    private var presentationTarget: AppModel.SessionPresentationTarget? {
        modelPresentationGeneration.map {
            AppModel.SessionPresentationTarget(sessionID: sessionID, generation: $0)
        }
    }

    private var transcriptProjectionSource: ChatTranscriptProjectionTag? {
        guard let snapshot = selectedAuthoritativeSnapshot,
              let generation = modelPresentationGeneration,
              let projection = model.chatProjectionGenerations(
                for: sessionID,
                presentationGeneration: generation
              ),
              snapshot.sessionId == sessionID else { return nil }
        return ChatTranscriptProjectionTag(
            snapshot: snapshot,
            presentationGeneration: generation,
            canonicalGeneration: projection.canonical,
            timelineGeneration: projection.timeline
        )
    }

    @MainActor
    private func installCurrentTranscriptProjection(
        presentationGeneration: Int
    ) async throws -> InstalledChatTranscript {
        while true {
            try Task.checkCancellation()
            guard modelPresentationGeneration == presentationGeneration,
                  let snapshot = model.authoritativeSnapshot(for: sessionID),
                  let projection = model.chatProjectionGenerations(
                    for: sessionID,
                    presentationGeneration: presentationGeneration
                  ),
                  snapshot.sessionId == sessionID else { throw CancellationError() }
            let tag = ChatTranscriptProjectionTag(
                snapshot: snapshot,
                presentationGeneration: presentationGeneration,
                canonicalGeneration: projection.canonical,
                timelineGeneration: projection.timeline
            )
            transcriptPresentation.submit(snapshot: snapshot, tag: tag)
            do {
                let installed = try await transcriptPresentation.waitForInstall(of: tag)
                guard modelPresentationGeneration == presentationGeneration else {
                    throw CancellationError()
                }
                if transcriptProjectionSource == tag { return installed }
            } catch ChatTranscriptPresentationStoreError.superseded {
                continue
            }
        }
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
            }
        )
    }

    private var pendingAttachments: [PendingAttachment] {
        presentationTarget.map(model.composerDrafts.pendingAttachments(for:)) ?? []
    }

    private var routedEditorRequest: ComposerEditorRequest? {
        presentationTarget.flatMap(model.composerDrafts.editorRequest(for:))
    }

    private var sending: Bool {
        presentationTarget.map(model.composerDrafts.isSending(target:)) ?? false
    }

    private var responseState: ChatResponseState? {
        selectedAuthoritativeSnapshot.map(ChatResponseState.init)
    }

    private var isTranscriptReady: Bool { openPresentation.phase == .ready }

    private var admitsNativeScrollCallbacks: Bool {
        #if HOSTED_TEST
        hostedProbe?.usesDrivenScrollAuthority != true
        #else
        true
        #endif
    }

    @ViewBuilder private var openingSurface: some View {
        switch openPresentation.phase {
        case .opening:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("Opening conversation…")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .accessibilityElement(children: .combine)
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
    private func beginOpeningPresentation() async {
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
        openingTask?.cancel()
        performanceTracker.discardScroll()
        modelPresentationGeneration = nil
        transcriptPresentation.reset()
        let epoch = openPresentation.begin()
        scrollCoordinator.resetForPresentation(epoch)
        let task = Task { @MainActor in
            let interval = performanceSignposts.begin(.firstReadyFrame)
            var openedGeneration: Int?
            do {
                let generation = try await model.openSessionPresentation(
                    sessionID,
                    composerScope: composerScope
                )
                openedGeneration = generation
                guard !Task.isCancelled,
                      model.authoritativeSnapshot(for: sessionID)?.sessionId == sessionID else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    return
                }
                modelPresentationGeneration = generation
                let installed = try await installCurrentTranscriptProjection(
                    presentationGeneration: generation
                )
                guard !Task.isCancelled,
                      transcriptProjectionSource == installed.tag,
                      openPresentation.installAuthoritativeBaseline(sessionID: sessionID, epoch: epoch) else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    if modelPresentationGeneration == generation {
                        modelPresentationGeneration = nil
                        transcriptPresentation.reset()
                    }
                    return
                }
                openedGeneration = nil
                positionLatestTail(
                    epoch: epoch,
                    targetRenderedID: installed.timeline.ids.last
                )
                _ = await completeFirstReadyFrame(interval, epoch: epoch)
            } catch {
                if let generation = openedGeneration {
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    if modelPresentationGeneration == generation {
                        modelPresentationGeneration = nil
                        transcriptPresentation.reset()
                    }
                }
                let result = PerformanceResult.forFailure(error)
                performanceSignposts.end(interval, result: result, metrics: .none)
                if result == .cancelled { return }
                _ = openPresentation.fail(
                    sessionID: sessionID,
                    epoch: epoch,
                    message: error.localizedDescription
                )
            }
        }
        openingTask = task
        await task.value
        if openPresentation.epoch == epoch { openingTask = nil }
    }

    #if HOSTED_TEST
    @MainActor
    private func beginHostedPresentation(probe: ChatHostedProbe) async {
        performanceTracker.discardScroll()
        transcriptPresentation.reset()
        let epoch = openPresentation.begin()
        scrollCoordinator.resetForPresentation(epoch)
        let interval = performanceSignposts.begin(.firstReadyFrame)
        guard selectedAuthoritativeSnapshot != nil else {
            performanceSignposts.end(interval, result: .failure, metrics: .none)
            _ = openPresentation.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: "Hosted authoritative snapshot unavailable"
            )
            return
        }
        modelPresentationGeneration = epoch
        let installed: InstalledChatTranscript
        do {
            installed = try await installCurrentTranscriptProjection(presentationGeneration: epoch)
        } catch {
            performanceSignposts.end(interval, result: PerformanceResult.forFailure(error), metrics: .none)
            _ = openPresentation.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: "Hosted transcript projection unavailable"
            )
            return
        }
        guard openPresentation.installAuthoritativeBaseline(sessionID: sessionID, epoch: epoch) else {
            performanceSignposts.end(interval, result: .discarded, metrics: .none)
            return
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
            composerViewport: {
                scrollCoordinator.composerViewportTransitionBegan()
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
                guard let installed = transcriptPresentation.installed,
                      installed.tag == transcriptProjectionSource else { return false }
                let anchor = scrollCoordinator.semanticAnchor(in: installed.timeline)
                return scrollCoordinator.beginPrepend(
                    anchor: anchor,
                    load: {
                        do { try await probe.waitForPrependPageRelease() }
                        catch { return nil }
                        guard let anchor,
                              let generation = modelPresentationGeneration else { return nil }
                        guard let current = try? await installCurrentTranscriptProjection(
                            presentationGeneration: generation
                        ),
                              let renderedID = current.timeline.renderedIDBySemanticID[anchor.semanticID] else {
                            return nil
                        }
                        let installedLayout = scrollCoordinator.beginInstalledPageLayoutEpoch()
                        return ChatPrependPage(
                            renderedAnchorID: renderedID,
                            installedLayout: installedLayout
                        )
                    },
                    completion: { probe.recordPrependCompletion($0) }
                )
            },
            invalidatePresentation: {
                scrollCoordinator.resetForPresentation()
            }
        )
        probe.markReady()
        positionLatestTail(
            epoch: epoch,
            targetRenderedID: installed.timeline.ids.last
        )
        _ = await completeFirstReadyFrame(interval, epoch: epoch)
        probe.recordReadyFrameCompletion()
    }
    #endif

    @MainActor
    private func completeFirstReadyFrame(_ interval: PerformanceInterval, epoch: Int) async -> Bool {
        do {
            try await displayFrameScheduler.nextFrame()
            guard !Task.isCancelled,
                  openPresentation.epoch == epoch,
                  openPresentation.phase == .ready else {
                performanceSignposts.end(interval, result: .discarded, metrics: .none)
                return false
            }
            performanceSignposts.end(interval, result: .success, metrics: .none)
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

    @MainActor
    private func positionLatestTail(epoch: Int, targetRenderedID: String?) {
        // Arm coordinator-owned final placement for the exact installed tail.
        // Empty timelines take the explicit no-transcript path.
        guard !Task.isCancelled,
              openPresentation.epoch == epoch,
              openPresentation.phase == .ready else { return }
        scrollCoordinator.requestOpeningTail(targetRenderedID: targetRenderedID)
    }

    @MainActor
    private func executePendingScrollCommand() {
        guard let command = scrollCoordinator.command else { return }
        performanceTracker.beginScrollCommand()
        let update = {
            switch command.destination {
            case .resetToBottom:
                transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
            case .tail:
                transcriptScrollPosition.scrollTo(edge: .bottom)
            case .offsetY(let offsetY):
                transcriptScrollPosition.scrollTo(y: offsetY)
            case .releaseBinding:
                transcriptScrollPosition = ScrollPosition(idType: String.self)
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
        if command.destination == .releaseBinding {
            performanceTracker.settleScroll()
        }
        #if HOSTED_TEST
        hostedProbe?.recordScrollCommand(
            isAutomatic: command.origin == .automaticFollow,
            isSmooth: command.animation != .disabled
        )
        #endif
        scrollCoordinator.commandApplied(command)
    }

    @MainActor
    private func catchUpToTail() {
        transcriptPresentation.discardPendingEntrances()
        scrollCoordinator.requestCatchUp(reduceMotion: reduceMotion)
    }

    private func earlierMessagesChip(snapshot: SessionSnapshot) -> some View {
        Button {
            let sessionID = snapshot.sessionId
            let runtimeGeneration = snapshot.runtimeGeneration
            let previousStart = snapshot.transcriptStart ?? 0
            guard let installed = transcriptPresentation.installed,
                  installed.tag == transcriptProjectionSource else { return }
            let anchor = scrollCoordinator.semanticAnchor(in: installed.timeline)
            guard let presentationGeneration = modelPresentationGeneration else { return }
            let performanceGeneration = performanceTracker.beginPrepend()
            let began = scrollCoordinator.beginPrepend(
                anchor: anchor,
                load: {
                    await model.loadEarlierTranscript(
                        sessionID: sessionID,
                        presentationGeneration: presentationGeneration
                    )
                    guard !Task.isCancelled,
                          modelPresentationGeneration == presentationGeneration,
                          let current = model.authoritativeSnapshot(for: sessionID),
                          current.sessionId == sessionID,
                          current.runtimeGeneration == runtimeGeneration,
                          (current.transcriptStart ?? previousStart) < previousStart else { return nil }
                    guard let anchor else { return nil }
                    guard let installed = try? await installCurrentTranscriptProjection(
                        presentationGeneration: presentationGeneration
                    ),
                          let renderedID = installed.timeline.renderedIDBySemanticID[anchor.semanticID] else {
                        return nil
                    }
                    let installedLayout = scrollCoordinator.beginInstalledPageLayoutEpoch()
                    return ChatPrependPage(
                        renderedAnchorID: renderedID,
                        installedLayout: installedLayout
                    )
                },
                completion: { result in
                    performanceTracker.endPrepend(generation: performanceGeneration, result: result)
                }
            )
            if !began {
                performanceTracker.endPrepend(generation: performanceGeneration, result: .discarded)
            }
        } label: {
            HStack(spacing: 7) {
                if model.loadingEarlierTranscript {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.tronEmerald)
                } else {
                    Image(systemName: "arrow.up")
                }
                Text(model.loadingEarlierTranscript ? "Loading earlier…" : "Load earlier messages")
            }
            .chatTranscriptPill()
        }
        .buttonStyle(.plain)
        .disabled(model.loadingEarlierTranscript)
        .frame(maxWidth: .infinity, minHeight: 44)
        .accessibilityLabel(model.loadingEarlierTranscript ? "Loading earlier messages" : "Load earlier messages")
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let snapshot = selectedAuthoritativeSnapshot {
                ForEach(ChatExtensionWidgetPolicy.visibleWidgets(
                    snapshot.extensionUI.widgets,
                    placement: .aboveEditor
                )) { widget in
                    ExtensionWidgetView(widget: widget)
                }
            }

            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                if let target = presentationTarget {
                                    model.composerDrafts.removeAttachment(attachment.id, target: target)
                                }
                            }
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .move(edge: .bottom)
                                            .combined(with: .scale(scale: 0.92, anchor: .bottom))
                                            .combined(with: .opacity),
                                        removal: .move(edge: .top)
                                            .combined(with: .scale(scale: 0.94, anchor: .top))
                                            .combined(with: .opacity)
                                    )
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .transition(
                    reduceMotion
                        ? .opacity
                        : .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                )
                .animation(
                    ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: reduceMotion),
                    value: pendingAttachments.map(\.id)
                )
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    composerInputBar
                    if scrollCoordinator.shouldShowCatchUpButton {
                        catchUpButton
                    }
                }
            }
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.32, dampingFraction: 0.82),
                value: scrollCoordinator.shouldShowCatchUpButton
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let snapshot = selectedAuthoritativeSnapshot {
                ForEach(ChatExtensionWidgetPolicy.visibleWidgets(
                    snapshot.extensionUI.widgets,
                    placement: .belowEditor
                )) { widget in
                    ExtensionWidgetView(widget: widget)
                }
            }
        }
        .onChange(of: pendingAttachments.map(\.id)) { _, _ in
            scrollCoordinator.composerViewportTransitionBegan()
        }
    }

    private var composerInputBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            attachmentButton

            ZStack(alignment: .leading) {
                if composerText.isEmpty && !composerFocused {
                    Text("Type here")
                        .font(TronTypography.input)
                        .foregroundStyle(Color.tronEmerald)
                        .padding(.leading, 2)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                MultilineComposerTextView(
                    text: composerTextBinding,
                    isFocused: Binding(
                        get: { composerFocused },
                        set: { composerFocused = $0 }
                    ),
                    height: $composerTextHeight,
                    isEditable: ChatComposerPolicy.isTextEditable(isTranscriptReady: isTranscriptReady),
                    keyboardAppearance: colorScheme == .dark ? .dark : .light
                )
                .frame(height: composerTextHeight)
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 40)

            if let snapshot = selectedAuthoritativeSnapshot {
                SessionContextProgressButton(
                    contextPercentage: contextPercentage(snapshot),
                    modelName: snapshot.model.map { "\($0.provider) / \($0.id)" },
                    isCompacting: snapshot.phase == .compacting
                ) { showContext = true }
            }

            if let composerTrailingMode {
                ComposerTrailingButton(
                    mode: composerTrailingMode,
                    isDisabled: sending || !isTranscriptReady,
                    isSending: sending,
                    offersQueueChoices: selectedAuthoritativeSnapshot?.phase.isActive == true,
                    onSend: { behavior in Task { await send(behavior: behavior) } },
                    onAbort: { Task { await model.abort(sessionID: sessionID) } }
                )
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.78, anchor: .center)
                            .combined(with: .opacity)
                )
            }
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.32, dampingFraction: 0.82),
            value: composerTrailingMode
        )
        .frame(maxWidth: .infinity, minHeight: 40)
        .padding(.horizontal, 4)
        .scaleEffect(sending && !reduceMotion ? 0.992 : 1, anchor: .bottom)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.tronEmerald.opacity(sending ? 0.30 : 0), lineWidth: 0.75)
        }
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .spring(response: 0.30, dampingFraction: 0.86),
            value: sending
        )
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .glassEffectID("chat-composer", in: composerGlassNamespace)
        .buttonStyle(.plain)
    }

    private var attachmentButton: some View {
        ZStack {
            // The original compact SF Symbol is a real composer child rendered
            // before the bar's glass. Only the transparent menu hit target is
            // overlaid, so native menu styling cannot wash out or enlarge it.
            Image(systemName: "plus")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(attachmentActionsEnabled ? Color.tronEmerald : Color.tronTextMuted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ComposerAttachmentMenuButton(
                isEnabled: attachmentActionsEnabled,
                onSelect: requestAttachmentPresentation
            )
            .frame(width: 40, height: 40)
            // Native menu action attributes may be cached across navigation.
            // Replace only when the viewed session or availability changes.
            .id(attachmentMenuState.identity)
            .accessibilityLabel("Add attachment")
        }
        .frame(width: 40, height: 40)
    }

    private var catchUpButton: some View {
        Button {
            catchUpToTail()
        } label: {
            Image(systemName: "arrow.down")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: .circle
        )
        .glassEffectID("chat-catch-up", in: composerGlassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .leading)
                    .combined(with: .scale(scale: 0.82, anchor: .leading))
                    .combined(with: .opacity)
        )
        .accessibilityLabel("Catch up")
        .accessibilityHint("Returns to the latest response and follows new messages")
    }

    private var composerTrailingMode: ComposerTrailingMode? {
        ChatComposerPolicy.trailingMode(
            phase: selectedAuthoritativeSnapshot?.phase,
            hasContent: !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingAttachments.isEmpty,
            isSending: sending
        )
    }

    private func contextPercentage(_ snapshot: SessionSnapshot) -> Int {
        if let percent = snapshot.contextUsage?.percent { return min(max(Int(percent.rounded()), 0), 100) }
        guard let usage = snapshot.contextUsage, usage.contextWindow > 0, let tokens = usage.tokens else { return 0 }
        return min(max(Int((Double(tokens) / Double(usage.contextWindow) * 100).rounded()), 0), 100)
    }

    private var chatTitle: String {
        selectedAuthoritativeSnapshot?.extensionUI.title
            ?? selectedAuthoritativeSnapshot?.name
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
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Settings")
        }
    }

    private var interactionBinding: Binding<ExtensionInteraction?> {
        Binding(
            get: { selectedAuthoritativeSnapshot?.extensionUI.pendingInteractions.first },
            set: { _ in }
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

    private var attachmentActionsEnabled: Bool { attachmentMenuState.actionsEnabled }

    private func requestAttachmentPresentation(_ destination: ChatAttachmentDestination) {
        guard attachmentActionsEnabled else { return }

        // A native Menu is still dismissing when its action runs. Presenting a
        // sheet or system picker synchronously can collide with that transient
        // presentation controller on physical iOS. Queue one destination, force
        // a fresh presentation edge, and activate it after dismissal settles.
        attachmentPresentationTask?.cancel()
        attachmentDestination = nil
        queuedAttachmentDestination = destination
        attachmentPresentationTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard !Task.isCancelled,
                  queuedAttachmentDestination == destination,
                  attachmentActionsEnabled else { return }
            queuedAttachmentDestination = nil
            attachmentDestination = destination
        }
    }

    private func cancelAttachmentPresentation(includingActive: Bool) {
        attachmentPresentationTask?.cancel()
        attachmentPresentationTask = nil
        queuedAttachmentDestination = nil
        if includingActive { attachmentDestination = nil }
    }

    private func attachmentPresentationBinding(
        for destination: ChatAttachmentDestination
    ) -> Binding<Bool> {
        Binding(
            get: { attachmentDestination == destination },
            set: { isPresented in
                if isPresented {
                    guard attachmentActionsEnabled else { return }
                    attachmentDestination = destination
                } else if attachmentDestination == destination {
                    attachmentDestination = nil
                }
            }
        )
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
    private func mutateQueue(
        affectedID: String,
        mutation: (inout [SessionSnapshot.QueuedMessage]) throws -> Void
    ) async {
        guard mutatingQueuedMessageIDs.isEmpty,
              let target = presentationTarget,
              let snapshot = selectedAuthoritativeSnapshot,
              let expectedRevision = snapshot.queueRevision,
              var items = snapshot.queuedItems else { return }
        do { try mutation(&items) }
        catch { return }
        mutatingQueuedMessageIDs.insert(affectedID)
        defer { mutatingQueuedMessageIDs.remove(affectedID) }
        do {
            try await model.replaceQueue(
                sessionID: sessionID,
                expectedRevision: expectedRevision,
                items: items
            )
        } catch {
            model.presentComposerActionError(error, target: target)
        }
    }

    private func send(behavior explicitBehavior: String? = nil) async {
        guard let target = presentationTarget else { return }
        let behavior = explicitBehavior
            ?? ChatComposerPolicy.submissionBehavior(phase: selectedAuthoritativeSnapshot?.phase)
        if !ChatComposerPolicy.preservesFocus(submissionBehavior: behavior) {
            composerFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        do { try await model.sendComposer(target: target, behavior: behavior) }
        catch { model.presentComposerActionError(error, target: target) }
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

    private func importPhotos(_ values: [PhotosPickerItem]) async {
        photos = []
        guard let target = presentationTarget else { return }
        for item in values {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    model.presentComposerActionError(
                        "The selected photo could not be prepared.",
                        target: target
                    )
                    continue
                }
                try await model.upload(
                    name: "photo.jpg",
                    mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg",
                    data: data,
                    target: target
                )
            }
            catch { model.presentComposerActionError(error, target: target) }
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
