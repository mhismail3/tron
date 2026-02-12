import SwiftUI

/// Detail sheet shown when tapping the provider error notification pill.
/// Displays error category, provider, message, suggestion, and retryable status.
@available(iOS 26.0, *)
struct ProviderErrorDetailSheet: View {
    let data: ProviderErrorDetailData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    errorHeader
                        .padding(.horizontal)

                    detailsSection
                        .padding(.horizontal)

                    if let suggestion = data.suggestion {
                        suggestionSection(suggestion)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(ErrorCategoryDisplay.label(for: data.category))
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .tint(.red)
    }

    // MARK: - Error Header

    private var errorHeader: some View {
        VStack(spacing: 12) {
            Image(systemName: ErrorCategoryDisplay.icon(for: data.category))
                .font(.system(size: 36))
                .foregroundStyle(.red)

            HStack(spacing: 8) {
                Text(data.provider.capitalized)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                if data.retryable {
                    Text("Retryable")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.orange.opacity(0.15))
                        }
                }
            }
        }
    }

    // MARK: - Details Section

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Error Details")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.red)

                    Text("Message")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.red)

                    Spacer()
                }

                Text(data.message)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.red.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Suggestion Section

    private func suggestionSection(_ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestion")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.yellow)

                    Text("How to Fix")
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.yellow)

                    Spacer()
                }

                Text(suggestion)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.yellow.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
