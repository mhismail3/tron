import SwiftUI

// MARK: - Streaming Content View

/// Optimized for efficient rendering during rapid text updates
struct StreamingContentView: View {
    let text: String
    @Environment(\.textSelectionDisabled) private var textSelectionDisabled

    var body: some View {
        Group {
            if text.isEmpty {
                Text(" ")
                    .font(TronTypography.messageBody)
            } else {
                // Use plain Text, NOT LocalizedStringKey - avoids parsing overhead
                Text(text)
                    .font(TronTypography.messageBody)
                    .foregroundStyle(.assistantMessageText)
                    .lineSpacing(4)
                    .selectableText(!textSelectionDisabled)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
