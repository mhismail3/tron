import SwiftUI
import UIKit

struct SessionContextRawJSONSelection: Identifiable, Sendable {
    let id: String
    let title: String
    let loadingMessage: String
    let accessibilityLabel: String
    let value: AnyCodable

    static func providerAudit(_ value: AnyCodable) -> Self {
        Self(
            id: "provider-audit",
            title: "Redacted JSON",
            loadingMessage: "Formatting redacted request…",
            accessibilityLabel: "Redacted provider request JSON",
            value: value
        )
    }

    static func toolSurface(_ value: AnyCodable) -> Self {
        Self(
            id: "tool-surface",
            title: "Surface JSON",
            loadingMessage: "Formatting exact tool surface…",
            accessibilityLabel: "Exact tool surface JSON",
            value: value
        )
    }
}

struct SessionContextRawJSONSheet: View {
    let selection: SessionContextRawJSONSelection

    @State private var formattedJSON: String?

    var body: some View {
        NavigationStack {
            Group {
                if let formattedJSON {
                    SessionContextReadOnlyJSONText(
                        text: formattedJSON,
                        accessibilityLabel: selection.accessibilityLabel
                    )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.tronTextMuted.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.tronTextMuted.opacity(0.2), lineWidth: 1)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                } else {
                    SheetLoadingState(label: selection.loadingMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: selection.title, color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
        }
        .adaptivePresentationDetents([.large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .task {
            let value = selection.value
            let text = await Task.detached(priority: .userInitiated) {
                SessionContextAuditFormatter.projectedJSONString(value)
            }.value
            guard !Task.isCancelled else { return }
            formattedJSON = text
        }
    }
}

private struct SessionContextReadOnlyJSONText: UIViewRepresentable {
    let text: String
    let accessibilityLabel: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.textColor = .secondaryLabel
        textView.font = .monospacedSystemFont(
            ofSize: CGFloat(TronTypography.sizeCaption),
            weight: .regular
        )
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)
        textView.textContainer.lineFragmentPadding = 0
        textView.accessibilityLabel = accessibilityLabel
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        guard textView.text != text else { return }
        textView.text = text
    }
}
