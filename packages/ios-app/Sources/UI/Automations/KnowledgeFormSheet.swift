import SwiftUI

/// Knowledge and connection forms share the existing settings geometry and toolbar controls.
/// This is presentation only: each form retains its own draft and command owner.
struct KnowledgeFormSheet<Content: View>: View {
    let title: String
    var accent: Color = .tronKnowledge
    var actionTitle = "Save"
    var isWorking = false
    var actionDisabled = false
    var onAction: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content() }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .tronScrollEdgeChrome()
            .tronNavigationTitle(title, accent: accent)
            .toolbar {
                if onAction != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(TronTypography.buttonSM)
                                .foregroundStyle(accent)
                        }
                        .accessibilityLabel("Cancel")
                        .disabled(isWorking)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { if let onAction { onAction() } else { dismiss() } } label: {
                        TronToolbarTextLabel(onAction == nil ? "Done" : actionTitle,
                                             systemImage: "checkmark", isWorking: isWorking)
                    }
                    .tronToolbarAction(accent: actionDisabled || isWorking ? .tronTextMuted : accent)
                    .disabled(actionDisabled || isWorking)
                }
            }
        }
        .foregroundStyle(Color.tronTextPrimary)
        .tronSettingsLayout()
        .tronSettingsVisualTheme(accent: accent)
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}
