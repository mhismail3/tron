import SwiftUI

struct WorkLedgerGoalRow: View {
    let goal: WorkLedgerGoal
    let questionCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: WorkLedgerPresentation.goalSymbol(goal.status))
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(WorkLedgerPresentation.statusColor(goal.status))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(goal.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .multilineTextAlignment(.leading)
                if !goal.description.isEmpty {
                    Text(goal.description)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 9) {
                    Label(WorkerConsolePresentation.displayLabel(goal.status), systemImage: "circle.fill")
                    if questionCount > 0 {
                        Label("\(questionCount)", systemImage: "questionmark.bubble")
                    }
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 5)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(
            WorkLedgerPresentation.statusColor(goal.status),
            cornerRadius: 12,
            subtle: true,
            interactive: true
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WorkLedgerQuestionRow: View {
    let question: WorkLedgerQuestion
    let goalTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "questionmark.bubble")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(WorkLedgerPresentation.statusColor(question.status))
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(question.text)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .multilineTextAlignment(.leading)
                if let goalTitle {
                    Label(goalTitle, systemImage: "target")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                Text(WorkerConsolePresentation.displayLabel(question.status))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(WorkLedgerPresentation.statusColor(question.status))
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 5)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronCyan, cornerRadius: 12, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WorkLedgerDecisionRow: View {
    let decision: WorkLedgerDecision
    let goalTitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "signpost.right.and.left")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronPurple)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(decision.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .multilineTextAlignment(.leading)
                if !decision.rationale.isEmpty {
                    Text(decision.rationale)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if let goalTitle {
                    Label(goalTitle, systemImage: "target")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
                .padding(.top, 5)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct WorkLedgerHistoryRow: View {
    let entry: WorkLedgerHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "clock.arrow.circlepath")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronSlate)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkerConsolePresentation.displayLabel(entry.action))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                HStack(spacing: 5) {
                    Text(WorkerConsolePresentation.displayLabel(entry.entityType))
                    Text("·")
                    Text(WorkerConsolePresentation.compactIdentifier(entry.entityId, length: 18))
                    if let time = WorkerConsolePresentation.timestamp(entry.timestamp) {
                        Text("·")
                        Text(time)
                    }
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .sectionFill(.tronSlate, cornerRadius: 10, subtle: true, interactive: false)
    }
}

enum WorkLedgerPresentation {
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "active", "open": .tronEmerald
        case "answered": .tronCyan
        case "completed", "resolved": .tronSuccess
        case "cancelled": .tronTextMuted
        default: .tronSlate
        }
    }

    static func goalSymbol(_ status: String) -> String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "cancelled": "xmark.circle"
        default: "target"
        }
    }
}
