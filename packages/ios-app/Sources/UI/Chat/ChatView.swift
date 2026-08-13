import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showContext = false
    @State private var showSettings = false
    @State private var sending = false
    @State private var openPresentation: ChatOpenPresentationState
    @State private var openingTask: Task<Void, Never>?
    @State private var bottomSentinelVisible = false
    @State private var pendingEditorRequest: AppModel.EditorRequest?
    @State private var transcriptAtBottom = true
    @State private var userScrolledAway = false
    @State private var hasUnreadTranscript = false
    @State private var speech = SpeechTranscriber()
    @State private var composerHeight: CGFloat = 72
    @State private var composerTextHeight: CGFloat = 20
    @State private var scrollToBottomRequest = 0
    @State private var tailFollowTask: Task<Void, Never>?
    @State private var tailFollowGeneration = 0
    @State private var tailFollowRequested = false
    @State private var pendingComposerGrowthFollow = false
    @State private var isUserInteractingWithTranscript = false
    @State private var isRestoringEarlierMessages = false
    @State private var visibleTranscriptRowIDs: [String] = []
    @State private var transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var transcriptGeometry = ChatTranscriptGeometry.zero
    // UITextView is the responder owner. This mirrors delegate callbacks for
    // placeholder/scroll presentation; SwiftUI FocusState must not compete with
    // a UIViewRepresentable that has no `.focused` registration.
    @State private var composerFocused = false

    init(sessionID: String) {
        self.sessionID = sessionID
        _openPresentation = State(initialValue: ChatOpenPresentationState(sessionID: sessionID))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript
            composer
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ComposerHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                }
        }
        .onPreferenceChange(ComposerHeightPreferenceKey.self) { composerHeight = $0 }
        .background(Color.tronBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .background(InteractivePopGestureEnabler())
        .tint(Color.tronEmerald)
        .toolbar { toolbar }
        .sheet(isPresented: $showContext) { SessionContextSheet() }
        .sheet(isPresented: $showSettings) { SettingsView(scope: .project).presentationDragIndicator(.hidden) }
        .sheet(isPresented: $showCamera) {
            CameraCaptureSheet { image in Task { await importCameraImage(image) } }
        }
        .photosPicker(isPresented: $showPhotos, selection: $photos, maxSelectionCount: 5, matching: .images)
        .sheet(item: interactionBinding) { interaction in ExtensionInteractionSheet(interaction: interaction) }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await importFiles(result) }
        }
        .onChange(of: photos) { _, values in Task { await importPhotos(values) } }
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
            cancelTailFollow()
        }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let snapshot = model.authoritativeSnapshot(for: sessionID) {
                    if (snapshot.transcriptStart ?? 0) > 0 {
                        earlierMessagesChip(snapshot: snapshot)
                            .id("earlier-messages")
                    }
                    ChatTranscriptContent(snapshot: snapshot)
                        .equatable()
                }
                Color.clear
                    .frame(height: max(88, composerHeight + 20))
                Color.clear
                    .frame(height: 1)
                    .id("transcript-bottom")
                    .accessibilityHidden(true)
            }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .scrollTargetLayout()
                // Animate only structural insertions/removals. Streaming text and
                // progress updates keep stable rows out of a stack-wide layout
                // transaction, which avoids re-rendering long transcript tails.
                .animation(isTranscriptReady ? .easeOut(duration: 0.20) : nil, value: transcriptLayoutState)
                .opacity(isTranscriptReady ? 1 : 0)
                .offset(y: isTranscriptReady || reduceMotion ? 0 : 8)
                .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.26), value: isTranscriptReady)
                .accessibilityHidden(!isTranscriptReady)
                .allowsHitTesting(isTranscriptReady)
        }
        .defaultScrollAnchor(.bottom, for: .alignment)
        .scrollPosition($transcriptScrollPosition)
        .tronScrollEdgeChrome()
        .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.15) { ids in
                visibleTranscriptRowIDs = ids.filter { $0 != "transcript-bottom" }
                bottomSentinelVisible = ids.contains("transcript-bottom")
                completeInitialPositioningIfReady()
        }
        .onScrollGeometryChange(for: ChatTranscriptGeometry.self) { geometry in
                ChatTranscriptGeometry(
                    offsetY: geometry.contentOffset.y,
                    contentHeight: geometry.contentSize.height,
                    containerHeight: geometry.containerSize.height
                )
        } action: { previous, geometry in
                transcriptGeometry = geometry
                let isAtBottom = geometry.isAtBottom
                transcriptAtBottom = isAtBottom
                if isUserInteractingWithTranscript,
                   ChatTailFollowPolicy.userScrolledUp(
                    previousOffset: previous.offsetY,
                    currentOffset: geometry.offsetY
                   ) {
                    userScrolledAway = true
                    pendingComposerGrowthFollow = false
                    cancelTailFollow()
                } else if geometry.isAtExactBottom {
                    userScrolledAway = false
                    hasUnreadTranscript = false
                }
                completeInitialPositioningIfReady()
                if isTranscriptReady,
                   ChatTailFollowPolicy.shouldFollowContentGrowth(
                    previousHeight: previous.contentHeight,
                    currentHeight: geometry.contentHeight,
                    userScrolledAway: userScrolledAway,
                    isUserInteracting: isUserInteractingWithTranscript,
                    isRestoringEarlierMessages: isRestoringEarlierMessages
                   ) {
                    scheduleTailFollow(delay: .milliseconds(12))
                }
            }
        .onScrollPhaseChange { _, phase, _ in
                let interacting = phase == .interacting || phase == .tracking || phase == .decelerating
                isUserInteractingWithTranscript = interacting
                if interacting {
                    // A direct gesture always wins over automatic following,
                    // including a drag that begins inside the former 80pt tail tolerance.
                    cancelTailFollow()
                } else {
                    if transcriptGeometry.isAtExactBottom {
                        userScrolledAway = false
                        hasUnreadTranscript = false
                    }
                    if pendingComposerGrowthFollow {
                        pendingComposerGrowthFollow = false
                        if !userScrolledAway, !isRestoringEarlierMessages {
                            scheduleTailFollow(delay: .milliseconds(12))
                        }
                    }
                }
            }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: composerHeight) { previousHeight, currentHeight in
                switch ChatTailFollowPolicy.composerGrowthFollowDecision(
                    previousHeight: previousHeight,
                    currentHeight: currentHeight,
                    userScrolledAway: userScrolledAway,
                    isUserInteracting: isUserInteractingWithTranscript,
                    isRestoringEarlierMessages: isRestoringEarlierMessages
                ) {
                case .ignore:
                    break
                case .followNow:
                    scheduleTailFollow(delay: .milliseconds(12))
                case .followWhenIdle:
                    pendingComposerGrowthFollow = true
                }
            }
        .onChange(of: scrollToBottomRequest) { _, _ in
                scrollToTail(animated: true)
            }
        .onChange(of: responseState, initial: true) { previous, current in
                guard let current else {
                    hasUnreadTranscript = false
                    transcriptAtBottom = true
                    userScrolledAway = false
                    return
                }
                guard previous?.sessionID == current.sessionID else {
                    // Opening or creating a session hydrates its first authoritative
                    // snapshot before scroll geometry settles. That baseline is not
                    // unread response content and must not inherit another session's pill.
                    hasUnreadTranscript = false
                    transcriptAtBottom = true
                    userScrolledAway = false
                    return
                }
                if isTranscriptReady, !userScrolledAway {
                    scheduleTailFollow(delay: .milliseconds(28))
                } else if ChatUnreadResponsePolicy.shouldMarkUnread(
                    previous: previous,
                    current: current,
                    userScrolledAway: userScrolledAway
                ) {
                    hasUnreadTranscript = true
                }
            }
        .overlay(alignment: .bottomTrailing) {
                if hasUnreadTranscript {
                    Button {
                        scrollToTail(animated: true)
                    } label: {
                        Label("New response", systemImage: "arrow.down")
                            .chatTranscriptPill()
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("New response")
                    .padding(.trailing, 12)
                    .padding(.bottom, composerHeight + 8)
                }
            }
        .overlay { openingSurface }
    }

    private var selectedAuthoritativeSnapshot: SessionSnapshot? {
        model.authoritativeSnapshot(for: sessionID)
    }

    private var responseState: ChatResponseState? {
        selectedAuthoritativeSnapshot.map(ChatResponseState.init)
    }

    private var transcriptLayoutState: ChatTranscriptLayoutState? {
        selectedAuthoritativeSnapshot.map(ChatTranscriptLayoutState.init)
    }

    private var isTranscriptReady: Bool { openPresentation.phase == .ready }

    @ViewBuilder private var openingSurface: some View {
        switch openPresentation.phase {
        case .opening, .staging:
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
        cancelTailFollow()
        let epoch = openPresentation.begin()
        transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)
        transcriptGeometry = .zero
        bottomSentinelVisible = false
        visibleTranscriptRowIDs = []
        userScrolledAway = false
        hasUnreadTranscript = false
        pendingComposerGrowthFollow = false
        let task = Task { @MainActor in
            do {
                try await model.openSessionPresentation(sessionID)
                guard !Task.isCancelled,
                      openPresentation.installAuthoritativeBaseline(sessionID: sessionID, epoch: epoch) else { return }
                scrollToTail(animated: false)
                completeInitialPositioningIfReady()
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
    private func completeInitialPositioningIfReady() {
        guard case .staging = openPresentation.phase else { return }
        if transcriptGeometry.isValid, (!bottomSentinelVisible || !transcriptGeometry.isAtExactBottom) {
            scrollToTail(animated: false)
        }
        _ = openPresentation.observeLayout(
            sessionID: sessionID,
            epoch: openPresentation.epoch,
            geometryIsValid: transcriptGeometry.isValid,
            tailIsVisible: bottomSentinelVisible,
            isAtExactBottom: transcriptGeometry.isAtExactBottom
        )
    }

    @MainActor
    private func scrollToTail(animated: Bool, clearsUnread: Bool = true) {
        var position = transcriptScrollPosition
        let update = { position.scrollTo(edge: .bottom) }
        if animated && !reduceMotion {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
        transcriptScrollPosition = position
        userScrolledAway = false
        if clearsUnread { hasUnreadTranscript = false }
    }

    @MainActor
    private func scheduleTailFollow(delay: Duration) {
        tailFollowRequested = true
        // Keep one bounded-latency follower alive. A trailing debounce can be
        // starved forever by progress arriving faster than its delay.
        guard tailFollowTask == nil else { return }
        tailFollowGeneration &+= 1
        let generation = tailFollowGeneration
        tailFollowTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard !userScrolledAway,
                      !isUserInteractingWithTranscript,
                      !isRestoringEarlierMessages else { break }
                tailFollowRequested = false
                scrollToTail(animated: true, clearsUnread: false)
                // Let this scroll and another layout pass settle before deciding
                // whether growth during the pass needs one more follow.
                try? await Task.sleep(for: .milliseconds(72))
                guard !Task.isCancelled else { break }
                if !tailFollowRequested && transcriptGeometry.isAtExactBottom { break }
            }
            guard tailFollowGeneration == generation else { return }
            tailFollowTask = nil
            if tailFollowRequested,
               !userScrolledAway,
               !isUserInteractingWithTranscript,
               !isRestoringEarlierMessages {
                scheduleTailFollow(delay: .milliseconds(12))
            }
        }
    }

    @MainActor
    private func cancelTailFollow() {
        tailFollowGeneration &+= 1
        tailFollowTask?.cancel()
        tailFollowTask = nil
        tailFollowRequested = false
    }

    private func earlierMessagesChip(snapshot: SessionSnapshot) -> some View {
        Button {
            let sessionID = snapshot.sessionId
            let runtimeGeneration = snapshot.runtimeGeneration
            let previousStart = snapshot.transcriptStart ?? 0
            let previousGeometry = transcriptGeometry
            let visibleIDs = Set(visibleTranscriptRowIDs)
            let anchorID = ChatTranscriptPresentation.timeline(in: snapshot).ids.first(where: visibleIDs.contains)
            let wasScrolledAway = userScrolledAway
            isRestoringEarlierMessages = true
            pendingComposerGrowthFollow = false
            cancelTailFollow()
            Task { @MainActor in
                defer {
                    isRestoringEarlierMessages = false
                    userScrolledAway = wasScrolledAway
                }
                await model.loadEarlierTranscript()
                guard let current = model.authoritativeSnapshot(for: sessionID),
                      current.sessionId == sessionID,
                      current.runtimeGeneration == runtimeGeneration,
                      (current.transcriptStart ?? previousStart) < previousStart else { return }

                // Lazy rows and Markdown can settle over multiple passes. Require
                // several stable observations before applying the complete delta.
                var lastHeight = transcriptGeometry.contentHeight
                var stablePasses = 0
                for _ in 0..<40 {
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(8))
                    let height = transcriptGeometry.contentHeight
                    if height > previousGeometry.contentHeight + 0.5,
                       abs(height - lastHeight) < 0.5 {
                        stablePasses += 1
                        if stablePasses >= 3 { break }
                    } else {
                        stablePasses = 0
                    }
                    lastHeight = height
                }
                guard model.selectedSessionID == sessionID,
                      model.authoritativeSnapshot(for: sessionID)?.runtimeGeneration == runtimeGeneration else { return }
                let delta = transcriptGeometry.contentHeight - previousGeometry.contentHeight
                if delta > 0.5 {
                    var position = transcriptScrollPosition
                    position.scrollTo(y: max(0, previousGeometry.offsetY + delta))
                    transcriptScrollPosition = position
                } else if let anchorID {
                    var position = transcriptScrollPosition
                    position.scrollTo(id: anchorID, anchor: .top)
                    transcriptScrollPosition = position
                }
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
                        isEditable: isTranscriptReady && selectedAuthoritativeSnapshot?.phase.isActive != true
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
            .frame(minHeight: 40)
            .padding(.horizontal, 4)
            .glassEffect(
                .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(alignment: .bottomLeading) {
                Menu {
                    Button("Take Photo", systemImage: "camera") { showCamera = true }
                    Button("Select Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                    Button("Attach Files", systemImage: "folder") { showFiles = true }
                } label: {
                    Image(systemName: "plus")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Add attachment")
                .padding(.leading, 4)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let snapshot = selectedAuthoritativeSnapshot {
                ForEach(snapshot.extensionUI.widgets.filter { $0.placement == .belowEditor }) { widget in
                    ExtensionWidgetView(widget: widget)
                }
            }
        }
    }

    private var composerTrailingMode: ComposerTrailingMode {
        if selectedAuthoritativeSnapshot?.phase.isActive == true { return .stopAgent }
        if speech.isRecording { return .stopRecording }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty {
            return .send
        }
        return .record
    }

    private func contextPercentage(_ snapshot: SessionSnapshot) -> Int {
        if let percent = snapshot.contextUsage?.percent { return min(max(Int(percent.rounded()), 0), 100) }
        guard let usage = snapshot.contextUsage, usage.contextWindow > 0, let tokens = usage.tokens else { return 0 }
        return min(max(Int((Double(tokens) / Double(usage.contextWindow) * 100).rounded()), 0), 100)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Back")
        }
        ToolbarItem(placement: .principal) {
            Text(selectedAuthoritativeSnapshot?.extensionUI.title ?? selectedAuthoritativeSnapshot?.name ?? model.sessions.first { $0.id == sessionID }?.title ?? "Session")
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronEmerald)
                .lineLimit(1)
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

    private func send() async {
        let outgoing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty || !model.pendingAttachments.isEmpty else { return }
        text = ""
        composerFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        sending = true
        defer { sending = false }
        do { try await model.send(outgoing) }
        catch { text = outgoing; model.lastError = error.localizedDescription }
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

@MainActor
private struct ChatTranscriptContent: View, Equatable {
    let snapshot: SessionSnapshot
    private let identity: Identity

    init(snapshot: SessionSnapshot) {
        self.snapshot = snapshot
        identity = Identity(snapshot: snapshot)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.identity == rhs.identity }

    var body: some View {
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        ForEach(timeline.items) { item in
            ChatTranscriptRenderRow(
                item: item,
                hiddenThinkingLabel: snapshot.extensionUI.hiddenThinkingLabel
            )
            .equatable()
            .id(item.id)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
        }
        if snapshot.phase.isActive && snapshot.extensionUI.working.visible {
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
        if !snapshot.extensionUI.statuses.isEmpty {
            ForEach(snapshot.extensionUI.statuses.sorted(by: { $0.key < $1.key }), id: \.key) { _, value in
                TranscriptNotice(title: value, icon: "info.circle.fill", tint: .tronInfo)
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

    private struct Identity: Equatable {
        let sessionID: String
        let revision: Int
        let eventSequence: Int
        let transcriptStart: Int?
        let transcriptCount: Int
        let firstTranscriptID: String?
        let phase: SessionPhase
        let working: ExtensionUIState.Working
        let statuses: [String: String]
        let hiddenThinkingLabel: String?

        init(snapshot: SessionSnapshot) {
            sessionID = snapshot.sessionId
            revision = snapshot.revision
            eventSequence = snapshot.eventSequence
            transcriptStart = snapshot.transcriptStart
            transcriptCount = snapshot.transcript.count
            firstTranscriptID = snapshot.transcript.first?.id
            phase = snapshot.phase
            working = snapshot.extensionUI.working
            statuses = snapshot.extensionUI.statuses
            hiddenThinkingLabel = snapshot.extensionUI.hiddenThinkingLabel
        }
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

private struct ComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat { 72 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
