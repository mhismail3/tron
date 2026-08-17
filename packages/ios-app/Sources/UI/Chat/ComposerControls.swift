import SwiftUI
import UIKit

/// UIKit owns selection and the capped editor's internal scroll position. A
/// vertical SwiftUI TextField can repeatedly relayout at its line cap and lose
/// the insertion point while typing; this control keeps one stable scroll owner.
struct MultilineComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var height: CGFloat
    let isEditable: Bool
    let keyboardAppearance: UIKeyboardAppearance
    var maximumLines = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = UIColor(Color.tronEmerald)
        view.tintColor = UIColor(Color.tronEmerald)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.alwaysBounceVertical = false
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = true
        view.keyboardAppearance = keyboardAppearance
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "Message input"
        context.coordinator.updateFont(on: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateFont(on: view)
        view.isEditable = isEditable
        view.isSelectable = isEditable
        if view.keyboardAppearance != keyboardAppearance {
            view.keyboardAppearance = keyboardAppearance
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        context.coordinator.updateLayout(of: view, keepCaretVisible: true)

        context.coordinator.reconcileFocus(on: view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MultilineComposerTextView
        private var usesInternalScrolling = false
        private var lastWidth: CGFloat = 0
        private var layoutRevision: UInt = 0
        private(set) var hasMirroredFocus = false

        init(_ parent: MultilineComposerTextView) { self.parent = parent }

        func reconcileFocus(on view: UITextView) {
            // A direct tap makes UITextView first responder before SwiftUI mirrors
            // the delegate callback. Never resign from that one stale render.
            // Programmatic dismissal is explicit only after UIKit has reported
            // focus for this responder lifetime.
            if parent.isFocused, !view.isFirstResponder, parent.isEditable {
                DispatchQueue.main.async { [weak view, weak self] in
                    guard let view, let self,
                          self.parent.isFocused,
                          self.parent.isEditable,
                          view.window != nil,
                          !view.isFirstResponder else { return }
                    view.becomeFirstResponder()
                }
            } else if Self.shouldResign(
                desiredFocus: parent.isFocused,
                isFirstResponder: view.isFirstResponder,
                hasMirroredFocus: hasMirroredFocus
            ) {
                view.resignFirstResponder()
            }
        }

        static func shouldResign(
            desiredFocus: Bool,
            isFirstResponder: Bool,
            hasMirroredFocus: Bool
        ) -> Bool {
            !desiredFocus && isFirstResponder && hasMirroredFocus
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            hasMirroredFocus = true
            if !parent.isFocused { parent.isFocused = true }
            updateLayout(of: textView, keepCaretVisible: true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            hasMirroredFocus = false
            if parent.isFocused { parent.isFocused = false }
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
            updateLayout(of: textView, keepCaretVisible: true)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.isFirstResponder else { return }
            keepCaretVisible(in: textView)
        }

        func updateFont(on view: UITextView) {
            let base = TronFontLoader.createUIFont(size: TronTypography.sizeBodyLG, weight: .regular)
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
            if view.font != font { view.font = font }
        }

        func updateLayout(of view: UITextView, keepCaretVisible: Bool) {
            guard view.bounds.width > 0, let font = view.font else { return }
            let fitting = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
            let minimum = ceil(font.lineHeight)
            let maximum = ceil(font.lineHeight * CGFloat(max(parent.maximumLines, 1)))

            // Hysteresis prevents the backing scroll view toggling on and off as
            // the final wrapped line fluctuates by a fraction during typing.
            if usesInternalScrolling {
                usesInternalScrolling = fitting > maximum - font.lineHeight
            } else {
                usesInternalScrolling = fitting > maximum + 0.5
            }
            if view.isScrollEnabled != usesInternalScrolling {
                view.isScrollEnabled = usesInternalScrolling
            }

            let resolvedHeight = min(max(fitting, minimum), maximum)
            layoutRevision &+= 1
            let revision = layoutRevision
            if abs(parent.height - resolvedHeight) > 0.5 {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.layoutRevision == revision,
                          abs(self.parent.height - resolvedHeight) > 0.5 else { return }
                    self.parent.height = resolvedHeight
                }
            }
            if lastWidth != view.bounds.width {
                lastWidth = view.bounds.width
                view.layoutIfNeeded()
            }
            if keepCaretVisible { self.keepCaretVisible(in: view) }
        }

        private func keepCaretVisible(in view: UITextView) {
            guard usesInternalScrolling else {
                if view.contentOffset != .zero { view.setContentOffset(.zero, animated: false) }
                return
            }
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                view.scrollRangeToVisible(view.selectedRange)
                let minimumY = -view.adjustedContentInset.top
                let maximumY = max(minimumY, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
                let boundedY = min(max(view.contentOffset.y, minimumY), maximumY)
                if abs(view.contentOffset.y - boundedY) > 0.5 {
                    view.setContentOffset(CGPoint(x: 0, y: boundedY), animated: false)
                }
            }
        }
    }
}

enum ComposerControlMetrics {
    static let hitTarget: CGFloat = 40
    static let symbolSize: CGFloat = 16
    static let contextRingDiameter: CGFloat = 16
}

/// Historical session-owned context indicator. Its value is projected from the
/// canonical snapshot and tapping it opens Manage Session; it owns no runtime
/// state or mutation path.
struct SessionContextProgressButton: View {
    let contextPercentage: Int
    let modelName: String?
    let isCompacting: Bool
    let onTap: () -> Void

    private var boundedPercentage: Int { min(max(contextPercentage, 0), 100) }
    private var fraction: Double { Double(boundedPercentage) / 100 }
    private var accent: Color {
        switch boundedPercentage {
        case 95...: .tronError
        case 80...: .tronAmber
        default: .tronEmerald
        }
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .stroke(Color.tronTextMuted.opacity(0.34), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if isCompacting {
                    Circle().fill(accent).frame(width: 4, height: 4)
                }
            }
            .frame(
                width: ComposerControlMetrics.contextRingDiameter,
                height: ComposerControlMetrics.contextRingDiameter
            )
            .frame(
                width: ComposerControlMetrics.hitTarget,
                height: ComposerControlMetrics.hitTarget
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-context-button")
        .accessibilityLabel("Manage Session")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows context usage, model selection, and session actions")
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: fraction)
    }

    private var accessibilityValue: String {
        var values = modelName.map { [$0] } ?? []
        values.append("\(boundedPercentage)% context used")
        if isCompacting { values.append("compacting") }
        return values.joined(separator: ", ")
    }
}

enum ComposerTrailingMode: Equatable {
    case stopAgent
    case send
}

enum ChatComposerPolicy {
    static func isTextEditable(isTranscriptReady: Bool) -> Bool {
        // Drafting is local and remains available while authoritative opening
        // finishes; send and attachment mutations retain their own readiness gates.
        true
    }

    static func trailingMode(
        phase: SessionPhase?,
        hasContent: Bool,
        isSending: Bool = false
    ) -> ComposerTrailingMode? {
        if isSending || hasContent { return .send }
        if phase?.isActive == true { return .stopAgent }
        return nil
    }

    static func submissionBehavior(phase: SessionPhase?) -> String? {
        phase?.isActive == true ? "steer" : nil
    }

    static func preservesFocus(submissionBehavior: String?) -> Bool {
        submissionBehavior != nil
    }

    static func restoredDraft(outgoing: String, currentDraft: String) -> String {
        ComposerDraftTextPolicy.restoredDraft(
            outgoing: outgoing,
            currentDraft: currentDraft
        )
    }
}

struct ComposerTrailingButtonPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.22, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

struct ComposerTrailingButton: View {
    let mode: ComposerTrailingMode
    let isDisabled: Bool
    let isSending: Bool
    let offersQueueChoices: Bool
    let onSend: (String?) -> Void
    let onAbort: () -> Void

    var body: some View {
        Button(action: performAction) {
            Group {
                switch mode {
                case .stopAgent:
                    Image(systemName: "stop.fill")
                        .font(TronTypography.sans(
                            size: ComposerControlMetrics.symbolSize,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color.tronError)
                case .send:
                    ZStack {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(TronTypography.sans(
                                size: ComposerControlMetrics.symbolSize,
                                weight: .semibold
                            ))
                            .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                            .opacity(isSending ? 0 : 1)
                            .scaleEffect(isSending ? 0.72 : 1)
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.tronEmerald)
                                .transition(.scale(scale: 0.72).combined(with: .opacity))
                        }
                    }
                    .animation(.smooth(duration: 0.18), value: isSending)
                }
            }
            .frame(
                width: ComposerControlMetrics.hitTarget,
                height: ComposerControlMetrics.hitTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(ComposerTrailingButtonPressStyle())
        .disabled(isDisabled && mode == .send)
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeInOut(duration: 0.2), value: mode)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .contextMenu {
            if mode == .send, offersQueueChoices, !isSending {
                Button("Steer after current turn", systemImage: "arrow.turn.up.right") {
                    onSend("steer")
                }
                Button("Follow up after current work", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    onSend("followUp")
                }
            }
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .stopAgent: "Stop Tron"
        case .send: isSending ? "Sending message" : "Send message"
        }
    }

    private var accessibilityHint: String {
        if isSending { return "Waiting for the message to be admitted." }
        if mode == .send, offersQueueChoices {
            return "Sends steering after the current turn. Touch and hold to choose follow-up delivery."
        }
        return ""
    }

    private func performAction() {
        switch mode {
        case .stopAgent: onAbort()
        case .send: onSend(nil)
        }
    }
}
