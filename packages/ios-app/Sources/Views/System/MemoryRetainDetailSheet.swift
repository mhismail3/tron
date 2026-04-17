import SwiftUI

/// Detail sheet shown when tapping the memory retained notification pill.
/// Displays the full summary produced by the LLM summarizer.
@available(iOS 26.0, *)
struct MemoryRetainDetailSheet: View {
    let title: String
    let summary: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    summarySection
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Memory Retained", color: .tronPink)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.tronPink)
    }

    // MARK: - Summary Section

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Summary")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                if let summary {
                    Button {
                        UIPasteboard.general.string = summary
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronPink.opacity(0.6))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "brain")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronPink)

                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronPink)

                    Spacer()
                }

                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No summary available")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextDisabled)
                        .italic()
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPink.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
