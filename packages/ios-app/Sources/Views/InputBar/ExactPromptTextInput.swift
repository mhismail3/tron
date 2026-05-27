import SwiftUI
import UIKit

/// UIKit-backed chat prompt input that preserves engine-facing text exactly.
///
/// SwiftUI `TextField` modifiers still allowed simulator keyboard replacement
/// in exact capability prompts. This component owns the lower-level
/// `UITextInputTraits` boundary for chat instructions so capability ids, JSON,
/// paths, and idempotency keys reach the server unchanged.
struct ExactPromptTextInput: UIViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let textColor: UIColor
    let onFocusChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = TronTypography.uiFont(mono: false, size: TronTypography.sizeBodyLG)
        view.textColor = textColor
        view.tintColor = UIColor(Color.tronEmerald)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.textContentType = nil
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.isEditable = isEditable
        uiView.textColor = textColor
        uiView.font = TronTypography.uiFont(mono: false, size: TronTypography.sizeBodyLG)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let fitting = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let lineHeight = uiView.font?.lineHeight ?? TronTypography.sizeBodyLG
        let maxHeight = lineHeight * 8
        let height = min(max(fitting.height, lineHeight), maxHeight)
        uiView.isScrollEnabled = fitting.height > maxHeight
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onFocusChanged: onFocusChanged)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        private let onFocusChanged: (Bool) -> Void

        init(text: Binding<String>, onFocusChanged: @escaping (Bool) -> Void) {
            self.text = text
            self.onFocusChanged = onFocusChanged
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            onFocusChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onFocusChanged(false)
        }
    }
}
