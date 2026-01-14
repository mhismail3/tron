import SwiftUI

// MARK: - AskUserQuestion Sheet

/// Sheet for answering AskUserQuestion tool calls
/// Uses amber/gold theme for attention-grabbing UI
@available(iOS 26.0, *)
struct AskUserQuestionSheet: View {
    let toolData: AskUserQuestionToolData
    let onSubmit: ([AskUserQuestionAnswer]) -> Void
    let onDismiss: () -> Void

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
                // Progress header
                progressHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Context (if provided)
                if let context = toolData.params.context {
                    Text(context)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.tronTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                // Questions pager
                TabView(selection: $currentQuestionIndex) {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                        QuestionCardView(
                            question: question,
                            answer: binding(for: question),
                            questionNumber: index + 1,
                            totalQuestions: questions.count
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentQuestionIndex)

                // Bottom bar
                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            }
            .background(Color.tronBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Questions")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronAmber)
        .preferredColorScheme(.dark)
        .onAppear {
            // Initialize answers from tool data
            answers = toolData.answers
        }
    }

    // MARK: - Progress Header

    private var progressHeader: some View {
        HStack(spacing: 8) {
            // Dot indicators
            ForEach(0..<questions.count, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 8, height: 8)
            }

            Spacer()

            // Progress text
            Text("\(answeredCount) of \(questions.count)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.tronTextSecondary)
        }
        .padding(.vertical, 8)
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Previous button
            Button {
                withAnimation {
                    currentQuestionIndex = max(0, currentQuestionIndex - 1)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Prev")
                }
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(currentQuestionIndex > 0 ? .tronAmber : .tronTextMuted)
            }
            .disabled(currentQuestionIndex == 0)

            Spacer()

            // Submit button (only on last question or when complete)
            if isComplete || currentQuestionIndex == questions.count - 1 {
                Button {
                    submitAnswers()
                } label: {
                    HStack(spacing: 4) {
                        Text("Submit")
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tronBackground)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isComplete ? Color.tronAmber : Color.tronTextMuted)
                    .clipShape(Capsule())
                }
                .disabled(!isComplete)
            } else {
                // Next button
                Button {
                    withAnimation {
                        currentQuestionIndex = min(questions.count - 1, currentQuestionIndex + 1)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Next")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronAmber)
                }
            }
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

    @State private var otherText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Question text
                Text(question.question)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.bottom, 8)

                // Mode indicator
                Text(question.mode == .single ? "Select one" : "Select all that apply")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tronTextMuted)

                // Options
                VStack(spacing: 8) {
                    ForEach(question.options) { option in
                        OptionRowView(
                            option: option,
                            isSelected: isSelected(option),
                            mode: question.mode
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
                            .background(Color.tronSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(otherText.isEmpty ? Color.tronBorder : Color.tronAmber, lineWidth: 1)
                            )
                            .onChange(of: otherText) { _, newValue in
                                answer.otherValue = newValue.isEmpty ? nil : newValue
                            }
                    }
                    .padding(.top, 8)
                }

                Spacer(minLength: 60)
            }
            .padding(16)
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

// MARK: - Option Row View

@available(iOS 26.0, *)
struct OptionRowView: View {
    let option: AskUserQuestionOption
    let isSelected: Bool
    let mode: AskUserQuestion.SelectionMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Selection indicator
                selectionIndicator

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 16))
                        .foregroundStyle(.tronTextPrimary)

                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.tronTextSecondary)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(isSelected ? Color.tronAmber.opacity(0.15) : Color.tronSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.tronAmber : Color.tronBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if mode == .single {
            // Radio button
            Circle()
                .strokeBorder(isSelected ? Color.tronAmber : Color.tronTextMuted, lineWidth: 2)
                .frame(width: 20, height: 20)
                .overlay {
                    if isSelected {
                        Circle()
                            .fill(Color.tronAmber)
                            .frame(width: 10, height: 10)
                    }
                }
        } else {
            // Checkbox
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.tronAmber : Color.tronTextMuted, lineWidth: 2)
                .frame(width: 20, height: 20)
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
