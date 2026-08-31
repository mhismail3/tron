import SwiftUI

typealias PendingExtensionInteractionPresenter = @MainActor @Sendable (ExtensionInteraction) -> Void

private struct PendingExtensionInteractionPresenterKey: EnvironmentKey {
    static let defaultValue: PendingExtensionInteractionPresenter? = nil
}

extension EnvironmentValues {
    var pendingExtensionInteractionPresenter: PendingExtensionInteractionPresenter? {
        get { self[PendingExtensionInteractionPresenterKey.self] }
        set { self[PendingExtensionInteractionPresenterKey.self] = newValue }
    }
}

enum PendingExtensionInteractionToolPresentation {
    @MainActor
    static func interaction(
        tools: [ChatToolDescriptor],
        sessionID: String,
        model: AppModel
    ) -> ExtensionInteraction? {
        interaction(
            tools: tools,
            pendingInteractions: model.authoritativeSnapshot(for: sessionID)?
                .extensionPresentation.pendingInteractions ?? []
        )
    }

    /// Matches the pending interaction to the tool's operation/extension owner,
    /// not to the tool-call ID. Pi's semantic interaction carries the enclosing
    /// prompt invocation ID, which is deliberately distinct from its tool-call ID.
    static func interaction(
        tools: [ChatToolDescriptor],
        pendingInteractions: [ExtensionInteraction]
    ) -> ExtensionInteraction? {
        guard !tools.isEmpty, !pendingInteractions.isEmpty else { return nil }

        let operationMatches = pendingInteractions.filter { interaction in
            guard let operationID = interaction.operationId else { return false }
            return tools.contains { tool in
                tool.isRunning
                    && toolOperationID(tool) == operationID
                    && ownersMatch(interaction: interaction, tool: tool)
                    && (interaction.method != .form || isAuditedAskUser(tool))
            }
        }
        if operationMatches.count == 1 { return operationMatches[0] }
        guard operationMatches.isEmpty else { return nil }

        // A running ask_user blocks its serialized session lane, so one exact
        // audited owner and one pending form are an unambiguous fallback when a
        // cold canonical tool segment no longer exposes the live operation ID.
        let askUserTools = tools.filter { tool in
            tool.isRunning && isAuditedAskUser(tool)
        }
        guard askUserTools.count == 1, let tool = askUserTools.first else { return nil }
        let formMatches = pendingInteractions.filter { interaction in
            interaction.method == .form && ownersMatch(interaction: interaction, tool: tool)
        }
        return formMatches.count == 1 ? formMatches[0] : nil
    }

    private static func isAuditedAskUser(_ tool: ChatToolDescriptor) -> Bool {
        tool.toolName == "ask_user"
            && tool.extensionOrigin?.owner?.source == AskUserToolPresentation.auditedSource
    }

    private static func toolOperationID(_ tool: ChatToolDescriptor) -> String? {
        guard let segment = tool.toolSegmentId,
              segment.hasPrefix("tool-segment:") else { return nil }
        let encoded = segment.dropFirst("tool-segment:".count)
        return try? JSONDecoder().decode(String.self, from: Data(encoded.utf8))
    }

    private static func ownersMatch(
        interaction: ExtensionInteraction,
        tool: ChatToolDescriptor
    ) -> Bool {
        guard let interactionOwner = interaction.owner,
              let toolOwner = tool.extensionOrigin?.owner else { return false }
        return interactionOwner == toolOwner
    }
}

struct AskUserToolPresentation: Equatable, Sendable {
    static let auditedSource = "npm:@zhushanwen/pi-ask-user@7.0.15"

    let form: ExtensionFormDescriptor
    let answer: ExtensionFormAnswer?
    let cancelled: Bool

