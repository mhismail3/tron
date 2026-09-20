import SwiftUI

/// Native projection of one bounded semantic form. The Gateway owns the
/// interaction and lifecycle; this view edits a bounded device-local, ID-keyed draft.
struct ExtensionFormSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationActivityCoordinator) private var presentationActivityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var presentationSurfaceToken
    let sessionID: String
    let interaction: ExtensionInteraction
    let onResolved: () -> Void
    let onLocallyClosed: () -> Void

    @State private var draft = ExtensionFormDraft()
    @State private var activeOtherQuestionIDs: Set<String> = []
    @State private var currentQuestionIndex = 0
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var now = Date()
    @State private var selectedDetent: PresentationDetent = .medium
    @FocusState private var focusedQuestionID: String?

    private var form: ExtensionFormDescriptor? { interaction.form }
    private var currentQuestion: ExtensionFormQuestion? {
        guard let form, form.questions.indices.contains(currentQuestionIndex) else { return nil }
        return form.questions[currentQuestionIndex]
    }
    private var expiry: Date? { interaction.expiresAt.flatMap(GatewayTimestamp.parse) }
    private var expired: Bool { expiry.map { now >= $0 } ?? false }
    private var responseValidationMessage: String? {
        guard let form, draftIsComplete(form) else { return nil }
        return ExtensionInteractionResponsePolicy.formError(draft.answer(for: form), descriptor: form)
    }
    private var canSubmit: Bool {
        guard !expired, !submitting, let form else { return false }
        return draftIsComplete(form) && responseValidationMessage == nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let form {
                    fixedQuestionStatus(form)

                    TabView(selection: $currentQuestionIndex) {
                        ForEach(Array(form.questions.enumerated()), id: \.element.id) { index, question in
                            questionPage(question, index: index)
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.snappy(duration: 0.24), value: currentQuestionIndex)
                } else {
                    Label("This form is unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronError)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                }
            }
            .tronTopBlurSurface()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                if form?.allowCancel == true {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: cancel)
                            .font(TronTypography.buttonSM)
                            .tronToolbarAction(accent: .tronError)
                            .disabled(submitting)
                            .accessibilityLabel("Cancel form")
                    }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: form?.title ?? "Questions", accent: .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                    }
                    .tronToolbarAction(accent: .tronTextMuted)
                    .disabled(submitting)
                    .accessibilityLabel("Close form and keep answers")
                }
                // Local dismissal keeps the draft; Cancel on the opposite side
                // resolves the domain request. Keep Close distinct from Send.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    if form != nil {
                        Button(action: submit) {
                            if submitting {
                                ProgressView()
                                    .scaleEffect(0.72)
                                    .tint(Color.tronAmber)
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(TronTypography.buttonSM)
                            }
                        }
                        .tronToolbarAction(accent: .tronAmber)
                        .tint(Color.tronAmber)
                        .disabled(!canSubmit)
                        .accessibilityLabel("Submit all answers")
                    }
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .onAppear { reset() }
        .onChange(of: ExtensionInteractionScope(interaction)) { _, _ in reset() }
        .onChange(of: currentQuestionIndex) { _, _ in
            focusedQuestionID = nil
            persistDraft()
        }
        .onChange(of: focusedQuestionID) { _, questionID in
            guard questionID != nil else { return }
            // Give the paged form room before keyboard avoidance compresses
            // its medium-height viewport. UIKit still owns editor focus.
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                selectedDetent = .large
            }
        }
        .task(id: PresentationActivityTaskID(
            source: ExtensionInteractionScope(interaction),
            presentationActive: expiryClockRuns
        )) {
            await runExpiryClock()
        }
    }

    /// The visible countdown is a self-updating relative text; this clock only
    /// drives the one-way expiry transition that disables submission. It must
    /// therefore never tick without a future deadline, and must stop once the
    /// form has expired.
    private var expiryClockRuns: Bool {
        PresentationClockPolicy.runs(
            surfaceActive: presentationActivity.allowsPresentationPublication,
            sceneActive: scenePhase == .active
        )
    }

    private func runExpiryClock() async {
        guard expiryClockRuns else { return }
        // Recompute the wall clock on every activation so a covered, suspended,
        // or backgrounded form never depends on a timer having fired.
        now = Date()
        while !Task.isCancelled {
            guard ExtensionFormExpiryClockPolicy.ticks(deadline: expiry, now: now) else { return }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            now = Date()
        }
    }

    private func fixedQuestionStatus(_ form: ExtensionFormDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            pageProgress(form)

            if let expiry {
                Label(
                    expired ? "This form expired. You can close it." : "Expires \(expiry, style: .relative)",
                    systemImage: expired ? "clock.badge.exclamationmark" : "clock"
                )
                .font(TronTypography.bodySM)
                .foregroundStyle(expired ? Color.tronError : Color.tronTextMuted)
            }
            if let errorMessage { error(errorMessage) }
            if let responseValidationMessage { error(responseValidationMessage) }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func pageProgress(_ form: ExtensionFormDescriptor) -> some View {
        HStack(spacing: 10) {
            Text(currentQuestion?.multiSelect == true ? "Select all that apply" : "Select one")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)

            Spacer(minLength: 8)

            if form.questions.count > 1 {
                HStack(spacing: 5) {
                    ForEach(form.questions.indices, id: \.self) { page in
                        Circle()
                            .fill(page == currentQuestionIndex ? Color.tronAmber : Color.tronTextMuted.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }

            Text("\(currentQuestionIndex + 1)/\(form.questions.count)")
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronAmber)
        }
        .animation(.easeInOut(duration: 0.18), value: currentQuestionIndex)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(currentQuestion?.multiSelect == true ? "Select all that apply" : "Select one"). Question \(currentQuestionIndex + 1) of \(form.questions.count)")
    }

    private func questionPage(_ question: ExtensionFormQuestion, index: Int) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let context = question.context, !context.isEmpty {
                    Text(context)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM + 0.3))
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(question.question)
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    ForEach(question.options) { option in
                        optionRow(option, question: question)
                    }
                    if question.allowOther { otherRow(question) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityLabel("Question \(index + 1) of \(form?.questions.count ?? 1)")
    }

    private func optionRow(_ option: ExtensionFormOption, question: ExtensionFormQuestion) -> some View {
        let selected = draft.value(for: question.id).optionIDs.contains(option.id)
        return Button {
            guard !submitting, !expired else { return }
            draft.toggle(optionID: option.id, for: question)
            if !question.multiSelect {
                activeOtherQuestionIDs.remove(question.id)
                focusedQuestionID = nil
            }
            errorMessage = nil
            persistDraft()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectionIcon(selected: selected, multiSelect: question.multiSelect))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(selected ? Color.tronAmber : Color.tronTextMuted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM + 0.3))
                            .foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitting || expired)
        .tronGlassSurface(accent: selected ? .tronAmber : .tronCyan, tintOpacity: selected ? 0.16 : 0.06)
        .accessibilityLabel(option.description.map { "\(option.label), \($0)" } ?? option.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func otherRow(_ question: ExtensionFormQuestion) -> some View {
        let selected = activeOtherQuestionIDs.contains(question.id)
            || !draft.value(for: question.id).other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                guard !submitting, !expired else { return }
                if question.multiSelect && selected {
                    activeOtherQuestionIDs.remove(question.id)
                    draft.clearOther(for: question)
                    focusedQuestionID = nil
                } else {
                    activeOtherQuestionIDs.insert(question.id)
                    draft.activateOther(for: question)
                    // Selecting Other reveals an editor; only tapping the
                    // mounted editor requests the keyboard and larger detent.
                }
                errorMessage = nil
                persistDraft()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectionIcon(selected: selected, multiSelect: question.multiSelect))
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(selected ? Color.tronAmber : Color.tronTextMuted)
                    Text("Other")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                .padding(.horizontal, 14)
                .padding(.bottom, selected ? 0 : 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(submitting || expired)
            .accessibilityValue(selected ? "Selected" : "Not selected")
            .accessibilityAddTraits(selected ? .isSelected : [])

            if selected {
                TextEditor(text: Binding(
                    get: { draft.value(for: question.id).other },
                    set: { text in
                        // A fading-out editor may finish an IME/autocorrection
                        // callback after deselection. It cannot restore Other.
                        guard activeOtherQuestionIDs.contains(question.id)
                            || !draft.value(for: question.id).other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        if draft.setOther(text, for: question) {
                            errorMessage = nil
                            persistDraft()
                        } else {
                            errorMessage = "Other responses are limited to 32 KiB of UTF-8 text."
                        }
                    }
                ))
                    .frame(minHeight: 160)
                    .focused($focusedQuestionID, equals: question.id)
                    .overlay(alignment: .topLeading) {
                        if draft.value(for: question.id).other.isEmpty {
                            Text("Type your answer")
                                .foregroundStyle(Color.tronTextMuted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .tronTextEditor()
                    .tronSettingsVisualTheme(accent: .tronAmber)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .disabled(submitting || expired)
                    .accessibilityLabel("Other response for \(question.header ?? question.question)")
                    .transition(.opacity)
            }
        }
        .background {
            // A composite card has two independent controls. Applying the
            // glass content shape to their parent enlarges Other's tap target
            // over the editor; selection accessibility belongs to the button.
            Color.clear
                .tronGlassSurface(accent: selected ? .tronAmber : .tronCyan, tintOpacity: selected ? 0.16 : 0.06)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: selected)
        .accessibilityElement(children: .contain)
    }

    private func selectionIcon(selected: Bool, multiSelect: Bool) -> String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "checkmark.circle.fill" : "circle"
    }

    private func draftIsComplete(_ form: ExtensionFormDescriptor) -> Bool {
        form.questions.allSatisfy { question in
            guard draft.isAnswered(question) else { return false }
            if activeOtherQuestionIDs.contains(question.id) {
                return !draft.value(for: question.id).other
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
    }

    private func error(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(TronTypography.bodySM)
            .foregroundStyle(Color.tronError)
            .accessibilityLabel(message)
    }

    private func reset() {
        if let form,
           let stored = model.extensionInteractionDrafts.formDraft(sessionID: sessionID, interaction: interaction) {
            draft = ExtensionFormDraft(restoring: stored.draft, for: form)
            activeOtherQuestionIDs = stored.activeOtherQuestionIDs
            currentQuestionIndex = min(stored.currentQuestionIndex, form.questions.count - 1)
        } else {
            draft = form.map(ExtensionFormDraft.init(form:)) ?? ExtensionFormDraft()
            activeOtherQuestionIDs = []
            currentQuestionIndex = 0
        }
        submitting = false
        errorMessage = nil
        focusedQuestionID = nil
        selectedDetent = .medium
        now = Date()
    }

    private func close() {
        guard !submitting else { return }
        persistDraft()
        onLocallyClosed()
        dismiss()
    }

    private func cancel() {
        guard !submitting, form?.allowCancel == true else { return }
        respond(value: nil, cancelled: true)
    }

    private func persistDraft() {
        guard let form, form.questions.indices.contains(currentQuestionIndex) else { return }
        model.extensionInteractionDrafts.saveForm(
            StoredExtensionFormDraft(
                draft: draft,
                activeOtherQuestionIDs: activeOtherQuestionIDs,
                currentQuestionIndex: currentQuestionIndex
            ),
            sessionID: sessionID,
            interaction: interaction
        )
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
        let expectedToken = presentationSurfaceToken
        Task { @MainActor in
            do {
                // Accepted domain mutation remains owned by SessionMutationService
                // even when this sheet disappears. Only presentation effects are
                // fenced: the old result must not dismiss or suppress a successor
                // sheet that reuses the interaction ID with a new scope.
                try await model.answerInteraction(interaction, sessionID: sessionID, value: value, cancelled: cancelled)
                model.extensionInteractionDrafts.clear(sessionID: sessionID, interaction: interaction)
                guard PresentationPublicationPolicy.allows(ambient: presentationActivity, coordinator: presentationActivityCoordinator, token: expectedToken) else { return }
                onResolved()
                dismiss()
            } catch is CancellationError {
                guard PresentationPublicationPolicy.allows(ambient: presentationActivity, coordinator: presentationActivityCoordinator, token: expectedToken) else { return }
                submitting = false
            } catch let failure as GatewayFailure where failure.code == "not_found" || failure.code == "conflict" {
                model.extensionInteractionDrafts.clear(sessionID: sessionID, interaction: interaction)
                guard PresentationPublicationPolicy.allows(ambient: presentationActivity, coordinator: presentationActivityCoordinator, token: expectedToken) else { return }
                onLocallyClosed()
                dismiss()
            } catch {
                guard PresentationPublicationPolicy.allows(ambient: presentationActivity, coordinator: presentationActivityCoordinator, token: expectedToken) else { return }
                submitting = false
                errorMessage = error.localizedDescription
                model.presentError(error)
            }
        }
    }
}

/// The only clock demand this sheet has is the one-way expiry transition that
/// disables submission; the visible countdown is a self-updating relative text.
/// A missing deadline therefore needs no timer at all, and an expired form needs
/// no further ticks.
enum ExtensionFormExpiryClockPolicy {
    static func ticks(deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now < deadline
    }
}
