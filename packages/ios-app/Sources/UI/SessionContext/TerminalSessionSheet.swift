import SwiftUI
import SwiftTerm
import UIKit

@Observable
@MainActor
final class TerminalSessionController {
    struct RenderChunk: Identifiable { let id: UInt64; let bytes: [UInt8] }

    private struct PendingInput {
        let id: String
        let terminal: TerminalSnapshot
        var bytes: [UInt8]
    }

    private static let maximumInputBatchBytes = 64 * 1024
    private static let maximumPendingInputBytes = 256 * 1024

    let sessionId: String
    private let repository: any TerminalRepository
    private(set) var terminal: TerminalSnapshot?
    private(set) var chunks: [RenderChunk] = []
    private(set) var status = "Connecting"
    private(set) var errorMessage: String?
    private(set) var attachmentId: String?
    private(set) var lastSequence: UInt64 = 0
    private(set) var rendererGeneration: UInt64 = 0
    private(set) var history: [TerminalSnapshot] = []
    private var resizeTask: Task<Void, Never>?
    private var didStart = false
    private var isAttaching = false
    private var processState = "connecting"
    private var pendingInputs: [PendingInput] = []
    private var pendingInputBytes = 0
    private var inFlightInputId: String?
    private var isFlushingInput = false
    private var isDetached = false

    init(sessionId: String, repository: any TerminalRepository) {
        self.sessionId = sessionId
        self.repository = repository
    }

    var workingDirectory: String { terminal?.workingDirectory ?? "Session workspace" }
    var isRunning: Bool { processState == "running" }

    func start() async {
        guard !didStart else { return }
        didStart = true
        isDetached = false
        errorMessage = nil
        repository.setUpdateHandler { [weak self] update in self?.receive(update) }
        guard repository.isSupported else {
            didStart = false
            errorMessage = "This Tron server does not support Terminal."
            status = "Unavailable"
            return
        }
        do {
            let opened = try await repository.open(sessionId: sessionId, rows: 24, columns: 80)
            terminal = opened
            processState = opened.state
            status = "Attaching"
            try await attach()
            history = (try? await repository.list(sessionId: sessionId)) ?? []
            history.removeAll { $0.id == opened.id }
        } catch {
            didStart = false
            errorMessage = error.localizedDescription
            status = "Unavailable"
        }
    }

    func reconcile(continuity: EngineConnectionContinuity) async {
        guard continuity.isConnected else {
            if terminal != nil, processState == "running" { status = "Reconnecting" }
            return
        }
        if terminal == nil {
            await start()
            return
        }
        do {
            try await attach()
            await flushPendingInputs()
        } catch { status = "Reconnecting" }
    }

    func detach() async {
        resizeTask?.cancel()
        isDetached = true
        if let attachmentId { await repository.detach(attachmentId: attachmentId) }
        repository.setUpdateHandler(nil)
        attachmentId = nil
    }

    func send(_ bytes: [UInt8]) {
        guard let terminal, processState == "running", !bytes.isEmpty else { return }
        guard pendingInputBytes + bytes.count <= Self.maximumPendingInputBytes else {
            errorMessage = "Terminal input is waiting for the connection to recover."
            return
        }

        // INVARIANT: input already submitted under an idempotency identity is
        // immutable. New keystrokes coalesce only into a not-yet-submitted
        // batch so a typing burst does not wait on one network round trip per
        // character while byte order and retry identity remain exact.
        var offset = 0
        while offset < bytes.count {
            if let lastIndex = pendingInputs.indices.last,
               pendingInputs[lastIndex].id != inFlightInputId,
               pendingInputs[lastIndex].terminal.id == terminal.id,
               pendingInputs[lastIndex].terminal.generation == terminal.generation,
               pendingInputs[lastIndex].bytes.count < Self.maximumInputBatchBytes {
                let available = Self.maximumInputBatchBytes - pendingInputs[lastIndex].bytes.count
                let count = min(available, bytes.count - offset)
                pendingInputs[lastIndex].bytes.append(contentsOf: bytes[offset ..< offset + count])
                offset += count
            } else {
                let count = min(Self.maximumInputBatchBytes, bytes.count - offset)
                pendingInputs.append(PendingInput(
                    id: UUID().uuidString,
                    terminal: terminal,
                    bytes: Array(bytes[offset ..< offset + count])
                ))
                offset += count
            }
        }
        pendingInputBytes += bytes.count
        Task { await flushPendingInputs() }
    }

