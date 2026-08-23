import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum ChatComposerLayoutSignalPolicy {
    static func shouldSignal(previous: CGFloat, current: CGFloat) -> Bool {
        previous > 0 && current > 0 && abs(current - previous) > 0.5
    }
}

struct ExtensionActivityPillComposerGeometry: Equatable, Sendable {
    let ownerIDs: [String]
    let height: CGFloat
}

enum ExtensionActivityPillComposerGeometryPolicy {
    enum Disposition: Equatable { case noScrollWrites, noSmoothFollow }

    static func disposition(isDetached: Bool) -> Disposition {
        isDetached ? .noScrollWrites : .noSmoothFollow
    }

    static func changed(previous: ExtensionActivityPillComposerGeometry?, current: ExtensionActivityPillComposerGeometry) -> Bool {
        guard let previous else { return false }
        return previous.ownerIDs != current.ownerIDs || abs(previous.height - current.height) > 0.5
    }
}

private struct ChatScrollGeometryObservation: Equatable {
    let geometry: ChatTranscriptGeometry
    let presentationEpoch: Int
    let phase: ChatOpenPresentationPhase
}

private struct ChatTranscriptProjectionCapture: Sendable {
    let snapshot: SessionSnapshot
    let handoff: ChatTranscriptHandoffCommit
    let queuePresentationIDByOperationID: [String: String]
    let tag: ChatTranscriptProjectionTag
}

private struct ChatQueuedMessageRenderEntry: Identifiable {
    let id: String
    let index: Int
    let message: SessionSnapshot.QueuedMessage
}

struct BoundedChatIdentityLedger: Equatable {
    private(set) var ids: Set<String> = []
    private var order: [String] = []

