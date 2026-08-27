import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ChatComposerResponder {
    @ObservationIgnored private weak var textView: UITextView?

    var window: UIWindow? { textView?.window }

    func attach(_ textView: UITextView) {
        self.textView = textView
    }

    func detach(_ textView: UITextView) {
        guard self.textView === textView else { return }
        self.textView = nil
    }

    @discardableResult
    func resignFirstResponder() -> Bool {
        textView?.resignFirstResponder() ?? false
    }
}

/// UIKit owns selection and the capped editor's internal scroll position. A
/// vertical SwiftUI TextField can repeatedly relayout at its line cap and lose
/// the insertion point while typing; this control keeps one stable scroll owner.
struct MultilineComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var selection: Binding<NSRange>? = nil
    var responder: ChatComposerResponder? = nil
    let isEditable: Bool
    let keyboardAppearance: UIKeyboardAppearance
    var maximumLines = 8

    final class LayoutAwareTextView: UITextView {
        var didLayout: ((LayoutAwareTextView) -> Void)?
        private var isReportingLayout = false

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !isReportingLayout else { return }
            isReportingLayout = true
            didLayout?(self)
            isReportingLayout = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> LayoutAwareTextView {
        let view = LayoutAwareTextView()
        view.delegate = context.coordinator
        view.didLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.textViewDidLayout(view)
        }
        view.backgroundColor = .clear
        view.textColor = UIColor(Color.tronEmerald)
        view.tintColor = UIColor(Color.tronEmerald)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.contentInsetAdjustmentBehavior = .never
        view.isScrollEnabled = false
        view.alwaysBounceVertical = false
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = true
        view.keyboardAppearance = keyboardAppearance
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "Message input"
        context.coordinator.updateFont(on: view)
        context.coordinator.requestCaretReveal(on: view)
        responder?.attach(view)
        return view
    }

    func updateUIView(_ view: LayoutAwareTextView, context: Context) {
        context.coordinator.parent.responder?.detach(view)
        context.coordinator.parent = self
        responder?.attach(view)
        let fontChanged = context.coordinator.updateFont(on: view)
        view.isEditable = isEditable
        view.isSelectable = isEditable
        if view.keyboardAppearance != keyboardAppearance {
            view.keyboardAppearance = keyboardAppearance
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if view.text != text {
            view.text = text
            view.selectedRange = context.coordinator.clampedSelection(
                selection?.wrappedValue ?? NSRange(location: (text as NSString).length, length: 0),
                text: text
            )
            context.coordinator.requestCaretReveal(on: view)
        } else if fontChanged {
            context.coordinator.requestCaretReveal(on: view)
        }
        context.coordinator.reconcileFocus(on: view)
    }

    static func dismantleUIView(_ view: LayoutAwareTextView, coordinator: Coordinator) {
        view.resignFirstResponder()
        coordinator.parent.responder?.detach(view)
        view.didLayout = nil
        view.delegate = nil
    }

    /// SwiftUI may call representable measurement speculatively. Keep this
    /// callback pure: live scroll mode and caret ownership reconcile only after
    /// UIKit has installed the returned bounds and completed TextKit layout.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: LayoutAwareTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, Self.isAdmittedWidth(width) else { return nil }
        return CGSize(
            width: width,
            height: context.coordinator.resolvedHeight(of: uiView, width: width)
        )
    }

    static func isAdmittedWidth(_ width: CGFloat) -> Bool {
        width.isFinite && width > 0
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MultilineComposerTextView
        private(set) var usesInternalScrolling = false
        private var lastLayoutSize = CGSize.zero
        private var needsCaretReveal = false
        private var focusReconciliationScheduled = false
        private var isReconcilingLayout = false
        private(set) var hasMirroredFocus = false

        init(_ parent: MultilineComposerTextView) { self.parent = parent }

        func reconcileFocus(on view: UITextView) {
            // A direct tap makes UITextView first responder before SwiftUI mirrors
            // the delegate callback. Never resign from that one stale render.
            // Programmatic dismissal is explicit only after UIKit has reported
            // focus for this responder lifetime.
            if parent.isFocused, !view.isFirstResponder, parent.isEditable {
                guard !focusReconciliationScheduled else { return }
                focusReconciliationScheduled = true
                DispatchQueue.main.async { [weak view, weak self] in
                    guard let self else { return }
                    self.focusReconciliationScheduled = false
                    guard let view,
                          self.parent.isFocused,
                          self.parent.isEditable,
                          view.window != nil,
                          !view.isFirstResponder else { return }
                    _ = view.becomeFirstResponder()
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
            publishSelection(from: textView)
            requestCaretReveal(on: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            hasMirroredFocus = false
            if parent.isFocused { parent.isFocused = false }
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text { parent.text = textView.text }
            publishSelection(from: textView)
            requestCaretReveal(on: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.isFirstResponder else { return }
            publishSelection(from: textView)
            requestCaretReveal(on: textView)
        }

        func clampedSelection(_ selection: NSRange, text: String) -> NSRange {
            let length = (text as NSString).length
            let location = min(max(selection.location, 0), length)
            let selectedLength = min(max(selection.length, 0), length - location)
            return NSRange(location: location, length: selectedLength)
        }

        private func publishSelection(from textView: UITextView) {
            guard let selection = parent.selection else { return }
            let current = clampedSelection(textView.selectedRange, text: textView.text)
            if selection.wrappedValue != current { selection.wrappedValue = current }
        }

        @discardableResult
        func updateFont(on view: UITextView) -> Bool {
            let base = TronFontLoader.createUIFont(
                size: TronTypography.sizeBodyLG,
                weight: .regular
            )
            let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
            guard view.font != font else { return false }
            view.font = font
            return true
        }

        func resolvedHeight(of view: UITextView, width: CGFloat) -> CGFloat {
            guard MultilineComposerTextView.isAdmittedWidth(width), let font = view.font else { return 0 }
            let fitting = view.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            let minimum = ceil(font.lineHeight)
            let maximum = ceil(font.lineHeight * CGFloat(max(parent.maximumLines, 1)))
            return min(max(fitting, minimum), maximum)
        }

        func requestCaretReveal(on view: UITextView) {
            needsCaretReveal = true
            view.setNeedsLayout()
        }

        /// Runs only from `layoutSubviews`, after SwiftUI has installed the
        /// representable's capped frame. Scroll ownership and caret visibility
        /// are therefore reduced from one final bounds/content geometry pair.
        func textViewDidLayout(_ view: UITextView) {
            guard !isReconcilingLayout,
                  view.bounds.width > 0,
                  view.bounds.height > 0,
                  let font = view.font else { return }
            let expectedHeight = resolvedHeight(of: view, width: view.bounds.width)
            guard abs(view.bounds.height - expectedHeight) <= 0.75 else { return }

            isReconcilingLayout = true
            defer { isReconcilingLayout = false }
            let fitting = view.sizeThatFits(CGSize(
                width: view.bounds.width,
                height: .greatestFiniteMagnitude
            )).height
            let maximum = ceil(font.lineHeight * CGFloat(max(parent.maximumLines, 1)))
            let shouldScroll = Self.shouldUseInternalScrolling(
                fittingHeight: fitting,
                maximumHeight: maximum,
                currentlyScrolling: usesInternalScrolling
            )
            let sizeChanged = abs(lastLayoutSize.width - view.bounds.width) > 0.5
                || abs(lastLayoutSize.height - view.bounds.height) > 0.5
            lastLayoutSize = view.bounds.size

            if shouldScroll != usesInternalScrolling {
                usesInternalScrolling = shouldScroll
                view.isScrollEnabled = shouldScroll
                view.setNeedsLayout()
                view.layoutIfNeeded()
                if shouldScroll {
                    needsCaretReveal = true
                } else {
                    needsCaretReveal = false
                    setOffsetY(0, on: view)
                }
            }
            if sizeChanged && usesInternalScrolling { needsCaretReveal = true }
            guard usesInternalScrolling, view.isScrollEnabled, needsCaretReveal else { return }
            needsCaretReveal = false
            revealCaret(in: view, measuredContentHeight: fitting)
        }

        static func shouldUseInternalScrolling(
            fittingHeight: CGFloat,
            maximumHeight: CGFloat,
            currentlyScrolling: Bool
        ) -> Bool {
            guard fittingHeight.isFinite, maximumHeight.isFinite, maximumHeight > 0 else {
                return currentlyScrolling
            }
            return currentlyScrolling
                ? fittingHeight >= maximumHeight - 0.5
                : fittingHeight > maximumHeight + 0.5
        }

        private func revealCaret(in view: UITextView, measuredContentHeight: CGFloat) {
            guard let selection = view.selectedTextRange else { return }
            var caret = view.caretRect(for: selection.end)
            guard caret.minY.isFinite, caret.maxY.isFinite else { return }
            let margin = min(4, max(1, (view.font?.lineHeight ?? 4) * 0.18))
            caret = caret.insetBy(dx: 0, dy: -margin)

            let minimumY = -view.contentInset.top
            let contentHeight = max(view.contentSize.height, measuredContentHeight)
            let maximumY = max(
                minimumY,
                contentHeight - view.bounds.height + view.contentInset.bottom
            )
            let visibleMinimumY = view.contentOffset.y + view.contentInset.top
            let visibleMaximumY = view.contentOffset.y + view.bounds.height
                - view.contentInset.bottom
            var targetY = view.contentOffset.y
            if caret.maxY > visibleMaximumY {
                targetY += caret.maxY - visibleMaximumY
            } else if caret.minY < visibleMinimumY {
                targetY -= visibleMinimumY - caret.minY
            }
            setOffsetY(min(max(targetY, minimumY), maximumY), on: view)
        }

        private func setOffsetY(_ y: CGFloat, on view: UITextView) {
            guard abs(view.contentOffset.y - y) > 0.5 else { return }
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }

        #if HOSTED_TEST
        func hostedCaretIsVisible(in view: UITextView) -> Bool {
            guard let selection = view.selectedTextRange else { return false }
            let caret = view.caretRect(for: selection.end)
            // TextKit can report the terminal caret fractionally beyond its
            // rounded contentSize edge; one physical-point tolerance matches
            // UIScrollView's own maximum-offset clamp.
            let minimum = view.contentOffset.y + view.contentInset.top - 1
            let maximum = view.contentOffset.y + view.bounds.height
                - view.contentInset.bottom + 1
            return caret.minY >= minimum && caret.maxY <= maximum
        }
        #endif
    }
}

enum ComposerControlMetrics {
    static let hitTarget: CGFloat = 40
    static let symbolSize: CGFloat = 16
    static let contextRingDiameter: CGFloat = 16
}

struct SessionContextProgressPresentation: Equatable {
    let contextPercentage: Int
    let modelName: String?
    let isCompacting: Bool
    let isEnabled: Bool
}

enum SessionContextProgressPolicy {
    static func presentation(
        isTranscriptReady: Bool,
        contextPercentage: Int?,
        modelName: String?,
        isCompacting: Bool
    ) -> SessionContextProgressPresentation {
        guard isTranscriptReady, let contextPercentage else {
            return SessionContextProgressPresentation(
                contextPercentage: 0,
                modelName: nil,
                isCompacting: false,
                isEnabled: false
            )
        }
        return SessionContextProgressPresentation(
            contextPercentage: contextPercentage,
            modelName: modelName,
            isCompacting: isCompacting,
            isEnabled: true
        )
    }
}

/// Historical session-owned context indicator. It remains mounted at zero
/// while the authoritative chat opens, then animates to the canonical value.
/// Tapping it opens Manage Session; it owns no runtime state or mutation path.
struct SessionContextProgressButton: View {
    let presentation: SessionContextProgressPresentation
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var contextPercentage: Int { presentation.contextPercentage }
    private var modelName: String? { presentation.modelName }
    private var isCompacting: Bool { presentation.isCompacting }

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
        .disabled(!presentation.isEnabled)
        .opacity(presentation.isEnabled ? 1 : 0.56)
        .accessibilityIdentifier("session-context-button")
        .accessibilityLabel("Manage Session")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Shows context usage, model selection, and session actions")
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
            value: fraction
        )
    }

    private var accessibilityValue: String {
        guard presentation.isEnabled else { return "Session context loading" }
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
        false
    }

    static func abortKind(operation: SessionOperationState?) -> String {
        switch operation?.kind {
        case .compaction: "compaction"
        case .branchSummary: "branchSummary"
        case .bash: "bash"
        case .retry: "retry"
        case .prompt, .command, .none: "agent"
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            .scaleEffect(isSending && !reduceMotion ? 0.72 : 1)
                        if isSending {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.tronEmerald)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .scale(scale: 0.72).combined(with: .opacity)
                                )
                        }
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSending)
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
        .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDisabled)
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