    func resize(columns: Int, rows: Int) {
        guard let terminal, processState == "running" else { return }
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let rows = UInt16(exactly: max(5, min(rows, 200))),
                  let columns = UInt16(exactly: max(20, min(columns, 400))) else { return }
            try? await repository.resize(terminal: terminal, rows: rows, columns: columns)
        }
    }

    func terminate() {
        guard let terminal else { return }
        Task {
            do { try await repository.terminate(terminal); status = "Stopping" }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func showHistory(_ selected: TerminalSnapshot) async {
        if let attachmentId { await repository.detach(attachmentId: attachmentId) }
        attachmentId = nil
        terminal = selected
        processState = selected.state
        status = "Loading history"
        lastSequence = 0
        chunks.removeAll(keepingCapacity: true)
        rendererGeneration &+= 1
        do { try await attach() } catch {
            errorMessage = error.localizedDescription
            status = "Unavailable"
        }
    }

    func showLiveTerminal() async {
        do {
            let opened = try await repository.open(sessionId: sessionId, rows: 24, columns: 80)
            await showHistory(opened)
            history = try await repository.list(sessionId: sessionId)
            history.removeAll { $0.id == opened.id }
        } catch {
            errorMessage = error.localizedDescription
            status = "Unavailable"
        }
    }

    private func attach() async throws {
        guard let terminal, !isAttaching else { return }
        isAttaching = true
        defer { isAttaching = false }
        if let attachmentId { await repository.detach(attachmentId: attachmentId) }
        let proposedAttachmentId = "termatt_\(UUID().uuidString)"
        attachmentId = proposedAttachmentId
        let attached: TerminalAttachmentSnapshot
        do {
            attached = try await repository.attach(
                terminalId: terminal.id,
                attachmentId: proposedAttachmentId,
                afterSequence: lastSequence
            )
        } catch {
            if attachmentId == proposedAttachmentId { attachmentId = nil }
            throw error
        }
        if attached.resetRequired {
            chunks.removeAll(keepingCapacity: true)
            rendererGeneration &+= 1
        }
        attachmentId = attached.attachmentId
        status = "Connected"
    }

    private func flushPendingInputs() async {
        guard !isFlushingInput, !isDetached, processState == "running" else { return }
        isFlushingInput = true
        defer {
            isFlushingInput = false
            inFlightInputId = nil
        }
        while !pendingInputs.isEmpty, !isDetached, processState == "running" {
            let input = pendingInputs[0]
            inFlightInputId = input.id
            do {
                try await repository.write(
                    input.bytes,
                    terminal: input.terminal,
                    inputId: input.id
                )
                if pendingInputs.first?.id == input.id {
                    pendingInputs.removeFirst()
                    pendingInputBytes -= input.bytes.count
                }
                inFlightInputId = nil
            } catch {
                status = "Reconnecting"
                return
            }
        }
    }

    private func receive(_ update: TerminalStreamUpdate) {
        switch update {
        case .status(let updateAttachmentId, let state, _, _):
            guard updateAttachmentId == attachmentId else { return }
            if let state, state != "catch_up_required" { processState = state }
            status = state == "catch_up_required" ? "Catching up" : (state ?? "Connected")
            if state == "catch_up_required" { Task { try? await attach() } }
        case .output(let updateAttachmentId, let sequence, let bytes):
            guard updateAttachmentId == attachmentId, sequence > lastSequence else { return }
            lastSequence = sequence
            chunks.append(RenderChunk(id: sequence, bytes: bytes))
            if chunks.count > 2_048 { chunks.removeFirst(chunks.count - 2_048) }
        }
    }
}

@Observable
@MainActor
private final class TerminalKeyboardController {
    private weak var terminalView: TronNativeTerminalView?
    private(set) var isKeyboardPresented = false
    private(set) var isExtendedKeyboardPresented = false
    private(set) var isControlModifierEnabled = false
    private(set) var isTouchScrollingEnabled = false

    func attach(_ view: TronNativeTerminalView) {
        guard terminalView !== view else { return }
        terminalView = view
        view.inputAccessoryView = nil
        applyExtendedKeyboard(to: view)
        sync(from: view)
    }

    func detach(_ view: TronNativeTerminalView) {
        guard terminalView === view else { return }
        terminalView = nil
        isKeyboardPresented = false
        isControlModifierEnabled = false
    }

    func keyboardPresentationChanged(_ isPresented: Bool) {
        isKeyboardPresented = isPresented
    }

    func send(_ bytes: [UInt8]) {
        terminalView?.send(bytes)
    }

    func send(_ text: String) {
        terminalView?.insertText(text)
    }

    func sendCursor(_ cursor: TerminalCursorKey) {
        guard let terminalView else { return }
        terminalView.send(cursor.bytes(applicationCursor: terminalView.getTerminal().applicationCursor))
    }

    func toggleControlModifier() {
        guard let terminalView else { return }
        terminalView.controlModifier.toggle()
        isControlModifierEnabled = terminalView.controlModifier
    }

    func toggleTouchScrolling() {
        guard let terminalView else { return }
        terminalView.allowMouseReporting.toggle()
        isTouchScrollingEnabled = !terminalView.allowMouseReporting
    }

    func toggleExtendedKeyboard() {
        guard let terminalView else { return }
        isExtendedKeyboardPresented.toggle()
        applyExtendedKeyboard(to: terminalView)
        UIView.performWithoutAnimation {
            terminalView.reloadInputViews()
        }
        _ = terminalView.becomeFirstResponder()
    }

    func dismissKeyboard() {
        _ = terminalView?.resignFirstResponder()
    }

    func sync(from view: TerminalView) {
        isControlModifierEnabled = view.controlModifier
        isTouchScrollingEnabled = !view.allowMouseReporting
    }

    private func applyExtendedKeyboard(to view: TronNativeTerminalView) {
        view.inputView = isExtendedKeyboardPresented
            ? TerminalExtendedKeyboardView(terminalView: view)
            : nil
    }
}

enum TerminalCursorKey: CaseIterable {
    case left
    case down
    case up
    case right

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .left:
            applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .down:
            applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .up:
            applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .right:
            applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
        }
    }

    var symbolName: String {
        switch self {
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .up: "arrow.up"
        case .right: "arrow.right"
        }
    }
}

