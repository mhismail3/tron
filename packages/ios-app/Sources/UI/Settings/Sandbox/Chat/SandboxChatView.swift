import SwiftUI

/// Settings → Setup → Sandbox → Chat · prototype: a new chat interface in the
/// Sandbox design language, with fake data only.
///
/// Layers, back to front (docs/design-language.md): the transcript, which owns
/// its scroll; the header (a safe-area bar, so scrolled content gets the
/// system's edge effect under it) and the bottom control row (a safe-area inset,
/// so the keyboard moves it and the last row stays visible); the menu's lower wash; the liquid action menu; the inset panel;
/// and the fluid sheets, the nested one on top. Only the top layer takes input.
struct SandboxChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chat = SandboxChatModel()
    @FocusState private var composerFocused: Bool
    @State private var showsEvents = false
    @State private var showsEventDetail = false

    private var motion: SandboxDesign.Motion { SandboxDesign.Motion(reduceMotion: reduceMotion) }

    var body: some View {
        ZStack {
            TronBackdrop().ignoresSafeArea()
            // The wash overlays the transcript only; the header and the control
            // row sit above it in the safe-area insets, so the menu stays sharp.
            transcript
                .overlay {
                    if chat.menuMounted {
                        SandboxMenuWash(open: chat.menuOpen) { setMenu(false) }
                    }
                }
                .safeAreaBar(edge: .top, spacing: 0) { header }
                // An inset, not a bar: the menu's circles rise above the row's
                // bounds and must stay hit-testable there.
                .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            if chat.overlay == .context {
                SandboxInsetPanel(onDismiss: { setOverlay(.none) }) { contextPanel }
                    .zIndex(1)
            }
        }
        .environment(\.sandboxMotion, motion)
        .tronFluidSheet(isPresented: $showsEvents) {
            SandboxSheetHeader(title: "Updates", onDone: { showsEvents = false })
        } content: {
            eventsList
        } footer: {
            EmptyView()
        }
        .tronFluidSheet(isPresented: $showsEventDetail) {
            SandboxSheetHeader(title: chat.selectedEvent?.title ?? "Update", onDone: { showsEventDetail = false })
        } content: {
            eventDetail
        } footer: {
            EmptyView()
        }
    }

    // MARK: Regions

    private var header: some View {
        HStack(spacing: SandboxDesign.Space.sm) {
            SandboxActionCircle(icon: "xmark", label: "Close prototype", diameter: SandboxDesign.Size.smallCircle) { dismiss() }
                .accessibilityIdentifier("chat-proto-close")
            Spacer(minLength: 0)
            SandboxContextPicker(title: chat.contextTitle, detail: chat.contextDetail) { setOverlay(.context) }
            Spacer(minLength: 0)
            SandboxActionCircle(icon: "slider.horizontal.3", label: "Manage session", diameter: SandboxDesign.Size.smallCircle) {}
                .accessibilityIdentifier("chat-proto-manage")
        }
        .padding(.horizontal, SandboxDesign.Space.sm)
        .padding(.bottom, SandboxDesign.Space.xs)
    }

    private var transcript: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: SandboxDesign.Space.lg) {
                ForEach(chat.entries) { entry in
                    entryView(entry)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .padding(.horizontal, SandboxDesign.Space.inset)
            .padding(.vertical, SandboxDesign.Space.md)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        // A hard top edge keeps scrolled text off the clock; the bottom stays soft.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .accessibilityIdentifier("chat-proto-transcript")
    }

    @ViewBuilder
    private func entryView(_ entry: SandboxChatModel.Entry) -> some View {
        switch entry {
        case .user(_, let text): SandboxUserMessage(text: text)
        case .assistant(_, let text): SandboxAssistantMessage(text: text)
        case .tools(let id, let tools):
            SandboxToolRun(id: id, tools: tools, expanded: chat.expandedTools.contains(id)) {
                withAnimation(motion.geometry) {
                    if chat.expandedTools.contains(id) { chat.expandedTools.remove(id) } else { chat.expandedTools.insert(id) }
                }
            }
        }
    }

    /// The feedback cluster above the composer's trailing edge, then the composer
    /// and the action circle. The row rides the keyboard through the safe-area inset.
    private var controls: some View {
        VStack(alignment: .trailing, spacing: SandboxDesign.Space.sm) {
            if !chat.events.isEmpty {
                SandboxFeedbackCluster(events: chat.events, collapsed: chat.feedbackCollapsed) {
                    composerFocused = false
                    showsEvents = true
                }
                .opacity(chat.menuOpen ? 0 : 1)
                .allowsHitTesting(!chat.menuOpen)
                .accessibilityHidden(chat.menuOpen)
            }
            HStack(alignment: .bottom, spacing: SandboxDesign.Space.sm) {
                SandboxComposerField(draft: $chat.draft, focus: $composerFocused)
                    .disabled(chat.menuOpen)
                SandboxLiquidMenu(open: chat.menuOpen, mounted: chat.menuMounted, items: menuItems,
                                  onToggle: { setMenu(!chat.menuOpen) })
                    .overlay {
                        if !chat.draft.isEmpty && !chat.menuOpen {
                            SandboxActionCircle(icon: "arrow.up", label: "Send", prominent: true) {
                                withAnimation(motion.geometry) { chat.send() }
                            }
                            .accessibilityIdentifier("chat-proto-send")
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
            }
        }
        .padding(.horizontal, SandboxDesign.Space.sm)
        .padding(.top, SandboxDesign.Space.xs)
        .padding(.bottom, SandboxDesign.Space.sm)
        .animation(motion.geometry, value: chat.draft.isEmpty)
    }

    private var menuItems: [SandboxLiquidMenu.Item] {
        [
            .init(id: "photo", icon: "photo", label: "Photo") { menuAction("photo", "Attached a photo", "IMG_2041.heic") },
            .init(id: "command", icon: "terminal", label: "Run command") { menuAction("terminal", "Ran a command", "git status") },
            .init(id: "task", icon: "checklist", label: "New task") { menuAction("checklist", "Started a task", "Docs sweep") },
        ]
    }

    // MARK: Overlays

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Context")
                .font(SandboxDesign.Typeface.title)
                .foregroundStyle(Color.tronTextPrimary)
                .padding(.horizontal, SandboxDesign.Space.inset)
                .padding(.top, 18)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(SandboxChatModel.contexts.enumerated()), id: \.offset) { index, context in
                if index > 0 { Divider().padding(.leading, 58) }
                Button {
                    withAnimation(motion.content) { chat.context = index }
                    setOverlay(.none)
                } label: {
                    SandboxGroupedRow(icon: index == 2 ? "leaf" : "folder", tint: .tronPrimary,
                                      title: context.0, detail: context.1, selected: chat.context == index)
                }
                .buttonStyle(SandboxPressStyle(scale: 0.98))
                .accessibilityIdentifier("chat-proto-context-\(index)")
            }
        }
        .padding(.bottom, 10)
    }

    private var eventsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(chat.events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider().padding(.leading, 58) }
                Button {
                    chat.selectedEvent = event
                    showsEventDetail = true
                } label: {
                    SandboxGroupedRow(icon: event.icon, tint: event.tint, title: event.title, detail: event.detail,
                                      trailing: index == 0 ? "now" : "\(index * 7)m")
                }
                .buttonStyle(SandboxPressStyle(scale: 0.98))
                .accessibilityIdentifier("chat-proto-event-\(index)")
            }
        }
        .padding(.bottom, 12)
    }

    private var eventDetail: some View {
        let event = chat.selectedEvent
        return VStack(alignment: .leading, spacing: SandboxDesign.Space.md) {
            HStack(spacing: 12) {
                Image(systemName: event?.icon ?? "circle")
                    .font(TronTypography.sans(size: 18, weight: .semibold))
                    .foregroundStyle(event?.tint ?? .tronPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill((event?.tint ?? .tronPrimary).opacity(0.12)))
                Text(event?.detail ?? "")
                    .font(SandboxDesign.Typeface.rowPrimary)
                    .foregroundStyle(Color.tronTextPrimary)
            }
            Text("A nested sheet: the update list stays mounted below, with its scroll position, and takes input again when this closes.")
                .font(SandboxDesign.Typeface.rowSecondary)
                .foregroundStyle(Color.tronTextSecondary)
        }
        .padding(.horizontal, SandboxDesign.Space.inset)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-proto-event-detail")
    }

    // MARK: Intents

    private func setMenu(_ open: Bool) {
        if open { composerFocused = false }
        TronHaptics.shared.play(.selectionChanged)
        let animate = {
            withAnimation(motion.progress) { chat.menuOpen = open } completion: {
                // Unmount only if no later tap reopened it.
                if !chat.menuOpen { chat.menuMounted = false }
            }
        }
        if open && !chat.menuMounted {
            // Mounted closed in this update; the spring starts from 0 on the next.
            chat.menuMounted = true
            Task { @MainActor in animate() }
        } else {
            animate()
        }
    }

    private func setOverlay(_ overlay: SandboxChatModel.Overlay) {
        if overlay != .none { composerFocused = false; if chat.menuOpen { setMenu(false) } }
        withAnimation(motion.geometry) { chat.overlay = overlay }
    }

    private func menuAction(_ icon: String, _ title: String, _ detail: String) {
        setMenu(false)
        chat.report(chat.makeEvent(icon, title, detail, .tronPrimary), animation: motion.progress)
    }
}

/// A sheet header: a quiet title and a Done circle.
struct SandboxSheetHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(SandboxDesign.Typeface.title)
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 60)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                SandboxActionCircle(icon: "checkmark", label: "Done", diameter: SandboxDesign.Size.smallCircle, action: onDone)
                    .accessibilityIdentifier("chat-proto-sheet-done")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}