    static func completed(tool: ChatToolPresentation) -> AskUserToolPresentation? {
        guard tool.toolName == "ask_user",
              tool.extensionOrigin?.owner?.source == auditedSource,
              !tool.isRunning,
              !tool.error,
              let result = tool.response?.objectValue,
              Set(result.keys).isSubset(of: ["questions", "answers", "cancelled"]),
              let cancelled = result["cancelled"]?.boolValue,
              let rawQuestions = result["questions"]?.arrayValue,
              (1...4).contains(rawQuestions.count),
              let answersObject = result["answers"]?.objectValue else { return nil }

        var questions: [ExtensionFormQuestion] = []
        var questionTexts = Set<String>()
        var headers = Set<String>()
        for (questionIndex, rawQuestion) in rawQuestions.enumerated() {
            guard let question = parseQuestion(
                rawQuestion,
                index: questionIndex,
                count: rawQuestions.count
            ), questionTexts.insert(question.question).inserted else { return nil }
            if let header = question.header, !headers.insert(header).inserted { return nil }
            questions.append(question)
        }
        let form = ExtensionFormDescriptor(
            version: 1,
            title: questions.count == 1 ? (questions[0].header ?? "Question") : "Questions",
            questions: questions,
            allowCancel: true
        )
        if cancelled {
            guard answersObject.isEmpty else { return nil }
            return AskUserToolPresentation(form: form, answer: nil, cancelled: true)
        }
        guard Set(answersObject.keys) == Set(questions.map(\.question)) else { return nil }

        var answers: [ExtensionFormQuestionAnswer] = []
        for question in questions {
            guard let rawAnswer = answersObject[question.question]?.objectValue,
                  Set(rawAnswer.keys).isSubset(of: ["selected", "other"]),
                  let selectedValues = rawAnswer["selected"]?.arrayValue else { return nil }
            let selectedLabels = selectedValues.compactMap(\.stringValue)
            guard selectedLabels.count == selectedValues.count,
                  Set(selectedLabels).count == selectedLabels.count else { return nil }
            let optionsByLabel = Dictionary(uniqueKeysWithValues: question.options.map { ($0.label, $0.id) })
            guard selectedLabels.allSatisfy({ optionsByLabel[$0] != nil }) else { return nil }
            let optionIDs = question.options.compactMap { option in
                selectedLabels.contains(option.label) ? option.id : nil
            }
            let other: String?
            if let value = rawAnswer["other"] {
                switch value {
                case .null:
                    other = nil
                case .string(let text) where admits(text, maximumBytes: ExtensionInteractionResponsePolicy.maximumOtherBytes, newlines: true)
                    && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    other = text
                default:
                    return nil
                }
            } else {
                other = nil
            }
            answers.append(ExtensionFormQuestionAnswer(
                questionId: question.id,
                optionIds: optionIDs,
                other: other
            ))
        }
        let answer = ExtensionFormAnswer(version: 1, answers: answers)
        guard ExtensionInteractionResponsePolicy.formError(answer, descriptor: form) == nil else { return nil }
        return AskUserToolPresentation(form: form, answer: answer, cancelled: false)
    }

    private static func parseQuestion(
        _ value: JSONValue,
        index: Int,
        count: Int
    ) -> ExtensionFormQuestion? {
        guard let object = value.objectValue,
              Set(object.keys).isSubset(of: ["header", "question", "context", "options", "multiSelect"]),
              let text = object["question"]?.stringValue,
              admits(text, maximumBytes: 4 * 1_024),
              !text.isEmpty,
              text.count <= 1_000,
              let rawOptions = object["options"]?.arrayValue,
              (2...4).contains(rawOptions.count) else { return nil }
        let header = object["header"]?.stringValue
        guard (object["header"] == nil || header != nil),
              header.map({ admits($0, maximumBytes: 256) && !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 12 }) ?? (count == 1) else {
            return nil
        }
        let context = object["context"]?.stringValue
        guard (object["context"] == nil || context != nil),
              context.map({ admits($0, maximumBytes: 32 * 1_024, newlines: true) }) ?? true else { return nil }
        let multiSelect = object["multiSelect"]?.boolValue ?? false
        guard object["multiSelect"] == nil || object["multiSelect"]?.boolValue != nil else { return nil }
        var labels = Set<String>()
        var options: [ExtensionFormOption] = []
        for (optionIndex, rawOption) in rawOptions.enumerated() {
            guard let option = rawOption.objectValue,
                  Set(option.keys).isSubset(of: ["label", "description"]),
                  let label = option["label"]?.stringValue,
                  admits(label, maximumBytes: 2 * 1_024),
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  labels.insert(label).inserted else { return nil }
            let description = option["description"]?.stringValue
            guard (option["description"] == nil || description != nil),
                  description.map({ admits($0, maximumBytes: 2 * 1_024, newlines: true) }) ?? true else { return nil }
            options.append(ExtensionFormOption(
                id: "question-\(index)-option-\(optionIndex)",
                label: label,
                description: description
            ))
        }
        return ExtensionFormQuestion(
            id: "question-\(index)",
            header: header,
            question: text,
            context: context,
            options: options,
            multiSelect: multiSelect,
            allowOther: true
        )
    }

