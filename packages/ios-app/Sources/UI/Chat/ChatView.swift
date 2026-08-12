import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var photos: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showContext = false
    @State private var showSettings = false
    @State private var sending = false
    @State private var transcriptVisible = false
    @State private var pendingEditorRequest: AppModel.EditorRequest?
    @State private var transcriptAtBottom = true
    @State private var userScrolledAway = false
    @State private var hasUnreadTranscript = false
    @State private var speech = SpeechTranscriber()
    @State private var composerHeight: CGFloat = 72
    @FocusState private var composerFocused: Bool

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
        .toolbar { toolbar }
        .sheet(isPresented: $showContext) { SessionContextSheet() }
        .sheet(isPresented: $showSettings) { SettingsView().presentationDragIndicator(.hidden) }
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
        .task(id: model.selectedSessionID) {
            transcriptVisible = false
            await Task.yield()
            withAnimation(.easeOut(duration: 0.28)) { transcriptVisible = true }
        }
        .onDisappear { speech.stop() }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let snapshot = model.selectedSnapshot {
                        if (snapshot.transcriptStart ?? 0) > 0 {
                            Button {
                                Task { await model.loadEarlierTranscript() }
                            } label: {
                                if model.loadingEarlierTranscript {
                                    TronLoadingState(label: "Loading earlier messages…")
                                } else {
                                    Label("Load earlier messages", systemImage: "arrow.up")
                                }
                            }
                            .buttonStyle(TronActionButtonStyle(expands: false))
                            .disabled(model.loadingEarlierTranscript)
                            .frame(maxWidth: .infinity)
                        }
                        let items = ChatTranscriptPresentation.items(in: snapshot)
                        let results = ChatTranscriptPresentation.toolResults(in: snapshot)
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            TranscriptRow(item: item, toolResults: results)
                                .id(item.id)
                                .opacity(transcriptVisible ? 1 : 0)
                                .offset(y: transcriptVisible ? 0 : 6)
                                .animation(
                                    .easeOut(duration: 0.22).delay(min(Double(index) * 0.025, 0.18)),
                                    value: transcriptVisible
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                        }
                        if let streaming = snapshot.streaming {
                            TranscriptRow(item: streaming, streaming: true, toolResults: results)
                                .id("streaming")
                                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
                        }
                        ForEach(snapshot.toolExecutions) { tool in
                            LiveToolCard(tool: tool)
                                .id("live-tool-\(tool.id)")
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
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
                                Label(value, systemImage: "info.circle").font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
                            }
                        }
                    } else { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
                    Color.clear
                        .frame(height: max(64, composerHeight - 6))
                        .id("transcript-bottom")
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16).padding(.vertical, 18)
                .animation(transcriptVisible ? .easeOut(duration: 0.25) : nil, value: model.selectedSnapshot?.transcript.map(\.id))
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: model.selectedSnapshot?.toolExecutions)
            }
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, isAtBottom in
                transcriptAtBottom = isAtBottom
                if isAtBottom {
                    userScrolledAway = false
                    hasUnreadTranscript = false
                }
            }
            .onScrollPhaseChange { _, phase, _ in
                if phase == .interacting || phase == .tracking || phase == .decelerating {
                    userScrolledAway = !transcriptAtBottom
                }
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
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
                    return
                }
                if !userScrolledAway {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo("transcript-bottom", anchor: .bottom)
                    }
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
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                        hasUnreadTranscript = false
                        userScrolledAway = false
                    } label: {
                        Label("New response", systemImage: "arrow.down")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(minHeight: 44)
                            .contentShape(Capsule())
                            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.24)).interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("New response")
                    .padding(.trailing, 12)
                    .padding(.bottom, composerHeight + 8)
                }
            }
        }
    }

    private var responseState: ChatResponseState? {
        model.selectedSnapshot.map(ChatResponseState.init)
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if let snapshot = model.selectedSnapshot {
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
                    TextField("", text: $text, axis: .vertical)
                        .tronInlineField(composer: true)
                        .foregroundStyle(Color.tronEmerald)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 10)
                        .lineLimit(1...8)
                        .focused($composerFocused)
                        .disabled(model.selectedSnapshot?.phase.isActive == true)
                        .accessibilityLabel("Message input")
                        .onSubmit { Task { await send() } }
                }
                .frame(minHeight: 40)
                .animation(.easeOut(duration: 0.18), value: speech.isRecording)

                if let snapshot = model.selectedSnapshot, !speech.isRecording {
                    SessionContextProgressButton(
                        contextPercentage: contextPercentage(snapshot),
                        modelName: snapshot.model.map { "\($0.provider) / \($0.id)" },
                        isCompacting: snapshot.phase == .compacting
                    ) { showContext = true }
                }

                ComposerTrailingButton(
                    mode: composerTrailingMode,
                    isDisabled: sending,
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

            if let snapshot = model.selectedSnapshot {
                ForEach(snapshot.extensionUI.widgets.filter { $0.placement == .belowEditor }) { widget in
                    ExtensionWidgetView(widget: widget)
                }
            }
        }
    }

    private var composerTrailingMode: ComposerTrailingMode {
        if model.selectedSnapshot?.phase.isActive == true { return .stopAgent }
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
        ToolbarItem(placement: .principal) {
            Text(model.selectedSnapshot?.extensionUI.title ?? model.selectedSnapshot?.name ?? model.sessions.first { $0.id == model.selectedSessionID }?.title ?? "Session")
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
            get: { model.selectedSnapshot?.extensionUI.pendingInteractions.first },
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

    private func statusText(_ phase: SessionPhase) -> String {
        switch phase { case .running: "Tron is working"; case .compacting: "Compacting context"; case .retrying: "Retrying provider"; case .interrupted: "Previous run was interrupted"; case .idle: "" }
    }
}

private struct PendingAttachmentChip: View {
    let attachment: AppModel.PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo.fill" : "doc.text.fill")
                .foregroundStyle(Color.tronBlue)
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

private struct LiveToolCard: View {
    let tool: ToolExecutionState

    var body: some View {
        ToolCard(
            title: tool.toolName,
            subtitle: subtitle,
            content: content,
            error: tool.isError,
            structured: tool.result ?? tool.partialResult ?? tool.arguments
        )
        .accessibilityLabel("\(tool.toolName), \(subtitle)")
    }

    private var subtitle: String {
        switch tool.status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }

    private var content: String {
        if let result = tool.result { return result.prettyPrinted }
        if let partial = tool.partialResult { return partial.prettyPrinted }
        return tool.arguments.prettyPrinted
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
