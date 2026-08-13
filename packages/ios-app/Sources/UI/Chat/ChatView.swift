import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private enum ChatAttachmentDestination: Hashable {
    case camera
    case photos
    case files
}

struct ChatView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var attachmentDestination: ChatAttachmentDestination?
    @State private var queuedAttachmentDestination: ChatAttachmentDestination?
    @State private var attachmentPresentationTask: Task<Void, Never>?
    @State private var showContext = false
    @State private var showSettings = false
    @State private var sending = false
    @State private var openPresentation: ChatOpenPresentationState
    @State private var openingTask: Task<Void, Never>?
    @State private var pagingTask: Task<Void, Never>?
    @State private var catchUpTask: Task<Void, Never>?
    @State private var modelPresentationGeneration: Int?
    @State private var pendingEditorRequest: AppModel.EditorRequest?
    @State private var speech = SpeechTranscriber()
    @State private var composerTextHeight: CGFloat = 20
    @State private var toolbarContainerWidth = ChatToolbarTitleLayout.defaultContainerWidth
    @State private var scrollToBottomRequest = 0
    @State private var scrollCoordinator = ChatScrollCoordinator()
    @State private var visibleTranscriptRowIDs: [String] = []
    @State private var transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var transcriptGeometry = ChatTranscriptGeometry.zero
    @State private var composerInputBarHeight: CGFloat = 40
    @Namespace private var composerGlassNamespace
    // UITextView is the responder owner. This mirrors delegate callbacks for
    // placeholder/scroll presentation; SwiftUI FocusState must not compete with
    // a UIViewRepresentable that has no `.focused` registration.
    @State private var composerFocused = false

    init(sessionID: String) {
        self.sessionID = sessionID
        _openPresentation = State(initialValue: ChatOpenPresentationState(sessionID: sessionID))
    }

    var body: some View {
        transcript
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Reserve one stable line. Multiline text, attachments, and
                // extension widgets expand upward in the overlay without
                // resizing or shifting the transcript viewport.
                Color.clear
                    .frame(height: 48)
                    .overlay(alignment: .bottom) {
                        composer.fixedSize(horizontal: false, vertical: true)
                    }
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
        .sheet(isPresented: $showContext) { SessionContextSheet() }
        .sheet(isPresented: $showSettings) { SettingsView(scope: .project).presentationDragIndicator(.hidden) }
        .sheet(isPresented: attachmentPresentationBinding(for: .camera)) {
            CameraCaptureSheet { image in Task { await importCameraImage(image) } }
        }
        .photosPicker(
            isPresented: attachmentPresentationBinding(for: .photos),
            selection: $photos,
            maxSelectionCount: 5,
            matching: .images
        )
        .sheet(item: interactionBinding) { interaction in ExtensionInteractionSheet(interaction: interaction) }
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
        .onChange(of: speech.transcript) { _, value in if !value.isEmpty { text = value } }
        .onChange(of: speech.error) { _, value in if let value { model.lastError = value } }
        .onChange(of: model.editorRequest) { _, request in
            guard let request, request.sessionId == model.selectedSessionID else { return }
            if text.isEmpty {
                text = request.action == .paste ? text + request.text : request.fullText
                model.editorRequest = nil
            } else {
                pendingEditorRequest = request
            }
        }
        .confirmationDialog("Replace the current draft?", isPresented: Binding(
            get: { pendingEditorRequest != nil },
            set: { if !$0 { pendingEditorRequest = nil } }
        )) {
            Button("Use Extension Text") {
                if let request = pendingEditorRequest {
                    text = request.action == .paste ? text + request.text : request.fullText
                    model.editorRequest = nil
                }
                pendingEditorRequest = nil
            }
            Button("Keep Current Draft", role: .cancel) { pendingEditorRequest = nil }
        } message: {
            Text("An extension requested a composer change. Tron will not overwrite what you typed without confirmation.")
        }
        .task(id: sessionID) { await beginOpeningPresentation() }
        .onDisappear {
            speech.stop()
            openingTask?.cancel()
            openingTask = nil
            pagingTask?.cancel()
            pagingTask = nil
            catchUpTask?.cancel()
            catchUpTask = nil
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
                        stableTranscriptRow(id: "earlier-messages") {
                            earlierMessagesChip(snapshot: snapshot)
                        }
                    }
                    let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
                    ForEach(timeline.items) { item in
                        stableTranscriptRow(id: item.id) {
                            ChatTranscriptRenderRow(
                                item: item,
                                hiddenThinkingLabel: snapshot.extensionUI.hiddenThinkingLabel
                            )
                            .equatable()
                        }
                    }
                    runtimeRows(snapshot)
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
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollPosition($transcriptScrollPosition)
        .tronScrollEdgeChrome()
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.15) { ids in
            visibleTranscriptRowIDs = ids.filter { $0 != "transcript-bottom" }
        }
        .onChange(of: transcriptScrollPosition.isPositionedByUser) { _, positionedByUser in
            scrollCoordinator.scrollPositionChanged(isPositionedByUser: positionedByUser)
        }
        .onScrollGeometryChange(for: ChatTranscriptGeometry.self) { geometry in
            ChatTranscriptGeometry(geometry)
        } action: { previous, geometry in
            transcriptGeometry = geometry
            guard isTranscriptReady else { return }
            if geometry.isViewportOnlyChange(from: previous) {
                scrollCoordinator.viewportChanged(previous: previous, current: geometry)
            } else if scrollCoordinator.geometryChanged(previous: previous, current: geometry) {
                scrollToTail(animated: false)
            }
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            if newPhase == .interacting || newPhase == .tracking || newPhase == .decelerating {
                catchUpTask?.cancel()
                catchUpTask = nil
            }
            if scrollCoordinator.scrollPhaseChanged(
                from: oldPhase,
                to: newPhase,
                finalGeometry: ChatTranscriptGeometry(context.geometry)
            ) {
                scrollToTail(animated: false)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: scrollToBottomRequest) { _, _ in
            scrollToTail(animated: true, force: true)
        }
        .onChange(of: responseState, initial: true) { previous, current in
            guard let current else { return }
            guard previous?.sessionID == current.sessionID else { return }
            if ChatUnreadResponsePolicy.shouldMarkUnread(
                previous: previous,
                current: current,
                userScrolledAway: scrollCoordinator.userScrolledAway
            ) {
                scrollCoordinator.semanticResponseArrived()
            }
        }
        .overlay { openingSurface }
    }

    private func stableTranscriptRow<Content: View>(
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(id)
    }

    private var selectedAuthoritativeSnapshot: SessionSnapshot? {
        model.authoritativeSnapshot(for: sessionID)
    }

    private var responseState: ChatResponseState? {
        selectedAuthoritativeSnapshot.map(ChatResponseState.init)
    }

    private var isTranscriptReady: Bool { openPresentation.phase == .ready }

    @ViewBuilder private func runtimeRows(_ snapshot: SessionSnapshot) -> some View {
        if snapshot.phase.isActive && snapshot.extensionUI.working.visible {
            stableTranscriptRow(id: "runtime-working") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.extensionUI.working.message ?? statusText(snapshot.phase)).foregroundStyle(.secondary)
                        if let retry = snapshot.retry {
                            Text("Attempt \(retry.attempt)\(retry.maxAttempts.map { " of \($0)" } ?? "")")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(TronTypography.caption).padding(.vertical, 4)
            }
        }
        if !snapshot.extensionUI.statuses.isEmpty {
            ForEach(snapshot.extensionUI.statuses.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                stableTranscriptRow(id: "runtime-status-\(key)") {
                    TranscriptNotice(title: value, icon: "info.circle.fill", tint: .tronInfo)
                }
            }
        }
    }

    private func statusText(_ phase: SessionPhase) -> String {
        switch phase {
        case .running: "Tron is working"
        case .compacting: "Compacting context"
        case .retrying: "Retrying provider"
        case .interrupted: "Previous run was interrupted"
        case .idle: ""
        }
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
        openingTask?.cancel()
        pagingTask?.cancel()
        modelPresentationGeneration = nil
        scrollCoordinator.resetForPresentation()
        let epoch = openPresentation.begin()
        transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
        transcriptGeometry = .zero
        visibleTranscriptRowIDs = []
        let task = Task { @MainActor in
            do {
                let generation = try await model.openSessionPresentation(sessionID)
                guard !Task.isCancelled,
                      openPresentation.installAuthoritativeBaseline(sessionID: sessionID, epoch: epoch) else {
                    await model.closeSessionPresentation(sessionID, generation: generation)
                    return
                }
                modelPresentationGeneration = generation
                positionLatestTail(epoch: epoch)
            } catch is CancellationError {
                return
            } catch {
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

    @MainActor
    private func positionLatestTail(epoch: Int) {
        // `ScrollPosition(edge: .bottom)` and the initial anchor provide the
        // baseline. Reissue once in the same MainActor turn that makes the
        // transcript ready, before native interaction can claim ownership.
        guard !Task.isCancelled,
              openPresentation.epoch == epoch,
              openPresentation.phase == .ready else { return }
        scrollCoordinator.beginOpeningBottomScroll()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
    }

    @MainActor
    private func scrollToTail(animated: Bool, force: Bool = false) {
        guard scrollCoordinator.beginAutomaticBottomScroll(force: force) else { return }
        let update = {
            transcriptScrollPosition.scrollTo(edge: .bottom)
        }
        if animated && !reduceMotion {
            withAnimation(.smooth(duration: 0.26), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
        if force { scrollCoordinator.clearUnreadAfterExplicitJump() }
    }

    @MainActor
    private func catchUpToTail() {
        catchUpTask?.cancel()
        catchUpTask = nil
        guard scrollCoordinator.beginAutomaticBottomScroll(force: true) else { return }
        // The tap is the durable follow decision, not the eventual animation
        // callback. New streamed growth therefore remains pinned immediately.
        scrollCoordinator.clearUnreadAfterExplicitJump()

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
            return
        }

        let longDistanceThreshold = max(320, transcriptGeometry.containerHeight * 0.8)
        guard transcriptGeometry.distanceFromBottom > longDistanceThreshold else {
            withAnimation(.smooth(duration: 0.30)) {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
            return
        }

        // Do not animate through a long lazy transcript: jump invisibly to a
        // small reveal distance, then animate only the final visible approach.
        let revealDistance = min(140, max(80, transcriptGeometry.containerHeight * 0.18))
        let bottomOffset = transcriptGeometry.contentHeight
            + transcriptGeometry.bottomInset
            - transcriptGeometry.containerHeight
        var stagedPosition = transcriptScrollPosition
        stagedPosition.scrollTo(y: max(0, bottomOffset - revealDistance))
        var stagingTransaction = Transaction()
        stagingTransaction.disablesAnimations = true
        withTransaction(stagingTransaction) {
            transcriptScrollPosition = stagedPosition
        }

        catchUpTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.30)) {
                transcriptScrollPosition.scrollTo(edge: .bottom)
            }
            catchUpTask = nil
        }
    }

    private func earlierMessagesChip(snapshot: SessionSnapshot) -> some View {
        Button {
            let sessionID = snapshot.sessionId
            let runtimeGeneration = snapshot.runtimeGeneration
            let previousStart = snapshot.transcriptStart ?? 0
            let previousGeometry = transcriptGeometry
            let visibleIDs = Set(visibleTranscriptRowIDs)
            let anchorID = ChatTranscriptPresentation.timeline(in: snapshot).ids.first(where: visibleIDs.contains)
            let wasScrolledAway = scrollCoordinator.userScrolledAway
            guard let presentationGeneration = modelPresentationGeneration else { return }
            scrollCoordinator.beginPrependingHistory()
            pagingTask?.cancel()
            pagingTask = Task { @MainActor in
                defer {
                    scrollCoordinator.endPrependingHistory(preserveScrolledAway: wasScrolledAway)
                    pagingTask = nil
                }
                await model.loadEarlierTranscript(presentationGeneration: presentationGeneration)
                guard !Task.isCancelled,
                      modelPresentationGeneration == presentationGeneration else { return }
                guard let current = model.authoritativeSnapshot(for: sessionID),
                      current.sessionId == sessionID,
                      current.runtimeGeneration == runtimeGeneration,
                      (current.transcriptStart ?? previousStart) < previousStart else { return }

                // Restore the semantic row first, then allow bounded late-layout
                // corrections while Markdown/attachments settle. Every pass is
                // generation-scoped and cancellation-aware.
                if let anchorID, scrollCoordinator.canRestorePrependPosition {
                    var position = transcriptScrollPosition
                    position.scrollTo(id: anchorID, anchor: .top)
                    transcriptScrollPosition = position
                }
                var lastHeight = transcriptGeometry.contentHeight
                var stablePasses = 0
                for _ in 0..<60 {
                    guard !Task.isCancelled,
                          modelPresentationGeneration == presentationGeneration,
                          scrollCoordinator.canRestorePrependPosition else { return }
                    try? await Task.sleep(for: .milliseconds(16))
                    guard scrollCoordinator.canRestorePrependPosition else { return }
                    let height = transcriptGeometry.contentHeight
                    let isStable = height > previousGeometry.contentHeight + 0.5 && abs(height - lastHeight) < 0.5
                    stablePasses = isStable ? stablePasses + 1 : 0
                    let delta = height - previousGeometry.contentHeight
                    if delta > 0.5 {
                        var position = transcriptScrollPosition
                        position.scrollTo(y: max(0, previousGeometry.offsetY + delta))
                        transcriptScrollPosition = position
                    }
                    if stablePasses >= 4 { break }
                    lastHeight = height
                }
                guard model.selectedSessionID == sessionID,
                      model.authoritativeSnapshot(for: sessionID)?.runtimeGeneration == runtimeGeneration,
                      modelPresentationGeneration == presentationGeneration else { return }
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
                ForEach(snapshot.extensionUI.widgets.filter { $0.placement == .aboveEditor }) { widget in
                    ExtensionWidgetView(widget: widget)
                }
            }

            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { attachment in
                            PendingAttachmentChip(attachment: attachment) {
                                model.removeAttachment(attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .transition(.opacity)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    composerInputBar
                    if scrollCoordinator.userScrolledAway {
                        catchUpButton
                    }
                }
            }
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.32, dampingFraction: 0.82),
                value: scrollCoordinator.userScrolledAway
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let snapshot = selectedAuthoritativeSnapshot {
                ForEach(snapshot.extensionUI.widgets.filter { $0.placement == .belowEditor }) { widget in
                    ExtensionWidgetView(widget: widget)
                }
            }
        }
    }

    private var composerInputBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Color.clear
                .frame(width: 40, height: 40)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            ZStack(alignment: .leading) {
                if text.isEmpty && !composerFocused {
                    Text(speech.isRecording ? "Listening…" : "Type here")
                        .font(TronTypography.input)
                        .foregroundStyle(Color.tronEmerald)
                        .padding(.leading, 2)
                        .padding(.vertical, 10)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                MultilineComposerTextView(
                    text: $text,
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
                .onChange(of: composerFocused) { _, focused in
                    guard focused else { return }
                    scrollToBottomRequest += 1
                }
            }
            .frame(minHeight: 40)
            .animation(.easeOut(duration: 0.18), value: speech.isRecording)

            if let snapshot = selectedAuthoritativeSnapshot, !speech.isRecording {
                SessionContextProgressButton(
                    contextPercentage: contextPercentage(snapshot),
                    modelName: snapshot.model.map { "\($0.provider) / \($0.id)" },
                    isCompacting: snapshot.phase == .compacting
                ) { showContext = true }
            }

            ComposerTrailingButton(
                mode: composerTrailingMode,
                isDisabled: sending || !isTranscriptReady,
                onSend: { Task { await send() } },
                onAbort: { Task { await model.abort() } },
                onMicTap: {
                    composerFocused = false
                    Task { await speech.toggle() }
                }
            )
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .padding(.horizontal, 4)
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .glassEffectID("chat-composer", in: composerGlassNamespace)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            composerInputBarHeight = max(40, height)
        }
        .overlay(alignment: .bottomLeading) {
            Menu {
                Button("Take Photo", systemImage: "camera") {
                    requestAttachmentPresentation(.camera)
                }
                .disabled(!attachmentActionsEnabled)
                Button("Select Photos", systemImage: "photo.on.rectangle") {
                    requestAttachmentPresentation(.photos)
                }
                .disabled(!attachmentActionsEnabled)
                Button("Attach Files", systemImage: "folder") {
                    requestAttachmentPresentation(.files)
                }
                .disabled(!attachmentActionsEnabled)
            } label: {
                Image(systemName: "plus")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.tronEmerald))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            // Native menu action attributes may be cached across navigation.
            // Replace only when the viewed session or effective availability changes.
            .id(attachmentMenuState.identity)
            .accessibilityLabel("Add attachment")
            .padding(.leading, 4)
        }
        .buttonStyle(.plain)
    }

    private var catchUpButton: some View {
        Button {
            catchUpToTail()
        } label: {
            Image(systemName: "arrow.down")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronEmerald)
                .frame(width: composerInputBarHeight, height: composerInputBarHeight)
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

    private var composerTrailingMode: ComposerTrailingMode {
        ChatComposerPolicy.trailingMode(
            phase: selectedAuthoritativeSnapshot?.phase,
            isRecording: speech.isRecording,
            hasContent: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.pendingAttachments.isEmpty
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

    private func send() async {
        let outgoing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty || !model.pendingAttachments.isEmpty else { return }
        let behavior = ChatComposerPolicy.submissionBehavior(phase: selectedAuthoritativeSnapshot?.phase)
        text = ""
        if !ChatComposerPolicy.preservesFocus(submissionBehavior: behavior) {
            composerFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        sending = true
        defer { sending = false }
        do { try await model.send(outgoing, behavior: behavior) }
        catch {
            text = ChatComposerPolicy.restoredDraft(outgoing: outgoing, currentDraft: text)
            model.lastError = error.localizedDescription
        }
    }

    private func importCameraImage(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            model.lastError = "The captured photo could not be prepared."
            return
        }
        do { try await model.upload(name: "photo.jpg", mimeType: "image/jpeg", data: data) }
        catch { model.lastError = error.localizedDescription }
    }

    private func importPhotos(_ values: [PhotosPickerItem]) async {
        photos = []
        for item in values {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do { try await model.upload(name: "photo.jpg", mimeType: item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg", data: data) }
            catch { model.lastError = error.localizedDescription }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        for url in urls.prefix(10) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try await model.upload(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: data)
            } catch { model.lastError = error.localizedDescription }
        }
    }
}

private struct PendingAttachmentChip: View {
    let attachment: AppModel.PendingAttachment
    let onRemove: () -> Void
    @State private var showPreview = false

    var body: some View {
        Group {
            if attachment.mimeType.hasPrefix("image/") {
                imagePreview
            } else {
                fileChip
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
    }

    private var imagePreview: some View {
        ZStack(alignment: .topTrailing) {
            if let image = decodedPreviewImage {
                Button { showPreview = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipped()
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                // Plain button semantics plus noninteractive glass keep a tap
                // from pulsing or morphing the staged photo.
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(attachment.name)")
                .accessibilityHint("Opens a photo preview")
            } else {
                Image(systemName: "photo.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(Color.tronBlue)
                    .frame(width: 64, height: 64)
                    .accessibilityLabel("Attached \(attachment.name)")
            }

            Button(action: onRemove) {
                ZStack {
                    Circle()
                        .fill(Color.tronBackground.opacity(0.92))
                    Circle()
                        .stroke(Color.tronTextMuted.opacity(0.35), lineWidth: 0.5)
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                }
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .frame(width: 64, height: 64)
        .glassEffect(
            .regular.tint(Color.tronBlue.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .sheet(isPresented: $showPreview) {
            if let image = decodedPreviewImage {
                AttachmentImagePreviewSheet(image: image)
            }
        }
    }

    private var decodedPreviewImage: UIImage? {
        attachment.previewData.flatMap(UIImage.init(data:))
    }

    private var fileChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "doc.text.fill").foregroundStyle(Color.tronBlue)
            Text(attachment.name)
                .font(TronTypography.code(size: TronTypography.sizeBody2))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 100)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.tronTextMuted)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .font(TronTypography.caption)
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(Color.tronBlue.opacity(0.22)).interactive(), in: Capsule())
    }
}

private struct ChatTranscriptRenderRow: View, Equatable {
    let item: ChatTranscriptRenderItem
    let hiddenThinkingLabel: String?

    @ViewBuilder var body: some View {
        switch item {
        case .transcript(let transcript):
            TranscriptRow(
                item: transcript,
                rendersToolCalls: false,
                hiddenThinkingLabel: hiddenThinkingLabel
            )
        case .message(let message):
            TranscriptRow(
                item: message.item,
                streaming: message.streaming,
                rendersToolCalls: false,
                projectedMessageParts: message.parts,
                showsMessageFooter: message.showsFooter,
                hiddenThinkingLabel: hiddenThinkingLabel
            )
        case .toolRun(let run):
            ToolRunView(run: run)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ExtensionWidgetView: View {
    let widget: ExtensionWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(widget.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(TronFont.mono(12)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.10)
        .padding(.horizontal, 12)
    }
}
