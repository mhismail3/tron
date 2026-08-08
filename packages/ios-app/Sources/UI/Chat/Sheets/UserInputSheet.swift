import SwiftUI

struct UserInputSheet: View {
    let request: UserInputRequest
    let isAgentActive: Bool
    let onSubmit: ([UserInputAnswer]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedLabels: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]
    @State private var customQuestionIds: Set<String> = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var isReadOnly: Bool { !request.isAnswerable }

    private var sheetTitle: String {
        switch request.status {
        case .answered: "Answers"
        case .failed: "Unavailable"
        case .pending: "Question"
        }
    }

    private var canSubmit: Bool {
        !isReadOnly && !isAgentActive && request.questions.allSatisfy { question in
            if customQuestionIds.contains(question.id) {
                return customAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            }
            return selectedLabels[question.id] != nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if request.isAnswerable && isAgentActive {
                        Label("Finishing the current step…", systemImage: "arrow.triangle.2.circlepath")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    ForEach(request.questions) { question in
                        questionSection(question)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCloseButton(color: .tronEmerald)
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(
                        title: sheetTitle,
                        color: .tronEmerald
                    )
                }
                if !isReadOnly {
                    ToolbarItem(placement: .topBarTrailing) {
                        SheetPrimaryActionButton(
                            icon: "paperplane.fill",
                            accent: .tronEmerald,
                            isBusy: isSubmitting,
                            isEnabled: canSubmit,
                            accessibilityLabel: "Submit answers"
                        ) {
                            submit()
                        }
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
        .interactiveDismissDisabled(isSubmitting)
        .tronErrorAlert(message: $errorMessage)
        .onAppear(perform: restoreAnswers)
    }

    private func questionSection(_ question: UserInputQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.header.uppercased())
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronEmerald)

            Text(question.question)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(question.options) { option in
                    optionRow(question: question, option: option)
                }
                otherRow(question)
            }
        }
        .padding(16)
        .sectionFill(.tronEmerald, interactive: false)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func optionRow(
        question: UserInputQuestion,
        option: UserInputOption
    ) -> some View {
        let selected = selectedLabels[question.id] == option.label
            && !customQuestionIds.contains(question.id)
        return Button {
            guard !isReadOnly else { return }
            selectedLabels[question.id] = option.label
            customQuestionIds.remove(question.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(selected ? .tronEmerald : .tronTextMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(option.description)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.tronEmerald.opacity(0.12) : Color.tronSurface.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func otherRow(_ question: UserInputQuestion) -> some View {
        let selected = customQuestionIds.contains(question.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !isReadOnly else { return }
                customQuestionIds.insert(question.id)
                selectedLabels[question.id] = nil
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? .tronEmerald : .tronTextMuted)
                    Text("Other")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .buttonStyle(.plain)

            if selected {
                TextField("Type your answer", text: customBinding(question.id), axis: .vertical)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2...6)
                    .disabled(isReadOnly)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(selected ? Color.tronEmerald.opacity(0.12) : Color.tronSurface.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func customBinding(_ questionId: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionId] ?? "" },
            set: { customAnswers[questionId] = $0 }
        )
    }

    private func restoreAnswers() {
        for answer in request.answers {
            if let freeText = answer.freeText {
                customQuestionIds.insert(answer.questionId)
                customAnswers[answer.questionId] = freeText
            } else if let selectedLabel = answer.selectedLabel {
                selectedLabels[answer.questionId] = selectedLabel
            }
        }
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        let answers = request.questions.map { question in
            if customQuestionIds.contains(question.id) {
                return UserInputAnswer(
                    questionId: question.id,
                    selectedLabel: nil,
                    freeText: customAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            return UserInputAnswer(
                questionId: question.id,
                selectedLabel: selectedLabels[question.id],
                freeText: nil
            )
        }
        isSubmitting = true
        Task {
            do {
                try await onSubmit(answers)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

struct UserInputRequestChip: View {
    let request: UserInputRequest
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Image(systemName: statusIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(request.questions.first?.question ?? "Input requested")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sectionFill(statusColor, interactive: request.isAnswerable)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var title: String {
        switch request.status {
        case .pending: request.questions.count == 1 ? "Question for you" : "Questions for you"
        case .answered: "Answered"
        case .failed: "Question unavailable"
        }
    }

    private var statusIcon: String {
        switch request.status {
        case .pending: "questionmark.bubble"
        case .answered: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch request.status {
        case .pending: .tronEmerald
        case .answered: .tronSuccess
        case .failed: .tronError
        }
    }
}

struct UserInputAnswerChip: View {
    let answer: UserInputAnswerPresentation

    var body: some View {
        Label(
            answer.answers.count == 1 ? "Answered question" : "Answered \(answer.answers.count) questions",
            systemImage: "checkmark.circle.fill"
        )
        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
        .foregroundStyle(.tronTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .sectionFill(.tronSuccess, interactive: false)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
