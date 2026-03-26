import SwiftUI

// MARK: - Fallback Views (for iOS < 26)

/// Fallback view for AskUserQuestion tool on older iOS
struct AskUserQuestionFallbackView: View {
    let questionCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronAmber)

            Text("\(questionCount) \(questionCount == 1 ? "question" : "questions") pending")
                .font(TronTypography.filePath)
                .foregroundStyle(.tronAmber.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tronAmber.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.tronAmber.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Fallback view for GetConfirmation tool on older iOS
struct GetConfirmationFallbackView: View {
    let action: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(TronTypography.codeSM)
                .foregroundStyle(.orange)

            Text("Confirm: \(action.prefix(40))")
                .font(TronTypography.filePath)
                .foregroundStyle(.orange.opacity(0.9))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
