import SwiftUI

// MARK: - AskUserQuestion Tool Viewer

/// In-chat viewer for AskUserQuestion tool calls
/// Shows a summary card that can be tapped to open the question sheet
/// Uses async model: pending → answered or superseded
@available(iOS 26.0, *)
struct AskUserQuestionToolViewer: View {
    let data: AskUserQuestionToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Status icon
                statusIcon

                VStack(alignment: .leading, spacing: 4) {
                    // Title
                    Text(statusTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)

                    // Subtitle
                    Text("\(data.params.questions.count) question(s)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tronTextSecondary)
                }

                Spacer()

                // Show chevron for pending and answered (tappable states)
                if data.status == .pending || data.status == .answered {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(data.status == .pending ? .tronAmber : .tronSuccess)
                }
            }
            .padding(12)
            .background(Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(data.status == .superseded) // Only superseded is non-tappable
        .opacity(data.status == .superseded ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .pending:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tronAmber)
        case .answered:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tronSuccess)
        case .superseded:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private var statusTitle: String {
        switch data.status {
        case .pending:
            return "Tap to answer"
        case .answered:
            return "Tap to view answers"
        case .superseded:
            return "Skipped"
        }
    }

    private var statusColor: Color {
        switch data.status {
        case .pending:
            return .tronAmber
        case .answered:
            return .tronSuccess
        case .superseded:
            return .tronTextMuted
        }
    }

    private var borderColor: Color {
        switch data.status {
        case .pending:
            return .tronAmber.opacity(0.5)
        case .answered:
            return .tronSuccess.opacity(0.5)
        case .superseded:
            return .tronBorder
        }
    }
}

// MARK: - Compact Viewer (for collapsed state)

@available(iOS 26.0, *)
struct AskUserQuestionCompactViewer: View {
    let data: AskUserQuestionToolData
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                statusIcon

                Text("\(data.params.questions.count) questions")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tronTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.tronSurface.opacity(0.5))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(data.status == .superseded) // Only superseded is non-tappable
        .opacity(data.status == .superseded ? 0.5 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .pending:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.tronAmber)
        case .answered:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.tronSuccess)
        case .superseded:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.tronTextMuted)
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("Pending") {
    VStack {
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_123",
                params: AskUserQuestionParams(
                    questions: [
                        AskUserQuestion(
                            id: "q1",
                            question: "What approach?",
                            options: [
                                AskUserQuestionOption(label: "A", value: nil, description: nil),
                                AskUserQuestionOption(label: "B", value: nil, description: nil)
                            ],
                            mode: .single,
                            allowOther: nil,
                            otherPlaceholder: nil
                        ),
                        AskUserQuestion(
                            id: "q2",
                            question: "Which files?",
                            options: [
                                AskUserQuestionOption(label: "File1", value: nil, description: nil),
                                AskUserQuestionOption(label: "File2", value: nil, description: nil)
                            ],
                            mode: .multi,
                            allowOther: nil,
                            otherPlaceholder: nil
                        )
                    ],
                    context: nil
                ),
                answers: [:],
                status: .pending,
                result: nil
            ),
            onTap: { }
        )
        .padding()
    }
    .background(Color.tronBackground)
}

@available(iOS 26.0, *)
#Preview("Answered") {
    VStack {
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_123",
                params: AskUserQuestionParams(
                    questions: [
                        AskUserQuestion(
                            id: "q1",
                            question: "What approach?",
                            options: [
                                AskUserQuestionOption(label: "A", value: nil, description: nil),
                                AskUserQuestionOption(label: "B", value: nil, description: nil)
                            ],
                            mode: .single,
                            allowOther: nil,
                            otherPlaceholder: nil
                        )
                    ],
                    context: nil
                ),
                answers: ["q1": AskUserQuestionAnswer(questionId: "q1", selectedValues: ["A"], otherValue: nil)],
                status: .answered,
                result: AskUserQuestionResult(
                    answers: [AskUserQuestionAnswer(questionId: "q1", selectedValues: ["A"], otherValue: nil)],
                    complete: true,
                    submittedAt: ISO8601DateFormatter().string(from: Date())
                )
            ),
            onTap: { }
        )
        .padding()
    }
    .background(Color.tronBackground)
}

@available(iOS 26.0, *)
#Preview("Superseded") {
    VStack {
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_123",
                params: AskUserQuestionParams(
                    questions: [
                        AskUserQuestion(
                            id: "q1",
                            question: "What approach?",
                            options: [
                                AskUserQuestionOption(label: "A", value: nil, description: nil),
                                AskUserQuestionOption(label: "B", value: nil, description: nil)
                            ],
                            mode: .single,
                            allowOther: nil,
                            otherPlaceholder: nil
                        )
                    ],
                    context: nil
                ),
                answers: [:],
                status: .superseded,
                result: nil
            ),
            onTap: { }
        )
        .padding()
    }
    .background(Color.tronBackground)
}
#endif
