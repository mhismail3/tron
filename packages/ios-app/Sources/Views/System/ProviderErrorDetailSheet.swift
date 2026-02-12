import SwiftUI

/// Detail sheet shown when tapping the provider error notification pill.
/// Displays error info in glass cards matching the CompactionDetailSheet pattern.
@available(iOS 26.0, *)
struct ProviderErrorDetailSheet: View {
    let data: ProviderErrorDetailData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    infoBadges
                        .padding(.horizontal)

                    messageSection
                        .padding(.horizontal)
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

    // MARK: - Info Badges

    private var infoBadges: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            VStack(spacing: 12) {
                // Row 1: Provider, Model
                HStack(spacing: 12) {
                    ErrorBadge(label: "Provider", value: data.provider.capitalized, color: .red)
                    if let model = data.model {
                        ErrorBadge(label: "Model", value: model, color: .red)
                    }
                }

                // Row 2: Status code, Error type, Retryable
                HStack(spacing: 12) {
                    if let statusCode = data.statusCode {
                        ErrorBadge(label: "Status", value: "\(statusCode)", color: .red)
                    }
                    if let errorType = data.errorType, errorType != "Error" {
                        ErrorBadge(label: "Type", value: errorType, color: .red)
                    }
                    if data.retryable {
                        ErrorBadge(label: "Retryable", value: "", color: .orange)
                    }
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.red.opacity(0.12)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: - Message Section

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Error Message")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                Button {
                    UIPasteboard.general.string = data.message
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.red.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: ErrorCategoryDisplay.icon(for: data.category))
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.red)

                    Text("Details")
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
}

// MARK: - Helper Views

@available(iOS 26.0, *)
private struct ErrorBadge: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
            if !value.isEmpty {
                Text(value)
                    .font(TronTypography.pillValue)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.tint(color.opacity(0.2)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
