import SwiftUI

/// Full-text preview used for long prompts from the history list.
@available(iOS 26.0, *)
struct PromptPreviewSheet: View {
    let text: String
    let onUse: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Prompt", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { onUse() } label: {
                        Label("Use", systemImage: "arrow.up.message.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronEmerald)
    }
}

extension PromptHistoryItem {
    // Identifiable conformance provided by the `id` property; this extension is
    // intentionally empty — kept here only to make the file future-proof.
}
