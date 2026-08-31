import SwiftUI

/// Native projection of one bounded semantic form. The Gateway owns the
/// interaction and lifecycle; this view owns only an ephemeral, ID-keyed draft.
struct ExtensionFormSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    let interaction: ExtensionInteraction
    let onResolved: () -> Void
    let onLocallyClosed: () -> Void

    @State private var draft = ExtensionFormDraft()
    @State private var currentIndex = 0
    @State private var reviewing = false
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var now = Date()

    private var form: ExtensionFormDescriptor? { interaction.form }
    private var currentQuestion: ExtensionFormQuestion? {
        guard let form, form.questions.indices.contains(currentIndex) else { return nil }
        return form.questions[currentIndex]
    }
    private var expiry: Date? { interaction.expiresAt.flatMap(GatewayTimestamp.parse) }
    private var expired: Bool { expiry.map { now >= $0 } ?? false }
    private var interactionScope: String { "\(interaction.id)|\(interaction.hostEpoch)|\(interaction.presentationRevision)" }
    private var responseValidationMessage: String? {
        guard let form, draft.isComplete(form) else { return nil }
        return ExtensionInteractionResponsePolicy.formError(draft.answer(for: form), descriptor: form)
    }
    private var canSubmit: Bool {
        guard !expired, !submitting, let form else { return false }
        return draft.isComplete(form) && responseValidationMessage == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let form {
                        progress(form)
                        if reviewing { review(form) }
                        else if let currentQuestion { questionView(currentQuestion) }
                        navigation(form)
                    } else {
                        Label("This form is unavailable.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.tronError)
                    }
                    if let errorMessage { error(errorMessage) }
                    if let responseValidationMessage { error(responseValidationMessage) }
                }
                .padding(20)
            }
            .tronScrollEdgeChrome()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if expired || form?.allowCancel == true {
                        Button(action: close) {
                            TronToolbarTextLabel(expired ? "Close" : "Cancel", systemImage: "xmark")
                        }
                        .tronToolbarAction(accent: .tronTextMuted)
                        .disabled(submitting)
                        .accessibilityLabel(expired ? "Close expired form" : "Cancel form")
                    }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: form?.title ?? "Questions", accent: .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if reviewing || form?.questions.count == 1 {
                        Button(action: submit) {
                            TronToolbarTextLabel("Submit", systemImage: "paperplane.fill", isWorking: submitting)
                                .tronToolbarAction(accent: canSubmit ? .tronAmber : .tronTextMuted)
                        }
                        .disabled(!canSubmit)
                        .accessibilityLabel("Submit all answers")
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .onAppear { reset() }
        .onChange(of: interactionScope) { _, _ in reset() }
        .task(id: interactionScope) {
            while !Task.isCancelled {
                now = Date()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func progress(_ form: ExtensionFormDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(reviewing ? "Review" : "Question \(currentIndex + 1) of \(form.questions.count)")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                Spacer()
                Text("\(form.questions.filter(draft.isAnswered).count)/\(form.questions.count) answered")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
            }
            ProgressView(value: Double(form.questions.filter(draft.isAnswered).count), total: Double(form.questions.count))
                .tint(Color.tronAmber)
            if let expiry {
                Text(expired ? "This form expired. You can close it." : "Expires \(expiry, style: .relative)")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(expired ? Color.tronError : Color.tronTextMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(reviewing ? "Review answers" : "Question \(currentIndex + 1) of \(form.questions.count)")
    }

    private func questionView(_ question: ExtensionFormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                if let context = question.context, !context.isEmpty {
                    Text(context).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary)
                }
                Text(question.question)
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.10)
            .accessibilityElement(children: .combine)

            Text(question.multiSelect ? "Select all that apply" : "Select one")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextMuted)

            ForEach(question.options) { option in optionRow(option, question: question) }
            if question.allowOther { otherRow(question) }
        }
    }

    private func optionRow(_ option: ExtensionFormOption, question: ExtensionFormQuestion) -> some View {
        let selected = draft.value(for: question.id).optionIDs.contains(option.id)
        return Button {
            guard !submitting, !expired else { return }
            draft.toggle(optionID: option.id, for: question)
            errorMessage = nil
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? (question.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill") : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(selected ? Color.tronAmber : Color.tronTextMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(TronTypography.bodySM).foregroundStyle(Color.tronTextSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitting || expired)
        .padding(12)
        .tronGlassSurface(accent: selected ? .tronAmber : .tronCyan, tintOpacity: selected ? 0.16 : 0.06)
        .accessibilityLabel(option.description.map { "\(option.label), \($0)" } ?? option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func otherRow(_ question: ExtensionFormQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Other").font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
            TextField("Type your response", text: Binding(
                get: { draft.value(for: question.id).other },
                set: { text in
                    if draft.setOther(text, for: question) { errorMessage = nil }
                    else { errorMessage = "Other responses are limited to 32 KiB of UTF-8 text." }
                }
            ), axis: .vertical)
                .lineLimit(2...7)
                .tronField()
                .disabled(submitting || expired)
                .accessibilityLabel("Other response for \(question.header ?? question.question)")
        }
        .padding(12)
        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.06)
    }

    private func review(_ form: ExtensionFormDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review your answers")
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
            ForEach(Array(form.questions.enumerated()), id: \.element.id) { index, question in
                Button {
                    currentIndex = index
                    reviewing = false
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.header ?? question.question)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                        Text(draft.summary(for: question))
                            .font(TronTypography.body)
                            .foregroundStyle(Color.tronTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.06)
                .accessibilityLabel("Edit \(question.header ?? question.question), answer \(draft.summary(for: question))")
            }
        }
    }

    @ViewBuilder
    private func navigation(_ form: ExtensionFormDescriptor) -> some View {
        if form.questions.count > 1 {
            HStack(spacing: 12) {
                if reviewing || currentIndex > 0 {
                    Button(reviewing ? "Back to questions" : "Previous") {
                        if reviewing { reviewing = false }
                        else { currentIndex -= 1 }
                    }
                    .buttonStyle(TronActionButtonStyle(expands: false))
                    .disabled(submitting)
                }
                Spacer()
                if !reviewing {
                    Button(currentIndex == form.questions.count - 1 ? "Review" : "Next") {
                        guard let question = currentQuestion, draft.isAnswered(question) else {
                            errorMessage = "Choose an answer before continuing."
                            return
                        }
                        errorMessage = nil
                        if currentIndex == form.questions.count - 1 { reviewing = true }
                        else { currentIndex += 1 }
                    }
                    .buttonStyle(TronActionButtonStyle(role: .primary, expands: false, accent: .tronAmber))
                    .disabled(submitting || expired)
                }
            }
        }
    }

    private func error(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronError)
            .accessibilityLabel(message)
    }

    private func reset() {
        draft = form.map(ExtensionFormDraft.init(form:)) ?? ExtensionFormDraft()
        currentIndex = 0
        reviewing = false
        submitting = false
        errorMessage = nil
        now = Date()
    }

    private func close() {
        if expired { onLocallyClosed(); dismiss(); return }
        guard !submitting, form?.allowCancel == true else { return }
        respond(value: nil, cancelled: true)
    }

    private func submit() {
        guard canSubmit, let form else { return }
        let answer = draft.answer(for: form)
        guard ExtensionInteractionResponsePolicy.formError(answer, descriptor: form) == nil,
              let data = try? JSONEncoder.gateway.encode(answer),
              let value = try? JSONDecoder.gateway.decode(JSONValue.self, from: data) else { return }
        respond(value: value, cancelled: false)
    }

    private func respond(value: JSONValue?, cancelled: Bool) {
        submitting = true
        errorMessage = nil
        Task {
            do {
                try await model.answerInteraction(interaction, sessionID: sessionID, value: value, cancelled: cancelled)
                onResolved()
                dismiss()
            } catch is CancellationError {
                submitting = false
            } catch let failure as GatewayFailure where failure.code == "not_found" || failure.code == "conflict" {
                onLocallyClosed()
                dismiss()
            } catch {
                submitting = false
                errorMessage = error.localizedDescription
                model.presentError(error)
            }
        }
    }
}
