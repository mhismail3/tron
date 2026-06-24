import SwiftUI

struct LocalErrorDetailSheet: View {
    let data: LocalErrorDetailData

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(data.title, systemImage: "exclamationmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .bold))
                        .foregroundStyle(.tronError)

                    Text(data.message)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let suggestion = data.suggestion?.nilIfEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Suggestion")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                            .foregroundStyle(.tronTextMuted)
                            .textCase(.uppercase)

                        Text(suggestion)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronBackground)
            .navigationTitle("Error Details")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
