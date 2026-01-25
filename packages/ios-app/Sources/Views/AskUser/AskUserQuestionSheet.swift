import SwiftUI

// MARK: - AskUserQuestion Sheet

/// Sheet for answering AskUserQuestion tool calls
/// Displays ONLY questions/answers - no surrounding context or agent messages
/// Uses iOS 26 liquid glass styling
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
            VStack(spacing: 0) {
                if questions.count == 1 {
                    // Single question - simple scrollable content
                    singleQuestionView
                } else {
                    // Multiple questions - TabView with scrollable cards + bottom dots
                    multipleQuestionsView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(readOnly ? "Answers" : "Questions")
                        .font(TronTypography.mono(size: TronTypography.sizeBodyLG, weight: .semibold))
                        .foregroundStyle(readOnly ? .tronSuccess : .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !readOnly {
                        Button {
                            submitAnswers()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "paperplane.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .medium))
                                Text("Submit")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                            }
                            .foregroundStyle(hasAnyAnswer ? .tronAmber : .tronTextMuted)
                        }
                        .disabled(!hasAnyAnswer)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronAmber)
        .preferredColorScheme(.dark)
        .onAppear {
            answers = toolData.answers
        }
    }

    // MARK: - Single Question View

    private var singleQuestionView: some View {
        ScrollView(.vertical) {
            QuestionCardView(
                question: questions[0],
                answer: binding(for: questions[0]),
                questionNumber: 1,
                totalQuestions: 1,
                status: toolData.status,
                readOnly: readOnly
            )
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - Multiple Questions View

    private var multipleQuestionsView: some View {
        VStack(spacing: 0) {
            // TabView takes available space
            TabView(selection: $currentQuestionIndex) {
                ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                    ScrollView(.vertical) {
                        QuestionCardView(
                            question: question,
                            answer: binding(for: question),
                            questionNumber: index + 1,
                            totalQuestions: questions.count,
                            status: toolData.status,
                            readOnly: readOnly
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 24)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.2), value: currentQuestionIndex)

            // Page indicators pinned at bottom
            pageIndicators
                .padding(.bottom, 16)
        }
    }

    // MARK: - Page Indicators

    private var pageIndicators: some View {
        HStack(spacing: 8) {
            ForEach(0..<questions.count, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == currentQuestionIndex ? 1.2 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: currentQuestionIndex)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentQuestionIndex = index
                        }
                    }
            }
        }
        .padding(.vertical, 12)
    }

    private func dotColor(for index: Int) -> Color {
        let question = questions[index]
        let accentColor = statusAccentColor
        if let answer = answers[question.id], !answer.selectedValues.isEmpty || answer.otherValue?.isEmpty == false {
            return accentColor
        } else if index == currentQuestionIndex {
            return accentColor.opacity(0.5)
        } else {
            return .tronTextMuted.opacity(0.3)
        }
    }

    private var statusAccentColor: Color {
        switch toolData.status {
        case .pending:
            return .tronAmber
        case .answered:
            return .tronSuccess
        case .superseded:
            return .tronTextMuted
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
    var status: AskUserQuestionStatus = .pending
    var readOnly: Bool = false

    @State private var otherText = ""

    private var accentColor: Color {
        switch status {
        case .pending:
            return .tronAmber
        case .answered:
            return .tronSuccess
        case .superseded:
            return .tronTextMuted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: mode indicator + question number (left aligned)
            HStack(spacing: 8) {
                Text(question.mode == .single ? "Select one" : "Select multiple")
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextMuted)

                if totalQuestions > 1 {
                    Text("·")
                        .foregroundStyle(.tronTextMuted.opacity(0.5))
                    Text("\(questionNumber)/\(totalQuestions)")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(accentColor.opacity(0.7))
                }

                Spacer()
            }

            // Question text
            Text(question.question)
                .font(TronTypography.mono(size: TronTypography.sizeBodyLG, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(4)
                .padding(.bottom, 4)

            // Options
            VStack(spacing: 8) {
                ForEach(question.options) { option in
                    CompactOptionRowView(
                        option: option,
                        isSelected: isSelected(option),
                        mode: question.mode,
                        accentColor: accentColor,
                        readOnly: readOnly
                    ) {
                        toggleOption(option)
                    }
                }
            }

            // Other option
            if question.allowOther == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)

                    TextField(question.otherPlaceholder ?? "Enter your answer...", text: $otherText)
                        .textFieldStyle(.plain)
                        .font(TronTypography.messageBody)
                        .foregroundStyle(.tronTextPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(
                                    .regular.tint(accentColor.opacity(otherText.isEmpty ? 0.06 : 0.15)),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .disabled(readOnly)
                        .onChange(of: otherText) { _, newValue in
                            guard !readOnly else { return }
                            answer.otherValue = newValue.isEmpty ? nil : newValue
                        }
                }
                .padding(.top, 8)
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
    var accentColor: Color = .tronAmber
    var readOnly: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Selection indicator
                selectionIndicator

                // Label and description
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.tronTextPrimary)

                    if let description = option.description {
                        Text(description)
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .lineSpacing(2)
                    }
                }

                Spacer()

                // Checkmark for selected state
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(accentColor.opacity(isSelected ? 0.22 : 0.06)).interactive(),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if mode == .single {
            Circle()
                .strokeBorder(isSelected ? accentColor : Color.tronTextMuted.opacity(0.35), lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .overlay {
                    if isSelected {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(isSelected ? accentColor : Color.tronTextMuted.opacity(0.35), lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(TronTypography.badge)
                            .foregroundStyle(accentColor)
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
#endif
