import SwiftUI

/// Sheet showing full thinking content for a single block
/// Uses iOS 26 liquid glass styling to match AskUserQuestionSheet
@available(iOS 26.0, *)
struct ThinkingDetailSheet: View {
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(LocalizedStringKey(content))
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.tronTextPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Thinking")
                        .font(TronTypography.mono(size: TronTypography.sizeBodyLG, weight: .semibold))
                        .foregroundStyle(.tronPurple)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Fallback for iOS 17

struct ThinkingDetailSheetFallback: View {
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(LocalizedStringKey(content))
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.tronTextPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
            .background(Color.tronBackground)
            .navigationTitle("Thinking")
            .navigationBarTitleDisplayMode(.inline)
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
