import SwiftUI

// MARK: - Plan Mode Fallback Views (for iOS < 26)

/// Fallback view for plan mode entered notification on older iOS
struct PlanModeEnteredFallbackView: View {
    let skillName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(TronTypography.codeSM)
                .foregroundStyle(.tronAmber)

            Text("Plan Mode Active")
                .font(TronTypography.filePath)
                .foregroundStyle(.tronAmber.opacity(0.9))

            Text("(\(skillName))")
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronAmber.opacity(0.6))
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

/// Fallback view for plan mode exited notification on older iOS
struct PlanModeExitedFallbackView: View {
    let reason: String

    private var reasonIcon: String {
        switch reason {
        case "approved": return "checkmark.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        case "timeout": return "clock.badge.xmark.fill"
        default: return "arrow.right.circle.fill"
        }
    }

    private var reasonColor: Color {
        switch reason {
        case "approved": return .tronSuccess
        case "cancelled": return .tronError
        case "timeout": return .tronWarning
        default: return .tronTextSecondary
        }
    }

    private var reasonText: String {
        switch reason {
        case "approved": return "Plan approved"
        case "cancelled": return "Plan cancelled"
        case "timeout": return "Plan timed out"
        default: return "Plan mode ended"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: reasonIcon)
                .font(TronTypography.codeSM)
                .foregroundStyle(reasonColor)

            Text(reasonText)
                .font(TronTypography.filePath)
                .foregroundStyle(reasonColor.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(reasonColor.opacity(0.1))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(reasonColor.opacity(0.3), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

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
