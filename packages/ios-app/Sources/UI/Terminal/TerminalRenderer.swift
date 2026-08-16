import SwiftTerm
import SwiftUI
import UIKit

@MainActor
@Observable
final class TerminalKeyboardController {
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

enum TerminalCursorKey: CaseIterable {
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

struct TerminalExtendedKey: Equatable {
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

struct NativeTerminal: UIViewRepresentable {
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

struct TerminalControlBar: View {
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

final class TronNativeTerminalView: TerminalView {
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

final class TerminalExtendedKeyboardView: UIInputView, UIInputViewAudioFeedback {
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
