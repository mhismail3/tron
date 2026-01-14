import SwiftUI

// MARK: - AskUserQuestion Sheet

/// Sheet for answering AskUserQuestion tool calls
/// Uses iOS 26 liquid glass styling with amber theme
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

    private var isComplete: Bool {
        questions.allSatisfy { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }
    }

    private var answeredCount: Int {
        questions.filter { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Context (if provided)
                if let context = toolData.params.context {
                    Text(context)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.tronTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Questions pager
                TabView(selection: $currentQuestionIndex) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        QuestionCardView(
                            question: question,
                            answer: binding(for: question),
                            questionNumber: index + 1,
                            totalQuestions: questions.count,
                            readOnly: readOnly
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: currentQuestionIndex)

                // Bottom: Centered dot indicators
                pageIndicators
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(readOnly ? "Answers" : "Questions")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(readOnly ? .tronSuccess : .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        // Submit button (when complete and not read-only)
                        if isComplete && !readOnly {
                            Button {
                                submitAnswers()
                            } label: {
                                Text("Submit")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.tronBackground)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                            }
                            .glassEffect(.regular.tint(Color.tronAmber.opacity(0.65)).interactive(), in: .capsule)
                        }

                        // Close button
                        Button {
                            dismiss()
                            onDismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronAmber)
        .preferredColorScheme(.dark)
        .onAppear {
            // Initialize answers from tool data
            answers = toolData.answers
        }
    }

    // MARK: - Page Indicators

    private var pageIndicators: some View {
        HStack(spacing: 10) {
            ForEach(0..<questions.count, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == currentQuestionIndex ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: currentQuestionIndex)
            }
        }
        .padding(.vertical, 16)
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
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                // Question number badge
                HStack {
                    Text("\(questionNumber) of \(totalQuestions)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronAmber.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.tronAmber.opacity(0.12))
                        .clipShape(Capsule())

                    Spacer()

                    // Mode indicator
                    Text(question.mode == .single ? "Select one" : "Select multiple")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tronTextMuted)
                }

                // Question text
                Text(question.question)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.bottom, 4)

                // Options with glass effect
                VStack(spacing: 10) {
                    ForEach(question.options) { option in
                        GlassOptionRowView(
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Other")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)

                        TextField(question.otherPlaceholder ?? "Enter your answer...", text: $otherText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundStyle(.tronTextPrimary)
                            .padding(12)
                            .glassEffect(
                                .regular.tint(Color.tronAmber.opacity(otherText.isEmpty ? 0.05 : 0.15)),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .disabled(readOnly)
                            .onChange(of: otherText) { _, newValue in
                                guard !readOnly else { return }
                                answer.otherValue = newValue.isEmpty ? nil : newValue
                            }
                    }
                    .padding(.top, 8)
                }

                Spacer(minLength: 40)
            }
            .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            otherText = answer.otherValue ?? ""
        }
    }

    private func isSelected(_ option: AskUserQuestionOption) -> Bool {
        let value = option.value ?? option.label
        return answer.selectedValues.contains(value)
    }

    private func toggleOption(_ option: AskUserQuestionOption) {
        let value = option.value ?? option.label

        if question.mode == .single {
            // Single select: replace selection
            answer.selectedValues = [value]
        } else {
            // Multi select: toggle
            if answer.selectedValues.contains(value) {
                answer.selectedValues.removeAll { $0 == value }
            } else {
                answer.selectedValues.append(value)
            }
        }
    }
}

// MARK: - Glass Option Row View

@available(iOS 26.0, *)
struct GlassOptionRowView: View {
    let option: AskUserQuestionOption
    let isSelected: Bool
    let mode: AskUserQuestion.SelectionMode
    var readOnly: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Selection indicator
                selectionIndicator

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.tronTextPrimary)

                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }

                Spacer()

                // Checkmark for selected state
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tronAmber)
                }
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .glassEffect(
            .regular.tint(Color.tronAmber.opacity(isSelected ? 0.25 : 0.08)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if mode == .single {
            // Radio button
            Circle()
                .strokeBorder(isSelected ? Color.tronAmber : Color.tronTextMuted.opacity(0.5), lineWidth: 2)
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Circle()
                            .fill(Color.tronAmber)
                            .frame(width: 12, height: 12)
                    }
                }
        } else {
            // Checkbox
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.tronAmber : Color.tronTextMuted.opacity(0.5), lineWidth: 2)
                .frame(width: 22, height: 22)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.tronAmber)
                    }
                }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(iOS 26.0, *)
#Preview {
    AskUserQuestionSheet(
        toolData: AskUserQuestionToolData(
            toolCallId: "call_123",
            params: AskUserQuestionParams(
                questions: [
                    AskUserQuestion(
                        id: "q1",
                        question: "What approach would you prefer for implementing this feature?",
                        options: [
                            AskUserQuestionOption(label: "Approach A", value: nil, description: "Use existing patterns"),
                            AskUserQuestionOption(label: "Approach B", value: nil, description: "Create new abstraction"),
                            AskUserQuestionOption(label: "Approach C", value: nil, description: "Refactor first")
                        ],
                        mode: .single,
                        allowOther: true,
                        otherPlaceholder: "Describe your preferred approach..."
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
                context: "I'm planning to implement the AskUserQuestion feature."
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