    private static func admits(_ value: String, maximumBytes: Int, newlines: Bool = false) -> Bool {
        value.utf8.count <= maximumBytes && !value.unicodeScalars.contains { scalar in
            let code = scalar.value
            if code == 0x0a || code == 0x0d { return !newlines }
            return code < 0x20 || (0x7f...0x9f).contains(code)
        }
    }
}

struct AskUserCompletedFormView: View {
    let presentation: AskUserToolPresentation
    @State private var currentQuestionIndex = 0

    private var answerByQuestionID: [String: ExtensionFormQuestionAnswer] {
        Dictionary(uniqueKeysWithValues: (presentation.answer?.answers ?? []).map { ($0.questionId, $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            status
            TabView(selection: $currentQuestionIndex) {
                ForEach(Array(presentation.form.questions.enumerated()), id: \.element.id) { index, question in
                    questionPage(question, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.snappy(duration: 0.24), value: currentQuestionIndex)
        }
        .background(Color.tronBackground)
        .tronTopBlurSurface()
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(presentation.cancelled ? "No answers submitted" : "Review answers")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(presentation.cancelled ? Color.tronAmber : Color.tronTextSecondary)
                Spacer(minLength: 8)
                if presentation.form.questions.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(presentation.form.questions.indices, id: \.self) { page in
                            Circle()
                                .fill(page == currentQuestionIndex ? Color.tronEmerald : Color.tronTextMuted.opacity(0.35))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text("\(currentQuestionIndex + 1)/\(presentation.form.questions.count)")
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
            }
            if presentation.cancelled {
                Label("This question was cancelled.", systemImage: "xmark.circle")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronAmber)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func questionPage(_ question: ExtensionFormQuestion, index: Int) -> some View {
        let answer = answerByQuestionID[question.id]
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let context = question.context, !context.isEmpty {
                    Text(context)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(question.question)
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    ForEach(question.options) { option in
                        readOnlyOption(option, question: question, selected: answer?.optionIds.contains(option.id) == true)
                    }
                    if question.allowOther {
                        readOnlyOther(question, text: answer?.other)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityLabel("Question \(index + 1) of \(presentation.form.questions.count)")
    }

    private func readOnlyOption(
        _ option: ExtensionFormOption,
        question: ExtensionFormQuestion,
        selected: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: selectionIcon(selected: selected, multiSelect: question.multiSelect))
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(selected ? Color.tronEmerald : Color.tronTextMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .tronGlassSurface(accent: selected ? .tronEmerald : .tronCyan, tintOpacity: selected ? 0.16 : 0.06)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func readOnlyOther(_ question: ExtensionFormQuestion, text: String?) -> some View {
        let selected = text != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: selectionIcon(selected: selected, multiSelect: question.multiSelect))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(selected ? Color.tronEmerald : Color.tronTextMuted)
                Text("Other")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            .padding(.horizontal, 14)
            .padding(.bottom, selected ? 0 : 14)
            if let text {
                Text(text)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            }
        }
        .tronGlassSurface(accent: selected ? .tronEmerald : .tronCyan, tintOpacity: selected ? 0.16 : 0.06)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func selectionIcon(selected: Bool, multiSelect: Bool) -> String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "checkmark.circle.fill" : "circle"
    }
}
