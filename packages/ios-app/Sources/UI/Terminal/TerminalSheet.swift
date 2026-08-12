import SwiftTerm
import SwiftUI
import UIKit

@MainActor
@Observable
private final class TerminalController {
    var terminal: TerminalSummary?
    var error: String?
    var connectionPhase: TerminalConnectionPhase = .connecting
    var history: [TerminalSummary] = []
    private var resizeTask: Task<Void, Never>?

    var isRunning: Bool { terminal?.exitedAt == nil }

    func start(model: AppModel) async {
        guard terminal == nil else { return }
        connectionPhase = .connecting
        error = nil
        do {
            let terminals = try await model.listTerminals().sorted { $0.createdAt > $1.createdAt }
            history = terminals
            if let existing = terminals.first(where: { $0.exitedAt == nil }) {
                terminal = try await model.attachTerminal(existing.id, after: 0)
            } else {
                terminal = try await model.openTerminal(columns: 80, rows: 24)
            }
            history.removeAll { $0.id == terminal?.id }
            connectionPhase = .connected
        } catch {
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    func show(_ selected: TerminalSummary, model: AppModel) async {
        if let current = terminal { await model.detachTerminal(current.id) }
        error = nil
        connectionPhase = .connecting
        terminal = nil
        do {
            terminal = try await model.attachTerminal(selected.id, after: 0)
            connectionPhase = .connected
        } catch {
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    func openLive(model: AppModel) async {
        if let current = terminal { await model.detachTerminal(current.id) }
        error = nil
        connectionPhase = .connecting
        terminal = nil
        do {
            terminal = try await model.openTerminal(columns: 80, rows: 24)
            history = try await model.listTerminals()
            history.removeAll { $0.id == terminal?.id }
            connectionPhase = .connected
        } catch {
            self.error = error.localizedDescription
            connectionPhase = .unavailable
        }
    }

    func send(_ bytes: ArraySlice<UInt8>, model: AppModel) {
        guard let id = terminal?.id, terminal?.exitedAt == nil else { return }
        let data = String(decoding: bytes, as: UTF8.self)
        Task {
            do { try await model.writeTerminal(id, data: data) }
            catch {
                self.error = error.localizedDescription
                self.connectionPhase = .reconnecting
            }
        }
    }

    func resize(columns: Int, rows: Int, model: AppModel) {
        guard let id = terminal?.id, terminal?.exitedAt == nil else { return }
        resizeTask?.cancel()
        resizeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                try await model.resizeTerminal(
                    id,
                    columns: max(20, min(columns, 400)),
                    rows: max(5, min(rows, 200))
                )
            } catch {
                self.error = error.localizedDescription
                self.connectionPhase = .reconnecting
            }
        }
    }

    func terminate(model: AppModel) {
        guard let id = terminal?.id else { return }
        Task {
            do { try await model.terminateTerminal(id) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private enum TerminalConnectionPhase: Equatable {
    case connecting, connected, reconnecting, unavailable

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .unavailable: "Unavailable"
        }
    }

    var color: SwiftUI.Color {
        switch self {
        case .connected: .tronEmerald
        case .connecting, .reconnecting: .tronAmber
        case .unavailable: .tronError
        }
    }
}

@MainActor
@Observable
private final class TerminalKeyboardController {
    private weak var terminalView: TronNativeTerminalView?
    var isKeyboardPresented = false
    var isExtendedKeyboardPresented = false
    var isControlModifierEnabled = false
    var isTouchScrollingEnabled = false

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

    func send(_ bytes: [UInt8]) { terminalView?.send(bytes) }
    func send(_ text: String) { terminalView?.send(txt: text) }

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
        UIView.performWithoutAnimation { terminalView.reloadInputViews() }
        _ = terminalView.becomeFirstResponder()
    }

    func dismissKeyboard() { _ = terminalView?.resignFirstResponder() }

    func sync(from view: TerminalView) {
        isControlModifierEnabled = view.controlModifier
        isTouchScrollingEnabled = !view.allowMouseReporting
    }

    private func applyExtendedKeyboard(to view: TronNativeTerminalView) {
        view.inputView = isExtendedKeyboardPresented ? TerminalExtendedKeyboardView(terminalView: view) : nil
    }
}

private enum TerminalCursorKey: CaseIterable {
    case left, down, up, right

    func bytes(applicationCursor: Bool) -> [UInt8] {
        switch self {
        case .left: applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
        case .down: applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
        case .up: applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
        case .right: applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
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

private struct TerminalExtendedKey: Equatable {
    enum Action: Equatable { case bytes([UInt8]), function(Int), home, end }
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
        case .bytes(let bytes): bytes
        case .function(let index): EscapeSequences.cmdF[index]
        case .home: applicationCursor ? EscapeSequences.moveHomeApp : EscapeSequences.moveHomeNormal
        case .end: applicationCursor ? EscapeSequences.moveEndApp : EscapeSequences.moveEndNormal
        }
    }

    static let rows: [[TerminalExtendedKey]] = [
        (0 ..< 10).map { TerminalExtendedKey("F\($0 + 1)", .function($0)) },
        [
            TerminalExtendedKey("[", .bytes(Array("[".utf8))), TerminalExtendedKey("]", .bytes(Array("]".utf8))),
            TerminalExtendedKey("{", .bytes(Array("{".utf8))), TerminalExtendedKey("}", .bytes(Array("}".utf8))),
            TerminalExtendedKey("<", .bytes(Array("<".utf8))), TerminalExtendedKey(">", .bytes(Array(">".utf8))),
            TerminalExtendedKey("&", .bytes(Array("&".utf8))), TerminalExtendedKey("Ins", .bytes(EscapeSequences.cmdInsert), isNavigation: true),
            TerminalExtendedKey("Home", .home, isNavigation: true), TerminalExtendedKey("PgUp", .bytes(EscapeSequences.cmdPageUp), isNavigation: true),
        ],
        [
            TerminalExtendedKey("+", .bytes(Array("+".utf8))), TerminalExtendedKey("−", .bytes(Array("-".utf8))),
            TerminalExtendedKey("*", .bytes(Array("*".utf8))), TerminalExtendedKey("=", .bytes(Array("=".utf8))),
            TerminalExtendedKey("%", .bytes(Array("%".utf8))), TerminalExtendedKey("`", .bytes(Array("`".utf8))),
            TerminalExtendedKey("\\", .bytes(Array("\\".utf8))), TerminalExtendedKey("Del", .bytes(EscapeSequences.cmdDelKey), isNavigation: true),
            TerminalExtendedKey("End", .end, isNavigation: true), TerminalExtendedKey("PgDn", .bytes(EscapeSequences.cmdPageDown), isNavigation: true),
        ],
    ]
}

struct TerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var controller = TerminalController()
    @State private var keyboard = TerminalKeyboardController()
    @State private var confirmQuit = false

    var body: some View {
        NavigationStack {
            Group {
                if let error = controller.error, controller.terminal == nil {
                    ContentUnavailableView("Terminal unavailable", systemImage: "terminal", description: Text(error))
                } else if let terminal = controller.terminal {
                    NativeTerminal(
                        chunks: model.terminalChunks[terminal.id] ?? [],
                        keyboard: keyboard,
                        onSend: { controller.send($0, model: model) },
                        onResize: { controller.resize(columns: $0, rows: $1, model: model) }
                    )
                    .id(terminal.id)
                    .padding(.horizontal, 8)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if keyboard.isKeyboardPresented {
                            TerminalControlBar(keyboard: keyboard)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                } else {
                    TronLoadingState(label: "Connecting terminal…")
                }
            }
            .background(Color.tronBackground)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { terminalMenu }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        Circle().fill(controller.connectionPhase.color).frame(width: 7, height: 7)
                        Text("Terminal")
                            .font(TronTypography.button)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Terminal")
                    .accessibilityValue(controller.connectionPhase.label)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .task {
            if let id = model.selectedSessionID { try? await model.openSession(id) }
            await controller.start(model: model)
        }
        .onDisappear {
            if let id = controller.terminal?.id { Task { await model.detachTerminal(id) } }
        }
        .confirmationDialog("Quit this terminal?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Quit Terminal", role: .destructive) { controller.terminate(model: model) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The shell and its running process group will stop. Closing the sheet alone only detaches.")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
        .animation(.easeOut(duration: 0.16), value: keyboard.isKeyboardPresented)
    }

    private var terminalMenu: some View {
        Menu {
            if !controller.isRunning {
                Button("Open Live Terminal", systemImage: "terminal") {
                    Task { await controller.openLive(model: model) }
                }
            }
            if !controller.history.isEmpty {
                Section {
                    ForEach(controller.history) { terminal in
                        Button {
                            Task { await controller.show(terminal, model: model) }
                        } label: {
                            Text(terminal.exitedAt ?? terminal.createdAt)
                        }
                    }
                } header: {
                    Text("Recent terminals")
                }
            }
            Button("Quit Terminal", role: .destructive) { confirmQuit = true }
                .disabled(!controller.isRunning)
        } label: {
            Image(systemName: "ellipsis")
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronEmerald)
        }
        .accessibilityLabel("Terminal options")
    }
}

private struct NativeTerminal: UIViewRepresentable {
    let chunks: [TerminalChunk]
    let keyboard: TerminalKeyboardController
    let onSend: (ArraySlice<UInt8>) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(keyboard: keyboard, onSend: onSend, onResize: onResize)
    }

    func makeUIView(context: Context) -> TronNativeTerminalView {
        let terminal = TronNativeTerminalView(
            frame: .zero,
            font: TronFontLoader.createUIFont(size: 13, weight: .regular, mono: true)
        )
        terminal.terminalDelegate = context.coordinator
        terminal.backgroundColor = .clear
        terminal.layer.backgroundColor = UIColor.clear.cgColor
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = .label
        terminal.caretColor = .label
        terminal.inputAccessoryView = nil
        terminal.focusDidChange = { [weak keyboard] isPresented in
            keyboard?.isKeyboardPresented = isPresented
        }
        keyboard.attach(terminal)
        applySoftEdges(to: terminal)
        return terminal
    }

    func updateUIView(_ view: TronNativeTerminalView, context: Context) {
        context.coordinator.keyboard = keyboard
        context.coordinator.onSend = onSend
        context.coordinator.onResize = onResize
        keyboard.attach(view)
        for chunk in chunks where chunk.sequence > context.coordinator.lastSequence {
            view.feed(byteArray: Array(chunk.data.utf8)[...])
            context.coordinator.lastSequence = chunk.sequence
        }
    }

    static func dismantleUIView(_ view: TronNativeTerminalView, coordinator: Coordinator) {
        coordinator.keyboard.detach(view)
        view.focusDidChange = nil
        view.terminalDelegate = nil
    }

    private func applySoftEdges(to view: UIView) {
        if let scroll = view as? UIScrollView {
            scroll.topEdgeEffect.style = .soft
            scroll.leftEdgeEffect.style = .soft
            scroll.bottomEdgeEffect.style = .soft
            scroll.rightEdgeEffect.style = .soft
        }
        view.subviews.forEach(applySoftEdges)
    }

    final class Coordinator: NSObject, @MainActor TerminalViewDelegate {
        var keyboard: TerminalKeyboardController
        var onSend: (ArraySlice<UInt8>) -> Void
        var onResize: (Int, Int) -> Void
        var lastSequence = 0

        init(
            keyboard: TerminalKeyboardController,
            onSend: @escaping (ArraySlice<UInt8>) -> Void,
            onResize: @escaping (Int, Int) -> Void
        ) {
            self.keyboard = keyboard
            self.onSend = onSend
            self.onResize = onResize
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onSend(data)
            Task { @MainActor [weak keyboard] in
                await Task.yield()
                keyboard?.sync(from: source)
            }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { onResize(newCols, newRows) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        nonisolated func bell(source: TerminalView) {
            Task { @MainActor in
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
        func clipboardCopy(source: TerminalView, content: Data) { UIPasteboard.general.setData(content, forPasteboardType: "public.data") }
        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

private struct TerminalControlBar: View {
    let keyboard: TerminalKeyboardController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) { scrollingControls }
                .scrollClipDisabled(false)
                .frame(maxWidth: .infinity)
            Divider().frame(height: 22).accessibilityHidden(true)
            imageButton("keyboard.chevron.compact.down", label: "Dismiss keyboard", action: keyboard.dismissKeyboard)
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
        .padding(.top, 12)
        .padding(.bottom, 5)
    }

    private var scrollingControls: some View {
        HStack(spacing: 2) {
            textButton("esc", label: "Escape") { keyboard.send(EscapeSequences.cmdEsc) }
            textButton("ctrl", label: "Control modifier", selected: keyboard.isControlModifierEnabled, action: keyboard.toggleControlModifier)
            imageButton("arrow.right.to.line.compact", label: "Tab") { keyboard.send(EscapeSequences.cmdTab) }
            textButton("~", label: "Tilde") { keyboard.send("~") }
            textButton("|", label: "Pipe") { keyboard.send("|") }
            textButton("/", label: "Slash") { keyboard.send("/") }
            textButton("−", label: "Dash") { keyboard.send("-") }
            Divider().frame(height: 20).padding(.horizontal, 2)
            ForEach(TerminalCursorKey.allCases, id: \.self) { cursor in
                imageButton(cursor.symbolName, label: "Move \(cursor)") { keyboard.sendCursor(cursor) }
            }
            imageButton(
                keyboard.isTouchScrollingEnabled ? "hand.draw.fill" : "hand.draw",
                label: "Touch scrolling",
                selected: keyboard.isTouchScrollingEnabled,
                action: keyboard.toggleTouchScrolling
            )
            imageButton(
                "rectangle.grid.3x2",
                label: "Command keys",
                selected: keyboard.isExtendedKeyboardPresented,
                action: keyboard.toggleExtendedKeyboard
            )
        }
        .padding(.horizontal, 7)
        .frame(height: 42)
    }

    private func textButton(
        _ title: String,
        label: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                .frame(minWidth: 30, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.tronEmerald : Color.tronTextPrimary)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func imageButton(
        _ systemName: String,
        label: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .frame(minWidth: 30, minHeight: 36)
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.tronEmerald : Color.tronTextPrimary)
        .contentShape(Rectangle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private final class TronNativeTerminalView: TerminalView {
    var focusDidChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { focusDidChange?(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { focusDidChange?(false) }
        return result
    }
}

private final class TerminalExtendedKeyboardView: UIInputView, UIInputViewAudioFeedback {
    private weak var terminalView: TerminalView?
    var enableInputClicksWhenVisible: Bool { true }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 176) }

    init(terminalView: TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero, inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        buildRows()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
            keys.map(button).forEach(row.addArrangedSubview)
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
        configuration.contentInsets = .init(top: 5, leading: 1, bottom: 5, trailing: 1)
        let font = TronFontLoader.createUIFont(size: 11, weight: .semibold, mono: true)
        configuration.titleTextAttributesTransformer = .init { attributes in
            var updated = attributes
            updated.font = font
            return updated
        }
        let button = UIButton(configuration: configuration)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.65
        button.accessibilityLabel = key.title
        button.addAction(UIAction { [weak self] _ in
            guard let terminal = self?.terminalView else { return }
            UIDevice.current.playInputClick()
            terminal.send(key.bytes(applicationCursor: terminal.getTerminal().applicationCursor))
        }, for: .touchDown)
        return button
    }
}