struct TerminalExtendedKey: Equatable {
    enum Action: Equatable {
        case bytes([UInt8])
        case function(Int)
        case home
        case end
    }

    let title: String
    let action: Action
    let isNavigation: Bool

    init(_ title: String, _ action: Action, isNavigation: Bool = false) {
        self.title = title
        self.action = action
        self.isNavigation = isNavigation
    }

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch action {
        case .bytes(let bytes):
            bytes
        case .function(let index):
            EscapeSequences.cmdF[index]
        case .home:
            applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal
        case .end:
            applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal
        }
    }

    static let rows: [[TerminalExtendedKey]] = [
        (0 ..< 10).map { TerminalExtendedKey("F\($0 + 1)", .function($0)) },
        [
            TerminalExtendedKey("[", .bytes(Array("[".utf8))),
            TerminalExtendedKey("]", .bytes(Array("]".utf8))),
            TerminalExtendedKey("{", .bytes(Array("{".utf8))),
            TerminalExtendedKey("}", .bytes(Array("}".utf8))),
            TerminalExtendedKey("<", .bytes(Array("<".utf8))),
            TerminalExtendedKey(">", .bytes(Array(">".utf8))),
            TerminalExtendedKey("&", .bytes(Array("&".utf8))),
            TerminalExtendedKey("Ins", .bytes(EscapeSequences.cmdInsert), isNavigation: true),
            TerminalExtendedKey("Home", .home, isNavigation: true),
            TerminalExtendedKey("PgUp", .bytes(EscapeSequences.cmdPageUp), isNavigation: true),
        ],
        [
            TerminalExtendedKey("+", .bytes(Array("+".utf8))),
            TerminalExtendedKey("−", .bytes(Array("-".utf8))),
            TerminalExtendedKey("*", .bytes(Array("*".utf8))),
            TerminalExtendedKey("=", .bytes(Array("=".utf8))),
            TerminalExtendedKey("%", .bytes(Array("%".utf8))),
            TerminalExtendedKey("`", .bytes(Array("`".utf8))),
            TerminalExtendedKey("\\", .bytes(Array("\\".utf8))),
            TerminalExtendedKey("Del", .bytes(EscapeSequences.cmdDelKey), isNavigation: true),
            TerminalExtendedKey("End", .end, isNavigation: true),
            TerminalExtendedKey("PgDn", .bytes(EscapeSequences.cmdPageDown), isNavigation: true),
        ],
    ]
}

