import SwiftUI

struct LocalErrorDetailSheet: View {
    let data: LocalErrorDetailData

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What happened")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronError)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(data.message)
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronTextPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)

                        if let suggestion = data.suggestion?.nilIfEmpty {
                            Divider()
                                .overlay(Color.tronError.opacity(0.18))

                            Label(suggestion, systemImage: "arrow.clockwise")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronTextSecondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .sectionFill(.tronError, cornerRadius: 12, subtle: true, interactive: false)
                }
                .padding(.horizontal)
                .padding(.vertical)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronError)
                        SheetTitle(title: data.title, color: .tronError)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronError)
                }
            }
        }
        .adaptivePresentationDetents([.medium], ipadSizing: .compactForm)
        .tint(.tronError)
    }
}