    mutating func formUnion(_ incoming: Set<String>) {
        for id in incoming.sorted() where ids.insert(id).inserted { order.append(id) }
        let excess = order.count - ChatTranscriptPageRequest.maximumItemCount
        guard excess > 0 else { return }
        for id in order.prefix(excess) { ids.remove(id) }
        order.removeFirst(excess)
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }
    mutating func remove(_ id: String) {
        ids.remove(id)
        order.removeAll { $0 == id }
    }
    mutating func removeAll() {
        ids.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }
}

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
    @State private var composerScope: ComposerDraftScope?
    @State private var photos: [PhotosPickerItem] = []
    @State private var photoImportTask: Task<Void, Never>?
    @State private var photoImportTarget: SessionPresentationIdentity?
    @State private var attachmentDestination: ChatAttachmentDestination?
    @State private var queuedAttachmentDestination: ChatAttachmentDestination?
    @State private var attachmentPresentationTask: Task<Void, Never>?
    @State private var showContext = false
    @State private var showExtensionDetails = false
    @State private var extensionDetailsGroupID: String?
    @State private var initialModelSettled = true
    @State private var showSettings = false
    @State private var queuedMessageEditor: QueuedMessageEditorRoute?
    @State private var mutatingQueuedMessageIDs: Set<String> = []
    @State private var locallyMutatedQueueOperationIDs: Set<String> = []
    @State private var deferredQueueMutationProjection: ChatTranscriptProjectionCapture?
    @State private var queueMutationCommandIsPending = false
    @State private var pendingQueueMutationRevision: Int?
    @State private var queueMutationResolution = ChatQueueMutationResolutionOwner()
    @State private var earlierMessagesOperation = ChatEarlierMessagesOperationOwner()
    @State private var openPresentation: ChatOpenPresentationState
    @State private var openingTask: Task<Void, Never>?
    @State private var modelPresentationGeneration: Int?
    @State private var composerLayoutHeight: CGFloat = 0
    @State private var extensionPillGeometry: ExtensionActivityPillComposerGeometry?
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
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerResourceCatalog = ComposerResourceCatalog(commands: [])
    @State private var composerResourcePicker: ComposerResourcePickerSource?
    @State private var composerResourceResults: [ComposerResourceEntry] = []
    @State private var suppressedInteractionScope: ExtensionInteractionScope?
    @State private var canonicalSubmissionHandoffs = BoundedChatIdentityLedger()

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
        _openPresentation = State(initialValue: ChatOpenPresentationState(sessionID: sessionID))
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
            if let commit = QueuedMessageManagementPolicy.installedCommit(
                for: transcriptPresentation.installed
            ), let message = commit.items.first(where: { $0.id == route.id }) {
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
                    "Queue Editing Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Queue management is no longer available for this Gateway commit.")
                )
            }
        }
        .onChange(of: transcriptPresentation.installed) { _, installed in
            // Revoke an editor at the same installed commit boundary as its
            // controls. mutateQueue also fails closed for an action already
            // queued by SwiftUI before this dismissal is rendered.
            guard queuedMessageEditor != nil,
                  QueuedMessageManagementPolicy.installedCommit(for: installed) == nil else { return }
            queuedMessageEditor = nil
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
        .sheet(isPresented: extensionHubPresentationBinding) {
            ExtensionDetailsSheet(sessionID: sessionID, groupID: extensionDetailsGroupID)
        }
        .sheet(item: interactionBinding) { interaction in
            if interaction.questionnaire != nil {
                ExtensionQuestionnaireSheet(
                    sessionID: sessionID,
                    interaction: interaction,
                    onResolved: {
                        suppressedInteractionScope = ExtensionInteractionScope(interaction)
                    },
                    onLocallyClosed: {
                        suppressedInteractionScope = ExtensionInteractionScope(interaction)
                    }
                )
            } else {
                ExtensionInteractionSheet(
                    sessionID: sessionID,
                    interaction: interaction,
                    onResolved: {
                        suppressedInteractionScope = ExtensionInteractionScope(interaction)
                    },
                    onLocallyClosed: {
                        suppressedInteractionScope = ExtensionInteractionScope(interaction)
                    }
                )
            }
        }
        .fileImporter(
            isPresented: attachmentPresentationBinding(for: .files),
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .onChange(of: photos) { _, values in
            guard !values.isEmpty else { return }
            // PhotosPicker may deliver its selection after the mounted
            // presentation has been revoked. Clear the native selection before
            // admitting a target so it cannot replay into a later chat.
            photos = []
            guard let target = presentationTarget else {
                photoImportTask?.cancel()
                photoImportTask = nil
                photoImportTarget = nil
                return
            }
            photoImportTask?.cancel()
            photoImportTarget = target
            photoImportTask = Task { @MainActor in
                await importPhotos(values, target: target)
                guard !Task.isCancelled, photoImportTarget == target else { return }
                photoImportTask = nil
                photoImportTarget = nil
            }
        }
        .onChange(of: attachmentMenuState) { previous, current in
            if previous.sessionID != current.sessionID {
                composerResourcePicker = nil
                cancelAttachmentPresentation(includingActive: true)
                photoImportTask?.cancel()
                photoImportTask = nil
                photoImportTarget = nil
            } else if !current.actionsEnabled {
                composerResourcePicker = nil
                cancelAttachmentPresentation(includingActive: false)
                photoImportTask?.cancel()
                photoImportTask = nil
                photoImportTarget = nil
            }
        }
        .sheet(item: Binding(
            get: { initialModelSettled ? routedEditorRequest : nil },
            set: { presented in
                guard presented == nil,
                      let request = routedEditorRequest,
                      let target = presentationTarget else { return }
                model.disposeExtensionEditorRequest(request, disposition: .keep, target: target)
            }
        )) { request in
            TronConfirmationSheet(
                title: ComposerEditorRequestPolicy.confirmationTitle,
                message: ComposerEditorRequestPolicy.confirmationMessage,
                confirmTitle: ComposerEditorRequestPolicy.useActionTitle,
                secondaryTitle: ComposerEditorRequestPolicy.keepActionTitle,
                icon: "square.and.pencil",
                onConfirm: {
                    guard let target = presentationTarget else { return }
                    model.disposeExtensionEditorRequest(request, disposition: .use, target: target)
                },
                onSecondary: {
                    guard let target = presentationTarget else { return }
                    model.disposeExtensionEditorRequest(request, disposition: .keep, target: target)
                }
            )
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
                model.composerDrafts.reconcileSelectedSkill(for: composerScope, commands: commands)
            }
            if let picker = composerResourcePicker {
                composerResourceResults = catalog.entries(kind: picker.kind, query: picker.query)
            }
            reconcileComposerResourcePicker()
        }
        .onChange(of: composerText) { _, _ in reconcileComposerResourcePicker() }
        .onChange(of: composerSelection) { _, _ in reconcileComposerResourcePicker() }
        .task(id: sessionID) { await beginOpeningPresentation() }
        .onChange(of: pendingInteractionScopes, initial: true) { _, scopes in
            guard let suppressedInteractionScope,
                  ChatExtensionInteractionPolicy.shouldClearSuppression(
                      suppressedInteractionScope,
                      from: selectedAuthoritativeSnapshot?.extensionPresentation.pendingInteractions ?? []
                  ) else { return }
            self.suppressedInteractionScope = nil
        }
        .onChange(of: transcriptProjectionSource, initial: true) { _, source in
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
        .onChange(of: transcriptPresentation.installed?.tag) { previousTag, _ in
            let installed = transcriptPresentation.installed
            if ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
                commandIsPending: queueMutationCommandIsPending,
                expectedRevision: pendingQueueMutationRevision,
                installedRevision: installed?.queueRevision
            ) {
                clearSettledQueueMutationPresentationState()
            }
            // Lifecycle-only grafts own one pinned-tail settlement but must not
            // consume the mutation boundary reserved for a newer authoritative
            // payload installation.
            if let previousTag, let installed,
               previousTag.matchesProjectionPayload(of: installed.tag) {
                scrollCoordinator.installedLifecycleChanged(installed)
            } else {
                scrollCoordinator.installedTranscriptChanged(installed)
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
        .onDisappear {
            if let target = presentationTarget { model.revokePresentationIntake(target) }
            openingTask?.cancel()
            openingTask = nil
            scrollCoordinator.cancel()
            transcriptPresentation.reset()
            earlierMessagesOperation.cancel()
            canonicalSubmissionHandoffs.removeAll()
            retireQueueMutationPresentationState()
            performanceTracker.cancelAll()
            cancelAttachmentPresentation(includingActive: true)
            photoImportTask?.cancel()
            photoImportTask = nil
            photoImportTarget = nil
            if let generation = modelPresentationGeneration {
                Task { await model.closeSessionPresentation(sessionID, generation: generation) }
            }
        }
    }

    private func rememberCanonicalSubmissionHandoffs(_ ids: Set<String>) {
        canonicalSubmissionHandoffs.formUnion(ids)
    }

    /// Keeps the installed queue boundary visible while a local queue command
    /// decides whether a simultaneous canonical row consumed that operation or
    /// is unrelated. Once deferral starts, newer complete captures coalesce here
    /// until the one in-flight command resolves.
    @MainActor
    private func deferQueueMutationProjectionIfNeeded(
        _ capture: ChatTranscriptProjectionCapture
    ) -> Bool {
        guard queueMutationCommandIsPending,
              !locallyMutatedQueueOperationIDs.isEmpty else { return false }
        if deferredQueueMutationProjection != nil {
            deferredQueueMutationProjection = capture
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
            excludedOperationIDs: locallyMutatedQueueOperationIDs,
            previousCanonicalIDs: previousCanonicalIDs(in: installed),
            previousSourceWindow: installed.sourceWindow,
            incomingSourceWindow: .init(snapshot: snapshot),
            incomingTranscript: snapshot.transcript
        )
        guard ChatQueueMutationProjectionPolicy.shouldDefer(
            affectedOperationIDs: locallyMutatedQueueOperationIDs,
            receiptOperationID: receiptOperationID,
            fallbackHandoffWithoutExclusions: fallbackWithoutExclusions,
            fallbackHandoffWithExclusions: fallbackWithExclusions
        ) else { return false }
        deferredQueueMutationProjection = capture
        return true
    }

    @MainActor
    private func resolveDeferredQueueMutationProjection() {
        guard let capture = deferredQueueMutationProjection else { return }
        deferredQueueMutationProjection = nil
        guard capture.tag.presentationGeneration == modelPresentationGeneration,
              transcriptProjectionSource == capture.tag else { return }
        intakeTranscriptProjection(capture, permitsQueueMutationDeferral: false)
    }

    @MainActor
    private func clearSettledQueueMutationPresentationState() {
        pendingQueueMutationRevision = nil
        mutatingQueuedMessageIDs.removeAll()
        locallyMutatedQueueOperationIDs.removeAll()
    }

    @MainActor
    private func retireQueueMutationPresentationState() {
        queueMutationResolution.retire()
        mutatingQueuedMessageIDs.removeAll()
        pendingQueueMutationRevision = nil
        locallyMutatedQueueOperationIDs.removeAll()
        deferredQueueMutationProjection = nil
        queueMutationCommandIsPending = false
    }

    @MainActor
    private func intakeTranscriptProjection(
        _ capture: ChatTranscriptProjectionCapture,
        permitsQueueMutationDeferral: Bool = true
    ) {
        guard capture.tag.presentationGeneration == modelPresentationGeneration,
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
               pendingReceipt.operationID.map({ locallyMutatedQueueOperationIDs.contains($0) }) != true,
               let receipt = model.composerDrafts.consumeCanonicalSubmissionHandoff(target: target) {
                canonicalHandoffIDs.insert(receipt.canonicalID)
                seedCanonicalMediaPreviews(from: receipt, in: snapshot)
            }
            rememberCanonicalSubmissionHandoffs(canonicalHandoffIDs)
        }
        let installedBeforeSubmission = transcriptPresentation.installed
        if let installedBeforeSubmission,
           let canonicalHandoffID = ChatPromptLifecycleReplacementPolicy.canonicalHandoffID(
               previousQueue: installedBeforeSubmission.queuedMessages,
               incomingQueue: snapshot.displayedQueuedMessages,
               excludedOperationIDs: locallyMutatedQueueOperationIDs,
               previousCanonicalIDs: previousCanonicalIDs(in: installedBeforeSubmission),
               previousSourceWindow: installedBeforeSubmission.sourceWindow,
               incomingSourceWindow: .init(snapshot: snapshot),
               incomingTranscript: snapshot.transcript
           ) {
            rememberCanonicalSubmissionHandoffs([canonicalHandoffID])
        }
        if let previousPending = installedBeforeSubmission?.handoff.pendingPromptPresentation {
            // The replacement snapshot normally no longer carries
            // pendingPrompt. Compare the previously installed immutable
            // handoff against the incoming canonical facts before submit, so
            // the canonical row installs directly visible rather than
            // replaying its entrance entitlement.
            rememberCanonicalSubmissionHandoffs(
                ChatPendingCanonicalSuppressionPolicy.canonicalIDs(
                    for: previousPending,
                    in: snapshot.transcript
                )
            )
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
        let startedWork = transcriptPresentation.submit(
            snapshot: snapshot,
            handoff: capture.handoff,
            queuePresentationIDByOperationID: capture.queuePresentationIDByOperationID,
            tag: currentSource
        )
        if startedWork {
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let installed = transcriptPresentation.installed {
                    if (installed.sourceWindow.originalStart ?? 0) > 0 {
                        stableTranscriptRow(
                            id: "earlier-messages",
                            installedTag: installed.tag,
                            entranceState: .none
                        ) {
                            earlierMessagesChip(installed: installed)
                        }
                    }
                    ForEach(installed.displayedItems) { item in
                            let entranceKind = ChatContentEntranceKind.classify(item)
                            let entranceState = canonicalSubmissionHandoffs.contains(item.id)
                                ? .none
                                : transcriptPresentation.entranceState(for: item.id)
                            stableTranscriptRow(
                                id: item.id,
                                installedTag: installed.tag,
                                entranceState: entranceState,
                                entranceKind: entranceKind
                            ) {
                                if canonicalSubmissionHandoffs.contains(item.id) {
                                    // This prompt already consumed its one entrance as
                                    // outgoing, pending, or queued content. Canonical
                                    // settlement is a direct visible replacement.
                                    transcriptRenderRow(
                                        item: item,
                                        installed: installed
                                    )
                                } else {
                                    ChatTranscriptEntranceRow(
                                        state: entranceState,
                                        admissionTag: installed.tag,
                                        kind: entranceKind,
                                        reduceMotion: reduceMotion,
                                        onFailsafeReveal: {
                                            _ = transcriptPresentation.resolveEntrance(
                                                id: item.id,
                                                installationTag: installed.tag,
                                                isVisible: false
                                            )
                                            #if HOSTED_TEST
                                            hostedProbe?.recordEntranceFailsafeReveal()
                                            #endif
                                        }
                                    ) {
                                        transcriptRenderRow(
                                            item: item,
                                            installed: installed
                                        )
                                    }
                                }
                            }
                        }
                        switch installed.handoff {
                        case .none:
                            EmptyView()
                        case .pending(let pendingPrompt):
                            let renderedID = "pending-prompt-\(pendingPrompt.id)"
                            stableTranscriptRow(
                                id: renderedID,
                                installedTag: installed.tag,
                                entranceState: .none
                            ) {
                                if pendingPrompt.promptBehavior.isQueuedKind {
                                    ChatQueuedMessageEntranceRow(
                                        animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                                            isReady: isTranscriptReady,
                                            entranceSuppressed: installed.tag.entranceSuppressionGeneration != nil,
                                            hasIdentityAlias: false
                                        ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                                        reduceMotion: reduceMotion,
                                        onEntranceConsumed: {
                                            transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                                        }
                                    ) {
                                        ChatPendingPromptRow(presentation: pendingPrompt)
                                    }
                                } else {
                                    ChatOutgoingSubmissionEntranceRow(
                                        reduceMotion: reduceMotion,
                                        animatesEntrance: installed.tag.entranceSuppressionGeneration == nil
                                            && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                                        kind: ChatPromptLifecycleTransitionPolicy.entranceKind(
                                            for: pendingPrompt.promptBehavior
                                        ),
                                        onEntranceConsumed: {
                                            transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                                        }
                                    ) {
                                        ChatPendingPromptRow(presentation: pendingPrompt)
                                    }
                                }
                            }
                        case .outgoing(let outgoing, let attachments):
                            stableTranscriptRow(
                                id: outgoing.id,
                                installedTag: installed.tag,
                                entranceState: .none
                            ) {
                                if outgoing.promptBehavior.isQueuedKind {
                                    ChatQueuedMessageEntranceRow(
                                        animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                                            isReady: isTranscriptReady,
                                            entranceSuppressed: installed.tag.entranceSuppressionGeneration != nil,
                                            hasIdentityAlias: false
                                        ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: outgoing.id),
                                        reduceMotion: reduceMotion,
                                        onEntranceConsumed: {
                                            transcriptPresentation.consumeLifecycleEntrance(id: outgoing.id)
                                        }
                                    ) {
                                        ChatOutgoingSubmissionRow(
                                            presentation: outgoing,
                                            attachments: attachments
                                        )
                                    }
                                } else {
                                    ChatOutgoingSubmissionEntranceRow(
                                        reduceMotion: reduceMotion,
                                        animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateUserEntrance(
                                            isReady: isTranscriptReady,
                                            entranceSuppressed: installed.tag.entranceSuppressionGeneration != nil
                                        ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: outgoing.id),
                                        kind: ChatPromptLifecycleTransitionPolicy.entranceKind(
                                            for: outgoing.promptBehavior
                                        ),
                                        onEntranceConsumed: {
                                            transcriptPresentation.consumeLifecycleEntrance(id: outgoing.id)
                                        }
                                    ) {
                                        ChatOutgoingSubmissionRow(
                                            presentation: outgoing,
                                            attachments: attachments
                                        )
                                    }
                                }
                            }
                        }
                    queuedMessageRows(installed)
                }
                transcriptTailMarker
            }
            .padding(.vertical, 12)
            .scrollTargetLayout()
            .chatStableTranscriptUpdates()
            // Keep rows physically realizable beneath the opaque opening surface.
            // The cover fades away only after exact-tail positioning; opacity-zero
            // lazy content can defer the very target needed to position it.
            .offset(y: isTranscriptReady || reduceMotion ? 0 : 8)
            // Readiness is animated only by the opening surface below. Keeping
            // animation off this structural stack prevents a later tool,
            // thinking-height, or composer-viewport update from inheriting the
            // opening transaction and interpolating the entire transcript.
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
        .onScrollGeometryChange(for: ChatScrollGeometryObservation.self) { geometry in
            ChatScrollGeometryObservation(
                geometry: ChatTranscriptGeometry(geometry),
                presentationEpoch: openPresentation.epoch,
                phase: openPresentation.phase
            )
        } action: { previous, observation in
            guard observation.presentationEpoch == openPresentation.epoch,
                  observation.phase == openPresentation.phase else { return }
            let geometry = observation.geometry
            let previousGeometry = previous.geometry
            transcriptGeometry = geometry
            #if HOSTED_TEST
            hostedProbe?.updateGeometry(geometry)
            if isTranscriptReady, geometry.isAtCatchUpBoundary {
                hostedProbe?.recordScrollSettle(distanceFromBottom: geometry.distanceFromBottom)
            }
            #endif
            guard observation.phase == .positioning || observation.phase == .ready,
                  admitsScrollGeometryCallbacks,
                  admitsNativeScrollCallbacks else { return }
            // Phase and epoch participate in the observed value so entering
            // positioning replays current native geometry even when its numeric
            // fields are unchanged and SwiftUI would otherwise coalesce it.
            if geometry.hasViewportChange(from: previousGeometry) {
                scrollCoordinator.viewportChanged(previous: previousGeometry, current: geometry)
            } else {
                scrollCoordinator.geometryChanged(previous: previousGeometry, current: geometry)
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
        .onChange(of: scrollCoordinator.layoutEpoch) { _, _ in
            scrollCoordinator.installedLayoutEpochChanged()
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
        .overlay { openingSurface }
    }

    @ViewBuilder
    private func queuedMessageRows(_ installed: InstalledChatTranscript) -> some View {
        let messages = installed.queuedMessages
        let managementAvailability = QueuedMessageManagementPolicy.availability(
            queueManagementCapability: installed.tag.queueManagementCapability,
            queueRevision: installed.queueRevision,
            hasAuthoritativeItems: installed.supportsQueueManagement
        )
        let entries = messages.enumerated().map { pair in
            ChatQueuedMessageRenderEntry(
                id: installed.queuePresentationIDByOperationID[pair.element.id]
                    ?? "queued-message-\(pair.element.id)",
                index: pair.offset,
                message: pair.element
            )
        }
        ForEach(entries) { entry in
            let index = entry.index
            let message = entry.message
            let aliasID = installed.queuePresentationIDByOperationID[message.id]
            let renderedID = aliasID ?? "queued-message-\(message.id)"
            let hasSuppressedEntrance = canonicalSubmissionHandoffs.contains(renderedID)
            stableTranscriptRow(
                id: renderedID,
                installedTag: installed.tag,
                entranceState: .none
            ) {
                ChatQueuedMessageEntranceRow(
                    animatesEntrance: ChatPromptLifecycleTransitionPolicy.shouldAnimateQueueEntrance(
                        isReady: isTranscriptReady,
                        entranceSuppressed: installed.tag.entranceSuppressionGeneration != nil,
                        hasIdentityAlias: aliasID != nil || hasSuppressedEntrance
                    ) && !transcriptPresentation.lifecycleEntranceIsConsumed(id: renderedID),
                    reduceMotion: reduceMotion,
                    onEntranceConsumed: {
                        transcriptPresentation.consumeLifecycleEntrance(id: renderedID)
                    }
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
    private func transcriptRenderRow(
        item: ChatTranscriptRenderItem,
        installed: InstalledChatTranscript
    ) -> some View {
        ChatTranscriptRenderRow(
            item: item,
            preparedText: installed.preparedText(for: item),
            hiddenThinkingLabel: installed.hiddenThinkingLabel,
            installationTag: installed.tag,
            resolveToolDetails: { callIDs, tag in
                transcriptPresentation.resolveToolDetails(
                    callIDs: callIDs,
                    installationTag: tag
                )
            },
            recordToolChip: { sample in
                #if HOSTED_TEST
                hostedProbe?.recordToolChip(sample)
                #endif
            }
        )
        .equatable()
        .chatStableTranscriptUpdates()
    }

    @ViewBuilder
    private func stableTranscriptRow<Content: View>(
        id: String,
        installedTag: ChatTranscriptProjectionTag?,
        entranceState: ChatTranscriptEntranceState,
        entranceKind: ChatContentEntranceKind = .assistantContent,
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
                if animated {
                    // Newly realized agent rows join the same short, frame-
                    // coalesced smooth pinned-tail motion as streamed growth.
                    // Detached readers remain inert and physical overshoot
                    // correction is still forced nonanimated by the coordinator.
                    scrollCoordinator.discreteContentInserted(renderedID: id)
                }
            }
            #if HOSTED_TEST
            hostedProbe?.updateRowFrame(id: id, frame: sample.frame)
            hostedProbe?.recordMaximumSemanticExcursion(scrollCoordinator.maximumPrependSemanticExcursion)
            #endif
        }
    }

    private var transcriptTailMarker: some View {
        let rowLayoutEpoch = scrollCoordinator.layoutEpoch
        return Color.clear
            .frame(height: 12)
            .id("transcript-bottom")
            .accessibilityHidden(true)
            .onGeometryChange(for: ChatSemanticFrameObservation.self) { geometry in
                ChatSemanticFrameObservation(
                    layoutEpoch: rowLayoutEpoch,
                    frame: geometry.frame(in: .scrollView(axis: .vertical)),
                    entranceAdmissionTag: nil
                )
            } action: { sample in
                scrollCoordinator.semanticFrameChanged(
                    renderedID: "transcript-bottom",
                    layoutEpoch: sample.layoutEpoch,
                    frame: sample.frame
                )
                #if HOSTED_TEST
                hostedProbe?.updateRowFrame(id: "transcript-bottom", frame: sample.frame)
                #endif
            }
    }

    private var selectedAuthoritativeSnapshot: SessionSnapshot? {
        model.authoritativeSnapshot(for: sessionID)
    }

    private var showsAmbientWorkingBlur: Bool {
        guard let snapshot = selectedAuthoritativeSnapshot else { return false }
        return ChatRuntimeWorkingPresentation(
            phase: snapshot.phase,
            working: snapshot.extensionPresentation.semanticState.working,
            retry: snapshot.retry
        )?.usesAmbientBottomIndicator == true
    }

    private var presentationTarget: AppModel.SessionPresentationTarget? {
        modelPresentationGeneration.map {
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
        guard let snapshot = model.transcriptSnapshot(for: sessionID),
              let generation = modelPresentationGeneration,
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
            entranceSuppressionGeneration: model.foregroundReconciliationGeneration == 0
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

    @MainActor
    private func installCurrentTranscriptProjection(
        presentationGeneration: Int
    ) async throws -> InstalledChatTranscript {
        while true {
            try Task.checkCancellation()
            guard modelPresentationGeneration == presentationGeneration,
                  let capture = transcriptProjectionCapture,
                  capture.tag.presentationGeneration == presentationGeneration else {
                throw CancellationError()
            }
            let snapshot = capture.snapshot
            let tag = capture.tag
            if deferQueueMutationProjectionIfNeeded(capture) {
                guard let token = queueMutationResolution.activeToken else { continue }
                let resolution = try await queueMutationResolution.wait(for: token)
                guard resolution == .commandCompleted else { throw CancellationError() }
                continue
            }
            transcriptPresentation.submit(
                snapshot: snapshot,
                handoff: capture.handoff,
                queuePresentationIDByOperationID: capture.queuePresentationIDByOperationID,
                tag: tag
            )
            do {
                let installed = try await transcriptPresentation.waitForInstall(of: tag)
                guard modelPresentationGeneration == presentationGeneration else {
                    throw CancellationError()
                }
                if transcriptProjectionSource == tag,
                   transcriptProjectionCapture?.handoff == capture.handoff {
                    return installed
                }
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

    private var submittedAttachments: [PendingAttachment] {
        presentationTarget.map(model.composerDrafts.submittedAttachments(for:)) ?? []
    }

    private var selectedComposerSkill: ComposerResourceEntry? {
        guard let composerScope,
              let command = model.composerDrafts.selectedSkill(for: composerScope) else { return nil }
        return ComposerResourceEntry(command: command)
    }

    private var candidatePresentedInteraction: ExtensionInteraction? {
        ChatExtensionInteractionPolicy.presentedInteraction(
            selectedAuthoritativeSnapshot?.extensionPresentation.pendingInteractions ?? [],
            suppressing: suppressedInteractionScope
        )
    }

    private var candidateEditorRequest: ComposerEditorRequest? {
        guard let target = presentationTarget else { return nil }
        return model.composerDrafts.editorRequest(for: target)
    }

    private var extensionForegroundPresentation: ChatExtensionForegroundPresentation {
        ChatExtensionPresentationArbiter.presentation(
            modelSettled: initialModelSettled,
            hasInteraction: candidatePresentedInteraction != nil,
            hasEditorRequest: candidateEditorRequest != nil
        )
    }

    /// The ChatView owns one extension hub intent. Interaction and editor routes
    /// have foreground priority; retaining this intent lets the hub resume
    /// after either route settles without competing sheets.
    private var extensionHubPresentationBinding: Binding<Bool> {
        Binding(
            get: { showExtensionDetails && extensionForegroundPresentation == .none },
            set: { presented in
                if !presented { showExtensionDetails = false }
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

    /// Builds the complete handoff exactly once with the canonical snapshot.
    /// The resulting immutable value, not the live composer, is what enters the
    /// projection worker and the installed transcript.
    private func transcriptHandoffCommit(snapshot: SessionSnapshot) -> ChatTranscriptHandoffCommit {
        if let target = presentationTarget,
           let submission = model.composerDrafts.outgoingSubmission(for: target) {
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
                    .filter { submission.attachmentIDs.contains($0.id) }
                    .prefix(ComposerAttachmentPolicy.maximumCount)
                    .map { $0.frozenForHandoff() }
                return .outgoing(
                    presentation: ChatOutgoingSubmissionPresentation(
                        snapshot: submission,
                        transportActive: model.composerDrafts.isSending(target: target)
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
        selectedAuthoritativeSnapshot.map(ChatResponseState.init)
    }

    private var isTranscriptReady: Bool { openPresentation.phase == .ready }

    private var isLoadingEarlierMessages: Bool {
        ChatEarlierMessagesOperationPolicy.isLoading(
            owner: earlierMessagesOperation,
            modelLoading: model.loadingEarlierTranscript,
            scrollLoading: scrollCoordinator.isPrependingHistory
        )
    }

    private var transcriptRevealAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26)
    }

    private var admitsScrollGeometryCallbacks: Bool {
        openPresentation.phase == .positioning || openPresentation.phase == .ready
    }

    private var admitsNativeScrollCallbacks: Bool {
        #if HOSTED_TEST
        hostedProbe?.usesDrivenScrollAuthority != true
        #else
        true
        #endif
    }

    @ViewBuilder private var openingSurface: some View {
        switch openPresentation.phase {
        case .opening, .positioning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.regular)
                Text("Opening conversation…")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.tronBackground)
            .accessibilityElement(children: .combine)
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
    private func beginOpeningPresentation() async {
        // Retiring/restarting presentation authority cancels any local page
        // admission; late model/scroll completions are token-gated.
        earlierMessagesOperation.cancel()
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
        openingTask?.cancel()
        performanceTracker.discardScroll()
        let retainsVisiblePresentation = modelPresentationGeneration != nil
            && selectedAuthoritativeSnapshot?.sessionId == sessionID
        if !retainsVisiblePresentation {
            modelPresentationGeneration = nil
            transcriptPresentation.reset()
        }
        let epoch = openPresentation.begin(retainingVisiblePresentation: retainsVisiblePresentation)
        scrollCoordinator.resetForPresentation(
            epoch,
            retainingVisibleViewport: retainsVisiblePresentation
        )
        let task = Task { @MainActor in
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
                modelPresentationGeneration = generation
                let installed = try await installCurrentTranscriptProjection(
                    presentationGeneration: generation
                )
                if retainsVisiblePresentation {
                    guard !Task.isCancelled,
                          transcriptProjectionSource == installed.tag,
                          openPresentation.epoch == epoch,
                          openPresentation.phase == .ready else {
                        performanceSignposts.end(interval, result: .discarded, metrics: .none)
                        await model.closeSessionPresentation(sessionID, generation: generation)
                        return
                    }
                    openedGeneration = nil
                    _ = await completeFirstReadyFrame(interval, epoch: epoch)
                    return
                }
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
                let positioned = await positionLatestTail(
                    epoch: epoch,
                    targetRenderedID: physicalOpeningTailID(for: installed)
                )
                guard positioned else {
                    let isCurrentTimeout = !Task.isCancelled
                        && openPresentation.epoch == epoch
                        && openPresentation.phase == .positioning
                    performanceSignposts.end(
                        interval,
                        result: isCurrentTimeout ? .failure : .discarded,
                        metrics: .none
                    )
                    if isCurrentTimeout {
                        _ = openPresentation.fail(
                            sessionID: sessionID,
                            epoch: epoch,
                            message: "The conversation layout did not settle. Please retry."
                        )
                    }
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    if modelPresentationGeneration == generation {
                        modelPresentationGeneration = nil
                        transcriptPresentation.reset()
                    }
                    return
                }
                guard !Task.isCancelled,
                      revealPositionedTranscript(epoch: epoch) else {
                    performanceSignposts.end(interval, result: .discarded, metrics: .none)
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    if modelPresentationGeneration == generation {
                        modelPresentationGeneration = nil
                        transcriptPresentation.reset()
                    }
                    return
                }
                openedGeneration = nil
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
        let retainsVisiblePresentation = modelPresentationGeneration != nil
            && selectedAuthoritativeSnapshot?.sessionId == sessionID
        if !retainsVisiblePresentation {
            transcriptPresentation.reset()
        }
        let epoch = openPresentation.begin(
            retainingVisiblePresentation: retainsVisiblePresentation
        )
        let interval = performanceSignposts.begin(.firstReadyFrame)
        guard selectedAuthoritativeSnapshot != nil,
              let presentationGeneration = model.presentationGeneration(for: sessionID) else {
            performanceSignposts.end(interval, result: .failure, metrics: .none)
            _ = openPresentation.fail(
                sessionID: sessionID,
                epoch: epoch,
                message: "Hosted authoritative snapshot unavailable"
            )
            return
        }
        modelPresentationGeneration = presentationGeneration
        scrollCoordinator.resetForPresentation(
            presentationGeneration,
            retainingVisibleViewport: retainsVisiblePresentation
        )
        let installed: InstalledChatTranscript
        do {
            installed = try await installCurrentTranscriptProjection(
                presentationGeneration: presentationGeneration
            )
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
                guard !isLoadingEarlierMessages,
                      let generation = modelPresentationGeneration,
                      let operationToken = earlierMessagesOperation.begin() else { return false }
                let admission = ChatEarlierMessagesOperationAdmission()
                let anchor = transcriptPresentation.installed
                    .flatMap { installed in
                        installed.tag == transcriptProjectionSource
                            ? scrollCoordinator.semanticAnchor(in: installed.timeline)
                            : nil
                    }
                let began = scrollCoordinator.beginPrepend(
                    anchor: anchor,
                    load: {
                        do { try await probe.waitForPrependPageRelease() }
                        catch { return nil }
                        let result = await model.loadEarlierTranscript(
                            sessionID: sessionID,
                            presentationGeneration: generation
                        )
                        guard result == .installed,
                              modelPresentationGeneration == generation else { return nil }
                        guard let anchor else {
                            _ = try? await installCurrentTranscriptProjection(
                                presentationGeneration: generation
                            )
                            return nil
                        }
                        guard let current = try? await installCurrentTranscriptProjection(
                            presentationGeneration: generation
                        ),
                              let renderedID = current.timeline.renderedIDBySemanticID[anchor.semanticID] else {
                            return nil
                        }
                        let installedLayout = scrollCoordinator.beginInstalledLayoutEpoch()
                        return ChatPrependPage(
                            renderedAnchorID: renderedID,
                            installedLayout: installedLayout
                        )
                    },
                    completion: { [admission] result in
                        probe.recordPrependCompletion(result)
                        guard admission.coordinatorAdmitted else { return }
                        self.settleEarlierMessagesOperation(operationToken)
                    }
                )
                if began {
                    admission.coordinatorAdmitted = true
                    return true
                }
                // The native coordinator may reject anchoring because its
                // command/semantic sample is stale. Canonical history still
                // starts, and its projection is installed explicitly.
                Task { @MainActor in
                    defer { self.settleEarlierMessagesOperation(operationToken) }
                    do { try await probe.waitForPrependPageRelease() } catch { return }
                    await loadEarlierTranscriptUnanchored(
                        sessionID: sessionID,
                        presentationGeneration: generation,
                        operationToken: operationToken
                    )
                }
                return true
            },
            invalidatePresentation: {
                scrollCoordinator.resetForPresentation()
            },
            cancelPresentation: {
                scrollCoordinator.cancel()
            }
        )
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
            if transcriptGeometry.isAtCatchUpBoundary {
                probe.recordScrollSettle(distanceFromBottom: transcriptGeometry.distanceFromBottom)
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
            openPresentation.installPositionedViewport(sessionID: sessionID, epoch: epoch)
        } completion: {
            guard openPresentation.epoch == epoch,
                  openPresentation.phase == .ready else { return }
            scrollCoordinator.openingRevealCompleted()
        }
    }

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

    private func physicalOpeningTailID(for installed: InstalledChatTranscript) -> String? {
        installed.displayedItems.isEmpty && installed.queuedMessages.isEmpty
            ? nil
            : "transcript-bottom"
    }

    @MainActor
    private func positionLatestTail(epoch: Int, targetRenderedID: String?) async -> Bool {
        // The opening surface remains opaque until the exact physical marker
        // after transcript and queue rows intersects a plausible bottom viewport.
        guard !Task.isCancelled,
              openPresentation.epoch == epoch,
              openPresentation.phase == .positioning else { return false }
        let positioned = await scrollCoordinator.positionOpeningTail(
            targetRenderedID: targetRenderedID
        )
        if positioned { performanceTracker.settleScroll() }
        return positioned
            && !Task.isCancelled
            && openPresentation.epoch == epoch
            && openPresentation.phase == .positioning
    }

    @MainActor
    private func executePendingScrollCommand() {
        guard let command = scrollCoordinator.command else { return }
        if command.destination != .releaseBinding {
            performanceTracker.beginScrollCommand()
        }
        let update = {
            switch command.destination {
            case .resetToBottom:
                transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
            case .tail:
                transcriptScrollPosition.scrollTo(edge: .bottom)
            case .openingTail(let renderedID):
                transcriptScrollPosition.scrollTo(id: renderedID, anchor: .bottom)
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
        if command.destination != .releaseBinding {
            hostedProbe?.recordScrollCommand(
                isAutomatic: command.origin == .automaticFollow,
                isSmooth: command.animation != .disabled
            )
        }
        #endif
        scrollCoordinator.commandApplied(command)
    }

    @MainActor
    private func catchUpToTail() {
        transcriptPresentation.discardPendingEntrances()
        scrollCoordinator.requestCatchUp(reduceMotion: reduceMotion)
    }

    @MainActor
    private func settleEarlierMessagesOperation(_ token: ChatEarlierMessagesOperationOwner.Token) {
        earlierMessagesOperation.settle(token)
    }

    @MainActor
    private func loadEarlierTranscriptUnanchored(
        sessionID: String,
        presentationGeneration: Int,
        operationToken: ChatEarlierMessagesOperationOwner.Token
    ) async {
        defer { settleEarlierMessagesOperation(operationToken) }
        let result = await model.loadEarlierTranscript(
            sessionID: sessionID,
            presentationGeneration: presentationGeneration
        )
        guard result == .installed, modelPresentationGeneration == presentationGeneration else { return }
        // A rejected prepend admission (no semantic anchor, stale geometry, or
        // an outstanding automatic command) must still install canonical data.
        // Do not rely on the source-change callback here: it is intentionally
        // suppressed while another layout transaction is settling.
        _ = try? await installCurrentTranscriptProjection(
            presentationGeneration: presentationGeneration
        )
    }

    private func earlierMessagesChip(installed: InstalledChatTranscript) -> some View {
        Button {
            guard !isLoadingEarlierMessages,
                  let presentationGeneration = modelPresentationGeneration,
                  let operationToken = earlierMessagesOperation.begin() else { return }
            let sessionID = installed.tag.sessionID
            let capturedAnchor = transcriptPresentation.installed.map {
                scrollCoordinator.semanticAnchor(in: $0.timeline)
            } ?? nil
            let admission = ChatEarlierMessagesOperationAdmission()
            let began = scrollCoordinator.beginPrepend(
                anchor: capturedAnchor,
                load: { @MainActor in
                    let result = await model.loadEarlierTranscript(
                        sessionID: sessionID,
                        presentationGeneration: presentationGeneration
                    )
                    guard result == .installed,
                          modelPresentationGeneration == presentationGeneration else { return nil }
                    guard let anchor = capturedAnchor else {
                        // The canonical page is already installed. Materialize
                        // its projection even though there is no old row whose
                        // viewport position can be preserved.
                        _ = try? await installCurrentTranscriptProjection(
                            presentationGeneration: presentationGeneration
                        )
                        return nil
                    }
                    guard let installed = try? await installCurrentTranscriptProjection(
                        presentationGeneration: presentationGeneration
                    ),
                    let renderedID = installed.timeline.renderedIDBySemanticID[anchor.semanticID] else {
                        return nil
                    }
                    let installedLayout = scrollCoordinator.beginInstalledLayoutEpoch()
                    return ChatPrependPage(
                        renderedAnchorID: renderedID,
                        installedLayout: installedLayout
                    )
                },
                completion: { [admission] _ in
                    guard admission.coordinatorAdmitted else { return }
                    self.settleEarlierMessagesOperation(operationToken)
                }
            )
            if began {
                admission.coordinatorAdmitted = true
                return
            }
            // beginPrepend is deliberately strict for viewport preservation;
            // its rejection is not permission to turn a canonical request into
            // a silent no-op.
            Task { @MainActor in
                await loadEarlierTranscriptUnanchored(
                    sessionID: sessionID,
                    presentationGeneration: presentationGeneration,
                    operationToken: operationToken
                )
            }
        } label: {
            HStack(spacing: 7) {
                if isLoadingEarlierMessages {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.tronEmerald)
                } else {
                    Image(systemName: "arrow.up")
                }
                Text(
                    isLoadingEarlierMessages
                        ? "Loading earlier…"
                        : "Load earlier messages"
                )
            }
            .chatTranscriptPill()
        }
        .buttonStyle(.plain)
        .disabled(isLoadingEarlierMessages)
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
        VStack(spacing: 10) {
            if let snapshot = selectedAuthoritativeSnapshot {
                let groups = ExtensionActivityPillPolicy.composerGroups(
                    ChatExtensionWidgetPolicy.liveGroups(
                        snapshot.extensionPresentation,
                        executions: snapshot.toolExecutions,
                        activities: snapshot.extensionActivities ?? []
                    )
                )
                if !groups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(groups) { group in
                                ExtensionActivityPill(
                                    group: group,
                                    onTap: {
                                        // Every pill enters the integrated hub. Run
                                        // details are a value-based destination
                                        // owned by that hub, never a bypass route.
                                        extensionDetailsGroupID = group.id
                                        showExtensionDetails = true
                                        #if HOSTED_TEST
                                        hostedProbe?.recordExtensionRoute(group.id)
                                        #endif
                                    },
                                    onVisualState: { state, token in
                                        #if HOSTED_TEST
                                        hostedProbe?.recordExtensionPillState(state, transitionToken: token)
                                        #endif
                                    },
                                    onExpiry: { ownerID, bucket, remainingMs in
                                        #if HOSTED_TEST
                                        hostedProbe?.recordExtensionPillExpiry(ownerID: ownerID, bucket: bucket, remainingMs: remainingMs)
                                        #endif
                                    }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 16)
                    }
                    .scrollClipDisabled()
                    .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.height } action: { height in
                        let current = ExtensionActivityPillComposerGeometry(
                            ownerIDs: groups.map(\.id), height: height
                        )
                        guard ExtensionActivityPillComposerGeometryPolicy.changed(
                            previous: extensionPillGeometry, current: current
                        ) else { return }
                        extensionPillGeometry = current
                        switch ExtensionActivityPillComposerGeometryPolicy.disposition(
                            isDetached: scrollCoordinator.userScrolledAway
                        ) {
                        case .noScrollWrites:
                            break
                        case .noSmoothFollow:
                            // The shared coordinator emits a disabled,
                            // frame-admitted follow; the pill reason never
                            // issues a smooth scroll or direct offset write.
                            scrollCoordinator.composerViewportTransitionBegan()
                        }
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
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
                    submissionPending
                        ? nil
                        : ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: reduceMotion),
                    value: pendingAttachments.map(\.id)
                )
            }

            if let selectedComposerSkill {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ComposerSkillChip(skill: selectedComposerSkill) {
                            guard let composerScope else { return }
                            withAnimation(ChatContentTransitionPolicy.attachmentAnimation(reduceMotion: reduceMotion)) {
                                model.composerDrafts.removeSelectedSkill(for: composerScope)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }

            if let picker = composerResourcePicker {
                ComposerResourcePicker(
                    kind: picker.kind,
                    query: picker.query,
                    entries: composerResourceResults,
                    onSelect: selectComposerResource,
                    onDismiss: dismissComposerResourcePicker
                )
                .padding(.horizontal, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
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
        }
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            let previous = composerLayoutHeight
            composerLayoutHeight = height
            if ChatComposerLayoutSignalPolicy.shouldSignal(previous: previous, current: height) {
                scrollCoordinator.composerViewportTransitionBegan()
            }
        }
        .background(alignment: .bottom) {
            ChatBottomActivityBlur(
                isActive: showsAmbientWorkingBlur,
                keyboardVisible: composerFocused
            )
                // The native safe-area inset moves the composer with the
                // keyboard. The background remains behind the input glass,
                // while its translated lower edge fills the keyboard corners.
                .offset(y: ChatBottomActivityBlurLayout.translation(
                    keyboardVisible: composerFocused
                ))
                .ignoresSafeArea(edges: .bottom)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.22),
                    value: composerFocused
                )
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
                    selection: $composerSelection,
                    isEditable: ChatComposerPolicy.isTextEditable(isTranscriptReady: isTranscriptReady),
                    keyboardAppearance: colorScheme == .dark ? .dark : .light
                )
                .padding(.horizontal, 2)
                .padding(.vertical, 10)
            }
            .frame(minHeight: 40)

            SessionContextProgressButton(
                presentation: contextProgressPresentation
            ) { showContext = true }

            if let composerTrailingMode {
                ComposerTrailingButton(
                    mode: composerTrailingMode,
                    isDisabled: sending || submissionPending || !isTranscriptReady,
                    isSending: sending,
                    offersQueueChoices: selectedAuthoritativeSnapshot?.phase.isActive == true,
                    onSend: { behavior in send(behavior: behavior) },
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
        // Sending is represented by the trailing control only. Animating the
        // entire glass bar while UIKit clears text/height and the transcript
        // installs a new row creates a competing structural transition.
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
                .font(TronTypography.sans(
                    size: ComposerControlMetrics.symbolSize,
                    weight: .semibold
                ))
                .foregroundStyle(attachmentActionsEnabled ? Color.tronEmerald : Color.tronTextMuted)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ComposerAttachmentMenuButton(
                isEnabled: attachmentActionsEnabled,
                showsSkills: skillPickerAvailable,
                onSelect: requestAttachmentPresentation
            )
            .frame(
                width: ComposerControlMetrics.hitTarget,
                height: ComposerControlMetrics.hitTarget
            )
            // Native menu action attributes may be cached across navigation.
            // Replace only when the viewed session or availability changes.
            .id(attachmentMenuState.identity)
            .accessibilityLabel("Add attachment")
        }
        .frame(
            width: ComposerControlMetrics.hitTarget,
            height: ComposerControlMetrics.hitTarget
        )
    }

    private var catchUpButton: some View {
        Button {
            catchUpToTail()
        } label: {
            Image(systemName: "arrow.down")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronEmerald)
                .frame(
                    width: ComposerControlMetrics.hitTarget,
                    height: ComposerControlMetrics.hitTarget
                )
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

    private var contextProgressPresentation: SessionContextProgressPresentation {
        let snapshot = selectedAuthoritativeSnapshot
        return SessionContextProgressPolicy.presentation(
            isTranscriptReady: isTranscriptReady && snapshot != nil,
            contextPercentage: snapshot.map(contextPercentage),
            modelName: snapshot?.model?.displayDescription,
            isCompacting: snapshot?.phase == .compacting
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
            Button { showSettings = true } label: {
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

    private var supportsSkillPrompt: Bool {
        model.gatewayInfo?.capabilities.contains("skill-prompt.v1") == true
    }

    private var skillPickerAvailable: Bool {
        guard supportsSkillPrompt, let presentationTarget else { return false }
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
            attachmentPresentationTask?.cancel()
            queuedAttachmentDestination = nil
            attachmentPresentationTask = Task { @MainActor in
                // Let the native menu complete dismissal before inserting the
                // inline child. The UITextView remains the responder owner.
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled, attachmentActionsEnabled else { return }
                let picker = ComposerResourcePickerSource.menu(kind)
                composerResourceResults = composerResourceCatalog.entries(kind: kind, query: "")
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82)) {
                    composerResourcePicker = picker
                }
            }
            return
        }
        dismissComposerResourcePicker()
        // End the responder lifetime before UIKit presents a picker. This also
        // invalidates queued becomeFirstResponder callbacks in the representable.
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

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
        precondition(!destination.isComposerResource)
        return Binding(
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

    private func reconcileComposerResourcePicker() {
        if let token = ComposerSuggestionTriggerPolicy.activeToken(
            in: composerText,
            selection: composerSelection
        ), token.kind != .skill || skillPickerAvailable {
            attachmentPresentationTask?.cancel()
            attachmentPresentationTask = nil
            if composerResourcePicker != .token(token) {
                composerResourceResults = composerResourceCatalog.entries(kind: token.kind, query: token.query)
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82)) {
                    composerResourcePicker = .token(token)
                }
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
            model.composerDrafts.selectSkill(entry.commandInfo, for: composerScope)
        case .command:
            let base: (text: String, selection: NSRange)
            let replacementRange: NSRange
            if case .token(let token) = composerResourcePicker {
                base = (composerText, composerSelection)
                replacementRange = token.replacementRange
            } else {
                // A command selected from the menu becomes the leading Pi
                // command; replace an existing exact command while retaining
                // its editable arguments.
                base = ComposerCommandCompletionPolicy.removingLeadingCommand(
                    text: composerText,
                    selection: composerSelection,
                    commands: composerResourceCatalog.commands
                )
                replacementRange = NSRange(location: 0, length: 0)
            }
            guard let replacement = ComposerSuggestionTriggerPolicy.replacing(
                text: base.text,
                range: replacementRange,
                with: "/\(entry.invocationName) "
            ) else { return }
            model.composerDrafts.removeSelectedSkill(for: composerScope)
            applyComposerReplacement(replacement)
        }
        dismissComposerResourcePicker()
    }

    private func applyComposerReplacement(_ replacement: (text: String, selection: NSRange)) {
        composerSelection = replacement.selection
        composerTextBinding.wrappedValue = replacement.text
    }

    private func dismissComposerResourcePicker() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.82)) {
            composerResourcePicker = nil
        }
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
    private func mutateQueue(
        affectedID: String,
        mutation: (inout [SessionSnapshot.QueuedMessage]) throws -> Void
    ) async {
        guard mutatingQueuedMessageIDs.isEmpty,
              let target = presentationTarget,
              let presentationGeneration = modelPresentationGeneration else { return }
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
        guard let mutationToken = queueMutationResolution.begin() else { return }
        mutatingQueuedMessageIDs.insert(affectedID)
        locallyMutatedQueueOperationIDs.formUnion(changedOperationIDs)
        queueMutationCommandIsPending = true
        pendingQueueMutationRevision = commit.expectedRevision
        do {
            try await model.replaceQueue(
                sessionID: sessionID,
                expectedRevision: commit.expectedRevision,
                items: commit.items
            )
            guard queueMutationResolution.isActive(mutationToken),
                  modelPresentationGeneration == presentationGeneration,
                  presentationTarget == target else {
                _ = queueMutationResolution.resolve(mutationToken, as: .retired)
                return
            }
            model.composerDrafts.invalidateSettledQueueHandoff(
                target: target,
                affectedOperationIDs: changedOperationIDs
            )
            locallyMutatedQueueOperationIDs.formUnion(
                ChatQueueMutationProjectionPolicy.exclusions(
                    for: .success,
                    affectedOperationIDs: changedOperationIDs
                )
            )
            queueMutationCommandIsPending = false
            resolveDeferredQueueMutationProjection()
            _ = queueMutationResolution.resolve(mutationToken, as: .commandCompleted)
            if ChatQueueMutationProjectionPolicy.shouldRetirePresentationState(
                commandIsPending: queueMutationCommandIsPending,
                expectedRevision: pendingQueueMutationRevision,
                installedRevision: transcriptPresentation.installed?.queueRevision
            ) {
                clearSettledQueueMutationPresentationState()
            }
            // Response-before-snapshot keeps controls inert and lineage excluded
            // until the exact newer sequenced queue frame installs. If that
            // frame raced ahead, the outcome-known check above clears now.
        } catch {
            guard queueMutationResolution.isActive(mutationToken),
                  modelPresentationGeneration == presentationGeneration,
                  presentationTarget == target else {
                _ = queueMutationResolution.resolve(mutationToken, as: .retired)
                return
            }
            queueMutationCommandIsPending = false
            clearSettledQueueMutationPresentationState()
            // Failure restores the pre-command interpretation before the held
            // canonical boundary installs, preserving its consumed entrance.
            resolveDeferredQueueMutationProjection()
            _ = queueMutationResolution.resolve(mutationToken, as: .commandCompleted)
            model.presentComposerActionError(error, target: target)
        }
    }

    @MainActor
    private func send(behavior explicitBehavior: String? = nil) {
        guard openingTask == nil,
              openPresentation.phase == .ready,
              let target = presentationTarget,
              model.ownsPresentation(target),
              let installed = transcriptPresentation.installed,
              installed.tag.presentationGeneration == target.generation,
              let source = transcriptProjectionCapture,
              source.tag.presentationGeneration == target.generation else { return }
        let behavior = explicitBehavior
            ?? ChatComposerPolicy.submissionBehavior(phase: selectedAuthoritativeSnapshot?.phase)
        if let composerScope,
           let selected = model.composerDrafts.selectedSkill(for: composerScope) {
            guard supportsSkillPrompt, model.commandCatalogTarget == target else {
                model.presentComposerActionError(
                    "Skills are still loading for this session.",
                    target: target
                )
                return
            }
            guard model.commands.filter({ $0 == selected }).count == 1 else {
                model.composerDrafts.removeSelectedSkill(for: composerScope)
                model.presentComposerActionError(
                    "That skill is no longer available for this session.",
                    target: target
                )
                return
            }
        }
        do {
            // Admission, composer collapse, and the local lifecycle graft share
            // one transaction. The full newest authoritative capture is then
            // submitted with animations disabled so concurrent streaming cannot
            // inherit this insertion choreography.
            let installedBeforeSubmission = transcriptPresentation.installed
            let entranceKind = ChatPromptLifecycleTransitionPolicy.entranceKind(
                for: ChatPromptBehavior(rawValue: behavior)
            )
            var transaction = Transaction(animation: ChatContentTransitionPolicy.revealAnimation(
                for: entranceKind,
                reduceMotion: reduceMotion
            ))
            if reduceMotion { transaction.disablesAnimations = true }
            let submission = try withTransaction(transaction) {
                composerResourcePicker = nil
                let submission = try model.beginComposerSubmission(
                    target: target,
                    behavior: behavior,
                    canonicalTranscript: model.transcriptSnapshot(for: sessionID)?.transcript ?? [],
                    queuedMessages: selectedAuthoritativeSnapshot?.displayedQueuedMessages ?? []
                )
                let submittedAttachments = model.composerDrafts.submittedAttachments(for: target)
                    .filter { submission.attachmentIDs.contains($0.id) }
                    .prefix(ComposerAttachmentPolicy.maximumCount)
                    .map { $0.frozenForHandoff() }
                if let installedBeforeSubmission {
                    _ = transcriptPresentation.graftLocalLifecycle(
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
            if !ChatComposerPolicy.preservesFocus(submissionBehavior: behavior) {
                composerFocused = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
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
        for item in values {
            guard !Task.isCancelled, presentationTarget == target else { return }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    model.presentComposerActionError(
                        "The selected photo could not be prepared.",
                        target: target
                    )
                    continue
                }
                guard !Task.isCancelled, presentationTarget == target else { return }
                let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                let filename = "photo.\(UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "jpg")"
                try await model.upload(
                    name: filename,
                    mimeType: mimeType,
                    data: data,
                    target: target
                )
            }
            catch is CancellationError { return }
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