struct TerminalSessionSheet: View {
    @Environment(\.dependencies) private var dependencies
    @State private var controller: TerminalSessionController
    @State private var keyboard = TerminalKeyboardController()
    @State private var confirmTerminate = false

    init(sessionId: String, repository: any TerminalRepository) {
        _controller = State(
            initialValue: TerminalSessionController(
                sessionId: sessionId,
                repository: repository
            )
        )
    }

    var body: some View {
        SettingsPageContainer(
            title: "Terminal",
            scrollsContent: false,
            leadingToolbar: { terminalMenu }
        ) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(controller.status == "Connected" ? Color.tronEmerald : Color.tronAmber).frame(width: 7, height: 7)
                    Text(controller.workingDirectory)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(controller.status)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                }
                .padding(.horizontal, 16).padding(.vertical, 9)

                if let error = controller.errorMessage, controller.terminal == nil {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(error))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativeTerminalView(controller: controller, keyboard: keyboard)
                        .id(controller.rendererGeneration)
                        .padding(.horizontal, 8)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if keyboard.isKeyboardPresented {
                    TerminalControlBar(keyboard: keyboard)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .adaptivePresentationDetents([.large], ipadSizing: .largeForm)
        .animation(.easeOut(duration: 0.16), value: keyboard.isKeyboardPresented)
        .task { await controller.start() }
        .task(id: dependencies.connectionRepository.continuity) {
            await controller.reconcile(continuity: dependencies.connectionRepository.continuity)
        }
        .onDisappear { Task { await controller.detach() } }
        .confirmationDialog("Terminate this terminal?", isPresented: $confirmTerminate, titleVisibility: .visible) {
            Button("Terminate Terminal", role: .destructive) { controller.terminate() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The shell and its running process group will stop. Closing the sheet alone only detaches.") }
    }

    private var terminalMenu: some View {
        Menu {
            if !controller.isRunning {
                Button("Open Live Terminal", systemImage: "terminal") {
                    Task { await controller.showLiveTerminal() }
                }
            }
            if !controller.history.isEmpty {
                Section("Recent terminals") {
                    ForEach(controller.history) { terminal in
                        Button {
                            Task { await controller.showHistory(terminal) }
                        } label: {
                            Label(
                                terminal.exitedAt ?? terminal.createdAt,
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                    }
                }
            }
            Button("Terminate Terminal", role: .destructive) { confirmTerminate = true }
                .disabled(!controller.isRunning)
        } label: {
            Image(systemName: "ellipsis")
                .font(TronTypography.buttonSM)
                .foregroundStyle(.tronEmerald)
        }
    }
}

private struct NativeTerminalView: UIViewRepresentable {
    let controller: TerminalSessionController
    let keyboard: TerminalKeyboardController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, keyboard: keyboard)
    }

    func makeUIView(context: Context) -> TronNativeTerminalView {
        let view = TronNativeTerminalView(
            frame: .zero,
            font: TronTypography.uiFont(mono: true, size: TronTypography.sizeBody3)
        )
        view.terminalDelegate = context.coordinator
        view.backgroundColor = .clear
        view.layer.backgroundColor = UIColor.clear.cgColor
        view.nativeBackgroundColor = .clear
        view.nativeForegroundColor = .label
        view.caretColor = .label
        view.inputAccessoryView = nil
        view.focusDidChange = { [weak keyboard] isPresented in
            keyboard?.keyboardPresentationChanged(isPresented)
        }
        keyboard.attach(view)
        TronScrollEdgeEffects.applySoft(to: view)
        return view
    }

    func updateUIView(_ view: TronNativeTerminalView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.keyboard = keyboard
        keyboard.attach(view)
        for chunk in controller.chunks where chunk.id > context.coordinator.lastFedSequence {
            view.feed(byteArray: chunk.bytes[...])
            context.coordinator.lastFedSequence = chunk.id
        }
    }

    static func dismantleUIView(
        _ view: TronNativeTerminalView,
        coordinator: Coordinator
    ) {
        coordinator.keyboard.detach(view)
        view.focusDidChange = nil
        view.terminalDelegate = nil
    }

    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        var controller: TerminalSessionController
        var keyboard: TerminalKeyboardController
        var lastFedSequence: UInt64 = 0
        init(
            controller: TerminalSessionController,
            keyboard: TerminalKeyboardController
        ) {
            self.controller = controller
            self.keyboard = keyboard
        }
        @MainActor func send(source: TerminalView, data: ArraySlice<UInt8>) {
            controller.send(Array(data))
            Task { @MainActor [weak keyboard] in
                await Task.yield()
                keyboard?.sync(from: source)
            }
        }
        @MainActor func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            controller.resize(columns: newCols, rows: newRows)
        }
        @MainActor func setTerminalTitle(source: TerminalView, title: String) {}
        @MainActor func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        @MainActor func scrolled(source: TerminalView, position: Double) {}
        @MainActor func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        @MainActor func bell(source: TerminalView) { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        @MainActor func clipboardCopy(source: TerminalView, content: Data) { UIPasteboard.general.setData(content, forPasteboardType: "public.data") }
        @MainActor func clipboardRead(source: TerminalView) -> Data? { nil }
        @MainActor func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        @MainActor func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct TerminalControlBar: View {
    let keyboard: TerminalKeyboardController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                scrollingControls
            }
            // INVARIANT: controls clip to their allocated viewport. The
            // capsule clips the curved outer edge; this scroll viewport clips
            // the fixed dismiss region's straight inner edge.
            .scrollClipDisabled(false)
            .frame(maxWidth: .infinity)

            Divider()
                .frame(height: 22)
                .accessibilityHidden(true)

            stickyDismissButton
                .frame(width: 44)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .clipShape(Capsule())
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.2)).interactive(),
            in: Capsule()
        )
        .padding(.horizontal, 8)
        // Keep the terminal's last visible row comfortably clear of the
        // floating control surface while preserving the keyboard attachment.
        .padding(.top, 12)
        .padding(.bottom, 5)
    }

    private var scrollingControls: some View {
        HStack(spacing: 2) {
            textButton("esc", accessibilityLabel: "Escape") {
                keyboard.send(EscapeSequences.cmdEsc)
            }
            toggleButton(
                "ctrl",
                accessibilityLabel: "Control modifier",
                isSelected: keyboard.isControlModifierEnabled,
                action: keyboard.toggleControlModifier
            )
            imageButton("arrow.right.to.line.compact", accessibilityLabel: "Tab") {
                keyboard.send(EscapeSequences.cmdTab)
            }
            textButton("~", accessibilityLabel: "Tilde") { keyboard.send("~") }
            textButton("|", accessibilityLabel: "Pipe") { keyboard.send("|") }
            textButton("/", accessibilityLabel: "Slash") { keyboard.send("/") }
            textButton("−", accessibilityLabel: "Dash") { keyboard.send("-") }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)

            ForEach(TerminalCursorKey.allCases, id: \.self) { cursor in
                imageButton(cursor.symbolName, accessibilityLabel: "Move \(cursor)") {
                    keyboard.sendCursor(cursor)
                }
            }

            toggleImageButton(
                keyboard.isTouchScrollingEnabled ? "hand.draw.fill" : "hand.draw",
                accessibilityLabel: "Touch scrolling",
                isSelected: keyboard.isTouchScrollingEnabled,
                action: keyboard.toggleTouchScrolling
            )
            toggleImageButton(
                "rectangle.grid.3x2",
                accessibilityLabel: "Command keys",
                isSelected: keyboard.isExtendedKeyboardPresented,
                action: keyboard.toggleExtendedKeyboard
            )
        }
        .padding(.horizontal, 7)
        .frame(height: 42)
    }

    private var stickyDismissButton: some View {
        imageButton(
            "keyboard.chevron.compact.down",
            accessibilityLabel: "Dismiss keyboard",
            action: keyboard.dismissKeyboard
        )
    }

    private func textButton(
        _ title: String,
        accessibilityLabel: String,
        color: SwiftUI.Color = .tronTextPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                .frame(minWidth: 30, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func toggleButton(
        _ title: String,
        accessibilityLabel: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        textButton(
            title,
            accessibilityLabel: accessibilityLabel,
            color: isSelected ? SwiftUI.Color.tronEmerald : .tronTextPrimary,
            action: action
        )
            .accessibilityAddTraits(
                isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits()
            )
    }

    private func imageButton(
        _ systemName: String,
        accessibilityLabel: String,
        color: SwiftUI.Color = .tronTextPrimary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .frame(minWidth: 30, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    private func toggleImageButton(
        _ systemName: String,
        accessibilityLabel: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        imageButton(
            systemName,
            accessibilityLabel: accessibilityLabel,
            color: isSelected ? SwiftUI.Color.tronEmerald : .tronTextPrimary,
            action: action
        )
            .accessibilityAddTraits(
                isSelected ? AccessibilityTraits.isSelected : AccessibilityTraits()
            )
    }
}

private final class TronNativeTerminalView: TerminalView {
    var focusDidChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { focusDidChange?(true) }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { focusDidChange?(false) }
        return resignedFirstResponder
    }
}

private final class TerminalExtendedKeyboardView: UIInputView, UIInputViewAudioFeedback {
    private weak var terminalView: TerminalView?

    var enableInputClicksWhenVisible: Bool { true }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 176)
    }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(
            frame: CGRect(x: 0, y: 0, width: 0, height: 176),
            inputViewStyle: .keyboard
        )
        autoresizingMask = [.flexibleWidth]
        buildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildRows() {
        let rows = UIStackView()
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 6
        rows.translatesAutoresizingMaskIntoConstraints = false

        for keys in TerminalExtendedKey.rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 5
            for key in keys {
                row.addArrangedSubview(button(for: key))
            }
            rows.addArrangedSubview(row)
        }

        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rows.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
    }

    private func button(for key: TerminalExtendedKey) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = key.title
        configuration.cornerStyle = .medium
        configuration.baseForegroundColor = key.isNavigation ? .systemGreen : .label
        configuration.baseBackgroundColor = key.isNavigation
            ? UIColor.systemGreen.withAlphaComponent(0.16)
            : .secondarySystemFill
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 1, bottom: 5, trailing: 1)
        let titleFont = TronTypography.uiFont(
            mono: true,
            size: TronTypography.sizeBody2,
            weight: .semibold
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = titleFont
            return outgoing
        }

        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.65
        button.accessibilityLabel = key.title
        button.addAction(UIAction { [weak self] _ in
            guard let terminalView = self?.terminalView else { return }
            UIDevice.current.playInputClick()
            terminalView.send(key.bytes(
                applicationCursor: terminalView.getTerminal().applicationCursor
            ))
        }, for: .touchDown)
        return button
    }
}
