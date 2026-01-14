import SwiftUI

// MARK: - AskUserQuestion Sheet

/// Sheet for answering AskUserQuestion tool calls
/// Uses iOS 26 liquid glass styling matching Context Manager
@available(iOS 26.0, *)
struct AskUserQuestionSheet: View {
    let toolData: AskUserQuestionToolData
    let onSubmit: ([AskUserQuestionAnswer]) -> Void
    let onDismiss: () -> Void
    var readOnly: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var currentQuestionIndex = 0
    @State private var answers: [String: AskUserQuestionAnswer] = [:]

    private var questions: [AskUserQuestion] {
        toolData.params.questions
    }

    private var hasAnyAnswer: Bool {
        questions.contains { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    // Context (if provided)
                    if let context = toolData.params.context {
                        Text(context)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                    }

                    // Questions
                    if questions.count == 1 {
                        // Single question - no paging needed
                        QuestionCardView(
                            question: questions[0],
                            answer: binding(for: questions[0]),
                            questionNumber: 1,
                            totalQuestions: 1,
                            readOnly: readOnly
                        )
                        .padding(.horizontal, 16)
                    } else {
                        // Multiple questions - use TabView pager
                        TabView(selection: $currentQuestionIndex) {
                            ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                                QuestionCardView(
                                    question: question,
                                    answer: binding(for: question),
                                    questionNumber: index + 1,
                                    totalQuestions: questions.count,
                                    readOnly: readOnly
                                )
                                .padding(.horizontal, 16)
                                .tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .frame(minHeight: 280)
                        .animation(.easeInOut(duration: 0.2), value: currentQuestionIndex)

                        // Dot indicators for multiple questions
                        pageIndicators
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(readOnly ? "Answers" : "Questions")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(readOnly ? .tronSuccess : .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !readOnly {
                        Button {
                            submitAnswers()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11, weight: .medium))
                                Text("Submit")
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(hasAnyAnswer ? .tronAmber : .tronTextMuted)
                        }
                        .disabled(!hasAnyAnswer)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronAmber)
        .preferredColorScheme(.dark)
        .onAppear {
            answers = toolData.answers
        }
    }

    // MARK: - Page Indicators

    private var pageIndicators: some View {
        HStack(spacing: 6) {
            ForEach(0..<questions.count, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 6, height: 6)
                    .scaleEffect(index == currentQuestionIndex ? 1.3 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: currentQuestionIndex)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private func dotColor(for index: Int) -> Color {
        let question = questions[index]
        if let answer = answers[question.id], !answer.selectedValues.isEmpty || answer.otherValue?.isEmpty == false {
            return .tronAmber
        } else if index == currentQuestionIndex {
            return .tronAmber.opacity(0.5)
        } else {
            return .tronTextMuted.opacity(0.3)
        }
    }

    // MARK: - Helpers

    private func binding(for question: AskUserQuestion) -> Binding<AskUserQuestionAnswer> {
        Binding(
            get: {
                answers[question.id] ?? AskUserQuestionAnswer(
                    questionId: question.id,
                    selectedValues: [],
                    otherValue: nil
                )
            },
            set: { newValue in
                answers[question.id] = newValue
            }
        )
    }

    private func submitAnswers() {
        let answersList = questions.compactMap { question in
            answers[question.id]
        }
        dismiss()
        onSubmit(answersList)
    }
}

// MARK: - Question Card View

@available(iOS 26.0, *)
struct QuestionCardView: View {
    let question: AskUserQuestion
    @Binding var answer: AskUserQuestionAnswer
    let questionNumber: Int
    let totalQuestions: Int
    var readOnly: Bool = false

    @State private var otherText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: mode indicator + question number (left aligned)
            HStack(spacing: 8) {
                Text(question.mode == .single ? "Select one" : "Select multiple")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)

                if totalQuestions > 1 {
                    Text("·")
                        .foregroundStyle(.tronTextMuted.opacity(0.5))
                    Text("\(questionNumber)/\(totalQuestions)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronAmber.opacity(0.7))
                }

                Spacer()
            }

            // Question text
            Text(question.question)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)

            // Options
            VStack(spacing: 4) {
                ForEach(question.options) { option in
                    CompactOptionRowView(
                        option: option,
                        isSelected: isSelected(option),
                        mode: question.mode,
                        readOnly: readOnly
                    ) {
                        toggleOption(option)
                    }
                }
            }

            // Other option
            if question.allowOther == true {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)

                    TextField(question.otherPlaceholder ?? "Enter your answer...", text: $otherText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tronTextPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.clear)
                                .glassEffect(
                                    .regular.tint(Color.tronAmber.opacity(otherText.isEmpty ? 0.06 : 0.15)),
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                )
                        }
                        .disabled(readOnly)
                        .onChange(of: otherText) { _, newValue in
                            guard !readOnly else { return }
                            answer.otherValue = newValue.isEmpty ? nil : newValue
                        }
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            otherText = answer.otherValue ?? ""
        }
    }

