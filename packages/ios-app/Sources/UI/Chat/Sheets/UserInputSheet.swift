import SwiftUI

struct UserInputSheet: View {
    let request: UserInputRequest
    let isAgentActive: Bool
    let onSubmit: ([UserInputAnswer]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedLabels: [String: String]
    @State private var customAnswers: [String: String]
    @State private var customQuestionIds: Set<String>
    @State private var currentQuestionIndex = 0
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focusedQuestionId: String?

    init(
        request: UserInputRequest,
        isAgentActive: Bool,
        onSubmit: @escaping ([UserInputAnswer]) async throws -> Void
    ) {
        self.request = request
        self.isAgentActive = isAgentActive
        self.onSubmit = onSubmit

        var selectedLabels: [String: String] = [:]
        var customAnswers: [String: String] = [:]
        var customQuestionIds = Set<String>()
        for answer in request.answers {
            if let freeText = answer.freeText {
                customQuestionIds.insert(answer.questionId)
                customAnswers[answer.questionId] = freeText
            } else if let selectedLabel = answer.selectedLabel {
                selectedLabels[answer.questionId] = selectedLabel
            }
        }
        _selectedLabels = State(initialValue: selectedLabels)
        _customAnswers = State(initialValue: customAnswers)
        _customQuestionIds = State(initialValue: customQuestionIds)
    }

    private var isReadOnly: Bool { !request.isAnswerable }

    private var accentColor: Color {
        switch request.status {
        case .pending: .tronWarning
        case .answered: .tronSuccess
        case .failed: .tronError
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
            TabView(selection: $currentQuestionIndex) {
                ForEach(Array(request.questions.enumerated()), id: \.element.id) { index, question in
                    questionPage(question, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy(duration: 0.24), value: currentQuestionIndex)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetCloseButton(color: accentColor)
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(
                        title: UserInputPresentation.sheetTitle(for: request),
                        color: accentColor
                    )
                }
                if !isReadOnly {
                    ToolbarItem(placement: .topBarTrailing) {
                        SheetPrimaryActionButton(
                            icon: "paperplane.fill",
                            accent: accentColor,
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
        .tint(accentColor)
        .interactiveDismissDisabled(isSubmitting)
        .tronErrorAlert(message: $errorMessage)
    }

    private func questionPage(_ question: UserInputQuestion, index: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                pageProgress(index: index)

                if request.isAnswerable && isAgentActive {
                    Label("Finishing the current step…", systemImage: "arrow.triangle.2.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(question.header.uppercased())
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(accentColor)

                Text(question.question)
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(question.options) { option in
                    optionRow(question: question, option: option)
                }
                otherRow(question)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityLabel("Question \(index + 1) of \(request.questions.count)")
    }

    private func pageProgress(index: Int) -> some View {
        HStack(spacing: 10) {
            Text(isReadOnly ? "Review answer" : "Select one")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            Spacer(minLength: 8)

            if request.questions.count > 1 {
                HStack(spacing: 5) {
                    ForEach(request.questions.indices, id: \.self) { page in
                        Circle()
                            .fill(page == index ? accentColor : Color.tronTextMuted.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }

            Text("\(index + 1)/\(request.questions.count)")
                .font(TronTypography.codeCaption)
                .foregroundStyle(accentColor)
        }
    }

    @ViewBuilder
    private func optionRow(
        question: UserInputQuestion,
        option: UserInputOption
    ) -> some View {
        let selected = selectedLabels[question.id] == option.label
            && !customQuestionIds.contains(question.id)
        Group {
            if isReadOnly {
                optionRowContent(option: option, selected: selected)
            } else {
                Button {
                    selectedLabels[question.id] = option.label
                    customQuestionIds.remove(question.id)
                    focusedQuestionId = nil
                } label: {
                    optionRowContent(option: option, selected: selected)
                }
                .buttonStyle(.plain)
            }
        }
        .sectionFill(accentColor, subtle: !selected, interactive: !isReadOnly)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func optionRowContent(option: UserInputOption, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(selected ? accentColor : .tronTextMuted)
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
        .padding(14)
        .contentShape(Rectangle())
    }

    private func otherRow(_ question: UserInputQuestion) -> some View {
        let selected = customQuestionIds.contains(question.id)
        return VStack(alignment: .leading, spacing: 10) {
            if isReadOnly {
                otherRowHeader(selected: selected)
            } else {
                Button {
                    customQuestionIds.insert(question.id)
                    selectedLabels[question.id] = nil
                    focusedQuestionId = question.id
                } label: {
                    otherRowHeader(selected: selected)
                }
                .buttonStyle(.plain)
            }

            if selected {
                if isReadOnly {
                    Text(customAnswers[question.id] ?? "No answer")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                } else {
                    TextField("Type your answer", text: customBinding(question.id), axis: .vertical)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(2...6)
                        .focused($focusedQuestionId, equals: question.id)
                        .padding(12)
                        .background(Color.tronSurface.opacity(0.34))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
        }
        .sectionFill(accentColor, subtle: !selected, interactive: !isReadOnly)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func otherRowHeader(selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(selected ? accentColor : .tronTextMuted)
            Text("Other")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, selected ? 0 : 14)
        .contentShape(Rectangle())
    }

    private func customBinding(_ questionId: String) -> Binding<String> {
        Binding(
            get: { customAnswers[questionId] ?? "" },
            set: { customAnswers[questionId] = $0 }
        )
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
                    Text(UserInputPresentation.chatTitle(for: request))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(UserInputPresentation.chatDetail(for: request))
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
        .sectionFill(statusColor, interactive: true)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(maxWidth: 460, alignment: .leading)
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
        case .pending: .tronWarning
        case .answered: .tronSuccess
        case .failed: .tronError
        }
    }
}
