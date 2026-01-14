import SwiftUI

// MARK: - AskUserQuestion Tool Viewer

/// In-chat viewer for AskUserQuestion tool calls
/// Compact chip style matching SkillChip - glassy capsule with status colors
/// Uses async model: pending → answered or superseded
@available(iOS 26.0, *)
struct AskUserQuestionToolViewer: View {
    let data: AskUserQuestionToolData
    let onTap: () -> Void

    private var questionCount: Int {
        data.params.questions.count
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // Status icon
                statusIcon

                // Status text
                Text(statusText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                // Question count badge (for multiple questions)
                if questionCount > 1 {
                    Text("(\(questionCount))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(textColor.opacity(0.7))
                }

                // Chevron for tappable states
                if data.status != .superseded {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(tintColor.opacity(0.35)),
                        in: .capsule
                    )
            }
            .overlay(
                Capsule()
                    .strokeBorder(tintColor.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(data.status == .superseded)
        .opacity(data.status == .superseded ? 0.6 : 1.0)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .pending:
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronAmber)
        case .answered:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronSuccess)
        case .superseded:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tronTextMuted)
        }
    }

    private var statusText: String {
        switch data.status {
        case .pending:
            return questionCount == 1 ? "Answer question" : "Answer questions"
        case .answered:
            return "Answered"
        case .superseded:
            return "Skipped"
        }
    }

    private var textColor: Color {
        switch data.status {
        case .pending:
            return .tronAmber
        case .answered:
            return .tronSuccess
        case .superseded:
            return .tronTextMuted
        }
    }

    private var tintColor: Color {
        switch data.status {
        case .pending:
            return .tronAmber
        case .answered:
            return .tronSuccess
        case .superseded:
            return .tronTextMuted
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("All States") {
    VStack(spacing: 16) {
        // Pending - single question
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_1",
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
                status: .pending,
                result: nil
            ),
            onTap: { }
        )

        // Pending - multiple questions
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_2",
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

        // Answered
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_3",
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

        // Superseded
        AskUserQuestionToolViewer(
            data: AskUserQuestionToolData(
                toolCallId: "call_4",
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
    }
    .padding()
    .background(Color.tronBackground)
    .preferredColorScheme(.dark)
}
#endif
