import SwiftUI
import UIKit

/// A multi-line text input that wraps UITextView with proper vertical centering
/// and full text selection support (cursor positioning, selection handles).
@available(iOS 26.0, *)
struct MultiLineTextView: UIViewRepresentable {
    @Binding var text: String
    var font: UIFont
    var textColor: UIColor
    var isEditable: Bool
    var onTextChange: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = .clear
        textView.isEditable = isEditable
        textView.isScrollEnabled = false
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        // Remove all internal padding for proper centering
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.isSelectable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = font
        uiView.textColor = textColor
        uiView.isEditable = isEditable
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: MultiLineTextView

        init(_ parent: MultiLineTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onTextChange?()
        }
    }
}