    private func isSelected(_ option: AskUserQuestionOption) -> Bool {
        let value = option.value ?? option.label
        return answer.selectedValues.contains(value)
    }

    private func toggleOption(_ option: AskUserQuestionOption) {
        guard !readOnly else { return }
        let value = option.value ?? option.label

        if question.mode == .single {
            answer.selectedValues = [value]
        } else {
            if answer.selectedValues.contains(value) {
                answer.selectedValues.removeAll { $0 == value }
            } else {
                answer.selectedValues.append(value)
            }
        }
    }
}

// MARK: - Compact Option Row View

@available(iOS 26.0, *)
struct CompactOptionRowView: View {
    let option: AskUserQuestionOption
    let isSelected: Bool
    let mode: AskUserQuestion.SelectionMode
    var readOnly: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Selection indicator
                selectionIndicator

                // Label and description
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular, design: .monospaced))
                        .foregroundStyle(.tronTextPrimary)

                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }

                Spacer()

                // Checkmark for selected state
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tronAmber)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(Color.tronAmber.opacity(isSelected ? 0.22 : 0.06)).interactive(),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if mode == .single {
            Circle()
                .strokeBorder(isSelected ? Color.tronAmber : Color.tronTextMuted.opacity(0.35), lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .overlay {
                    if isSelected {
                        Circle()
                            .fill(Color.tronAmber)
                            .frame(width: 8, height: 8)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isSelected ? Color.tronAmber : Color.tronTextMuted.opacity(0.35), lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tronAmber)
                    }
                }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview("Single Question") {
    AskUserQuestionSheet(
        toolData: AskUserQuestionToolData(
            toolCallId: "call_123",
            params: AskUserQuestionParams(
                questions: [
                    AskUserQuestion(
                        id: "q1",
                        question: "What is your favorite color?",
                        options: [
                            AskUserQuestionOption(label: "Red", value: nil, description: nil),
                            AskUserQuestionOption(label: "Blue", value: nil, description: nil),
                            AskUserQuestionOption(label: "Green", value: nil, description: nil),
                            AskUserQuestionOption(label: "Yellow", value: nil, description: nil),
                            AskUserQuestionOption(label: "Purple", value: nil, description: nil)
                        ],
                        mode: .single,
                        allowOther: true,
                        otherPlaceholder: "Enter a custom color..."
                    )
                ],
                context: nil
            ),
            answers: [:],
            status: .pending,
            result: nil
        ),
        onSubmit: { _ in },
        onDismiss: { }
    )
}

@available(iOS 26.0, *)
#Preview("Multiple Questions") {
    AskUserQuestionSheet(
        toolData: AskUserQuestionToolData(
            toolCallId: "call_123",
            params: AskUserQuestionParams(
                questions: [
                    AskUserQuestion(
                        id: "q1",
                        question: "What approach would you prefer?",
                        options: [
                            AskUserQuestionOption(label: "Approach A", value: nil, description: "Use existing patterns"),
                            AskUserQuestionOption(label: "Approach B", value: nil, description: "Create new abstraction")
                        ],
                        mode: .single,
                        allowOther: nil,
                        otherPlaceholder: nil
                    ),
                    AskUserQuestion(
                        id: "q2",
                        question: "Which files should I modify?",
                        options: [
                            AskUserQuestionOption(label: "Message.swift", value: nil, description: nil),
                            AskUserQuestionOption(label: "ChatViewModel.swift", value: nil, description: nil),
                            AskUserQuestionOption(label: "MessageBubble.swift", value: nil, description: nil)
                        ],
                        mode: .multi,
                        allowOther: nil,
                        otherPlaceholder: nil
                    )
                ],
                context: "Planning the implementation"
            ),
            answers: [:],
            status: .pending,
            result: nil
        ),
        onSubmit: { _ in },
        onDismiss: { }
    )
}
#endif
