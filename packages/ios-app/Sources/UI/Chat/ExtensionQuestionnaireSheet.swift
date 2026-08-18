import SwiftUI

/// Native projection of the bounded @pi9/ask contract. The Gateway remains
/// authoritative; this view owns only an ephemeral draft until submission.
struct ExtensionQuestionnaireSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let interaction: ExtensionInteraction
    let onResolved: () -> Void
    let onLocallyClosed: () -> Void
    @State private var selected: Set<Int> = []
    @State private var comments: [Int: String] = [:]
    @State private var freeform = ""
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var now = Date()

    private var descriptor: ExtensionQuestionnaireDescriptor? { interaction.questionnaire }
    private var expiry: Date? { interaction.expiresAt.flatMap(GatewayTimestamp.parse) }
    private var expired: Bool { expiry.map { now >= $0 } ?? false }
    private var canSubmit: Bool {
        guard !expired, !submitting, let descriptor, responseValidationMessage == nil else { return false }
        return !selected.isEmpty || (descriptor.allowFreeform && !freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var interactionScope: String {
        "\(interaction.id)|\(interaction.hostEpoch)|\(interaction.presentationRevision)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    prompt
                    if let descriptor { options(descriptor) }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronError)
                            .accessibilityLabel("Could not submit: \(errorMessage)")
                    }
                    if let responseValidationMessage {
                        Label(responseValidationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronError)
                            .accessibilityLabel(responseValidationMessage)
                    }
                }
                .padding(20)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(expired ? "Close" : "Cancel", action: close)
                        .foregroundStyle(Color.tronTextMuted)
                        .disabled(submitting)
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Question", accent: .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: submit) {
                        HStack(spacing: 5) {
                            if submitting { ProgressView().controlSize(.mini) }
                            Image(systemName: "paperplane.fill")
                            Text("Submit")
                        }
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(canSubmit ? Color.tronAmber : Color.tronTextMuted)
                    }
                    .disabled(!canSubmit)
                    .accessibilityLabel("Submit answer")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .onChange(of: interactionScope) { _, _ in reset() }
        .task(id: interactionScope) {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let context = descriptor?.context, !context.isEmpty {
                Text(context)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            Text(descriptor?.question ?? interaction.title)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let expiry {
                Text(expired ? "This question expired. You can close it." : "Expires \(expiry, style: .relative)")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(expired ? Color.tronError : Color.tronTextMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
        .accessibilityElement(children: .combine)
    }

    private func options(_ descriptor: ExtensionQuestionnaireDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(descriptor.allowMultiple ? "Select all that apply" : "Select one")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextMuted)
            ForEach(Array(descriptor.options.enumerated()), id: \.offset) { index, option in
                optionRow(index: index, option: option, descriptor: descriptor)
            }
            if descriptor.allowFreeform { freeformRow }
        }
    }

    private func optionRow(index: Int, option: ExtensionQuestionnaireOption, descriptor: ExtensionQuestionnaireDescriptor) -> some View {
        let isSelected = selected.contains(index)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !submitting, !expired else { return }
                if descriptor.allowMultiple {
                    if isSelected { selected.remove(index) } else { selected.insert(index) }
                } else {
                    selected = [index]
                    freeform = ""
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? (descriptor.allowMultiple ? "checkmark.square.fill" : "checkmark.circle.fill") : (descriptor.allowMultiple ? "square" : "circle"))
                        .foregroundStyle(isSelected ? Color.tronAmber : Color.tronTextMuted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.label).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                        if let description = option.description {
                            Text(description).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(submitting || expired)
            if isSelected, let preview = option.preview, !preview.isEmpty {
                TronMarkdownView(text: preview, streaming: false)
                    .padding(.leading, 30)
                    .accessibilityLabel("Preview for \(option.label)")
            }
            if isSelected {
                TextField("Optional comment", text: Binding(get: { comments[index, default: ""] }, set: { comments[index] = $0 }), axis: .vertical)
                    .lineLimit(1...4)
                    .tronField()
                    .padding(.leading, 30)
                    .disabled(submitting || expired)
                    .accessibilityLabel("Comment for \(option.label)")
            }
        }
        .padding(12)
        .tronGlassSurface(accent: isSelected ? .tronAmber : .tronCyan, tintOpacity: isSelected ? 0.16 : 0.06)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var freeformRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other")
                .font(TronTypography.body)
                .foregroundStyle(Color.tronTextPrimary)
            TextField("Type your response", text: Binding(get: { freeform }, set: { value in
                freeform = value
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, descriptor?.allowMultiple == false { selected = [] }
            }), axis: .vertical)
                .lineLimit(2...7)
                .tronField()
                .disabled(submitting || expired)
                .accessibilityLabel("Other response")
        }
        .padding(12)
        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.06)
    }

    private func reset() {
        selected = []
        comments = [:]
        freeform = ""
        submitting = false
        errorMessage = nil
        now = Date()
    }

    private func close() {
        if expired { onLocallyClosed(); dismiss(); return }
        guard !submitting else { return }
        respond(value: nil, cancelled: true)
    }

    private func submit() {
        guard canSubmit, let descriptor else { return }
        let selections = selected.sorted().map { index in
            ExtensionQuestionnaireSelection(option: index, comment: comments[index]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? comments[index] : nil)
        }
        let answer = ExtensionQuestionnaireAnswer(
            selections: selections,
            freeform: freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : freeform
        )
        guard descriptor.allowMultiple || answer.selections.count <= 1 else { return }
        guard ExtensionInteractionResponsePolicy.questionnaireError(answer) == nil else { return }
        let data = try? JSONEncoder.gateway.encode(answer)
        let value = data.flatMap { try? JSONDecoder.gateway.decode(JSONValue.self, from: $0) }
        respond(value: value, cancelled: false)
    }

    private var responseValidationMessage: String? {
        let answer = ExtensionQuestionnaireAnswer(
            selections: selected.sorted().map { index in
                ExtensionQuestionnaireSelection(option: index, comment: comments[index]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? comments[index] : nil)
            },
            freeform: freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : freeform
        )
        return ExtensionInteractionResponsePolicy.questionnaireError(answer)
    }

    private func respond(value: JSONValue?, cancelled: Bool) {
        submitting = true
        errorMessage = nil
        Task {
            do {
                try await model.answerInteraction(interaction, sessionID: sessionID, value: value, cancelled: cancelled)
                onResolved()
                dismiss()
            } catch {
                submitting = false
                errorMessage = error.localizedDescription
                model.lastError = error.localizedDescription
            }
        }
    }
}
