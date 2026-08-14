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
            .frame(width: 15, height: 15)
            .frame(width: 40, height: 40)
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

enum TaperedActivityWaveProfile {
    static func envelope(at progress: CGFloat) -> CGFloat {
        let bounded = min(max(progress, 0), 1)
        let remaining = 1 - bounded
        return remaining * remaining
    }

    static func amplitude(at progress: CGFloat, phase: Double) -> CGFloat {
        let bounded = min(max(progress, 0), 1)
        let pulse = 0.30 + 0.70 * ((sin(Double(bounded) * .pi * 7 - phase) + 1) / 2)
        return envelope(at: bounded) * CGFloat(pulse)
    }
}

private struct TaperedActivityWave: Shape {
    let phase: Double

    func path(in rect: CGRect) -> Path {
        let sampleCount = 56
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        upper.reserveCapacity(sampleCount + 1)
        lower.reserveCapacity(sampleCount + 1)

        for sample in 0...sampleCount {
            let progress = CGFloat(sample) / CGFloat(sampleCount)
            let envelope = TaperedActivityWaveProfile.envelope(at: progress)
            let amplitude = TaperedActivityWaveProfile.amplitude(at: progress, phase: phase)
            let drift = sin(Double(progress) * .pi * 2 + phase * 0.35)
            let center = rect.midY + rect.height * 0.06 * envelope * CGFloat(drift)
            let halfHeight = rect.height * (0.10 * envelope + 0.38 * amplitude)
            let x = rect.minX + rect.width * progress
            upper.append(CGPoint(x: x, y: center - halfHeight))
            lower.append(CGPoint(x: x, y: center + halfHeight))
        }

        var path = Path()
        guard let first = upper.first else { return path }
        path.move(to: first)
        for point in upper.dropFirst() { path.addLine(to: point) }
        for point in lower.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

struct ComposerActivityWave: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 2.4
            TaperedActivityWave(phase: phase)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.tronEmerald.opacity(0.82),
                            Color.tronEmerald.opacity(0.42),
                            Color.tronEmerald.opacity(0.04)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .frame(width: 104, height: 17)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
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
        hasContent: Bool
    ) -> ComposerTrailingMode? {
        if hasContent { return .send }
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
        guard !outgoing.isEmpty else { return currentDraft }
        guard !currentDraft.isEmpty else { return outgoing }
        return "\(outgoing)\n\(currentDraft)"
    }
}

struct ComposerTrailingButton: View {
    let mode: ComposerTrailingMode
    let isDisabled: Bool
    let onSend: () -> Void
    let onAbort: () -> Void

    var body: some View {
        Button(action: performAction) {
            Group {
                switch mode {
                case .stopAgent:
                    Image(systemName: "stop.fill")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronError)
                case .send:
                    Image(systemName: "arrow.up.circle.fill")
                        .font(TronTypography.button)
                        .foregroundStyle(isDisabled ? Color.tronEmerald.opacity(0.3) : Color.tronEmerald)
                }
            }
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && mode == .send)
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeInOut(duration: 0.2), value: mode)
        .animation(.easeInOut(duration: 0.2), value: isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch mode {
        case .stopAgent: "Stop Tron"
        case .send: "Send message"
        }
    }

    private func performAction() {
        switch mode {
        case .stopAgent: onAbort()
        case .send: onSend()
        }
    }
}
