import SwiftUI
import TronMobileCore
import UIKit.UIGestureRecognizerSubclass

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

    @PresentationState private var draft = ExtensionFormDraft()
    @PresentationState private var activeOtherQuestionIDs: Set<String> = []
    @PresentationState private var currentQuestionIndex = 0
    @PresentationState private var submitting = false
    @PresentationState private var errorMessage: String?
    @PresentationState private var now = Date()
    @PresentationState private var selectedDetent: PresentationDetent = .medium
    @PresentationState private var pendingOtherFocusQuestionID: String?
    @State private var pageDragOffset: CGFloat = 0 // view-local: a rebuilt view has no active finger drag
    @State private var peekQuestionIndex: Int? // view-local: the transient drag neighbour resets with the gesture
    @State private var pageWidth: CGFloat = 0 // view-local: geometry is measured again for the rebuilt view
    @FocusState private var focusedQuestionID: String?

    private var form: ExtensionFormDescriptor? { interaction.form }
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
            ZStack {
                if let form, form.questions.indices.contains(currentQuestionIndex) {
                    ForEach(visiblePageIndices(form), id: \.self) { index in
                        let current = index == currentQuestionIndex
                        questionPage(form.questions[index], index: index, form: form)
                            .offset(x: CGFloat(index - currentQuestionIndex) * pageWidth + pageDragOffset)
                            .allowsHitTesting(current)
                            .accessibilityHidden(!current)
                            .transition(reduceMotion ? .opacity : .identity)
                    }
                } else {
                    Label("This form is unavailable.", systemImage: "exclamationmark.triangle.fill")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronError)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(20)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
            .gesture(QuestionPagePanGesture(isEnabled: (form?.questions.count ?? 0) > 1 && !submitting) { sample in
                if let form { trackPageDrag(sample, form: form) }
            })
            .tronTopBlurSurface()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if form?.allowCancel == true {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive, action: cancel) {
                            Image(systemName: "xmark")
                                .font(TronTypography.buttonSM)
                                .tronToolbarAction(role: .destructive)
                        }
                        .disabled(submitting)
                        .accessibilityLabel("Cancel form")
                    }
                }
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: form?.title ?? "Questions", accent: .tronAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if form != nil {
                        Button(action: submit) {
                            if submitting {
                                TronPulseLoadingIndicator(accent: .tronAmber, size: 14)
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
        .presentationContentInteraction(.scrolls)
        .interactiveDismissDisabled(submitting)
        .onAppear { reset() }
        .onChange(of: ExtensionInteractionScope(interaction)) { _, _ in reset() }
        .onChange(of: currentQuestionIndex) { _, _ in
            focusedQuestionID = nil
            persistDraft()
        }
        .onChange(of: expired) { _, expired in
            if expired { focusedQuestionID = nil }
        }
        .onChange(of: focusedQuestionID) { _, questionID in
            guard questionID != nil else { return }
            withAnimation(reduceMotion ? nil : ChatMotion.extensionSelectionControl) {
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

    private var expiryClockRuns: Bool {
        PresentationClockPolicy.runs(
            surfaceActive: presentationActivity.allowsPresentationPublication,
            sceneActive: scenePhase == .active
        )
    }

    private func runExpiryClock() async {
        guard expiryClockRuns else { return }
        now = Date()
        while !Task.isCancelled {
            guard ExtensionFormExpiryClockPolicy.ticks(deadline: expiry, now: now) else { return }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            now = Date()
        }
    }

    private func questionStatus(_ question: ExtensionFormQuestion, index: Int, form: ExtensionFormDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            pageProgress(question, index: index, form: form)

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
    }

    private func pageProgress(_ question: ExtensionFormQuestion, index: Int, form: ExtensionFormDescriptor) -> some View {
        let instruction = question.multiSelect ? "Select all that apply" : "Select one"
        return HStack(spacing: 10) {
            Text(instruction)
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)

            Spacer(minLength: 8)

            if form.questions.count > 1 {
                HStack(spacing: 5) {
                    ForEach(form.questions.indices, id: \.self) { page in
                        Circle()
                            .fill(page == index ? Color.tronAmber : Color.tronTextMuted.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }

            Text("\(index + 1)/\(form.questions.count)")
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronAmber)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(instruction). Question \(index + 1) of \(form.questions.count)")
    }

    private func otherEditorScrollID(_ question: ExtensionFormQuestion) -> String { "other-editor.\(question.id)" }

    private func questionPage(
        _ question: ExtensionFormQuestion,
        index: Int,
        form: ExtensionFormDescriptor
    ) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                questionStatus(question, index: index, form: form)

                if let context = question.context, !context.isEmpty {
                    TronMarkdownView(
                        text: context,
                        streaming: false,
                        textStyle: ChatSelectableTextStyle(
                            size: TronTypography.sizeBodySM + 0.3,
                            color: .tronTextSecondary
                        ),
                        selectableText: true
                    )
                }

                TronMarkdownView(
                    text: question.question,
                    streaming: false,
                    textStyle: ChatSelectableTextStyle(
                        size: TronTypography.sizeBodyLG,
                        weight: .semibold,
                        color: .tronTextPrimary
                    ),
                    selectableText: true
                )

                VStack(spacing: 10) {
                    ForEach(question.options) { option in
                        optionRow(option, question: question)
                    }
                    if question.allowOther { otherRow(question) }
                }
                Color.clear
                    .frame(height: 0)
                    .id(otherEditorScrollID(question))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityLabel("Question \(index + 1) of \(form.questions.count)")
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            if focusedQuestionID == question.id { revealOtherEditor(question, proxy: proxy, animated: true) }
        }
        .onChange(of: draft.value(for: question.id).other) { _, _ in
            if focusedQuestionID == question.id { revealOtherEditor(question, proxy: proxy, animated: false) }
        }
        }
    }

    private func visiblePageIndices(_ form: ExtensionFormDescriptor) -> [Int] {
        guard let peek = peekQuestionIndex, peek != currentQuestionIndex,
              form.questions.indices.contains(peek) else { return [currentQuestionIndex] }
        return [currentQuestionIndex, peek].sorted()
    }

    private func trackPageDrag(_ sample: QuestionPagePanGesture.Sample, form: ExtensionFormDescriptor) {
        let dx = sample.translation
        let target = currentQuestionIndex + (dx < 0 ? 1 : -1)
        let hasTarget = form.questions.indices.contains(target)
        switch sample.state {
        case .began, .changed:
            guard !reduceMotion else { return }
            if sample.state == .began { focusedQuestionID = nil }
            let peek = hasTarget ? target : nil
            if peekQuestionIndex != peek { peekQuestionIndex = peek }
            pageDragOffset = hasTarget ? dx : dx / 3
        case .ended:
            let projected = dx + sample.velocity * 0.2
            let turns = hasTarget && abs(projected) > max(pageWidth / 3, 60) && (projected < 0) == (dx < 0)
            let animation = ChatMotion.questionPageTurn(reduceMotion: reduceMotion)
            guard turns else { settlePage(animation); return }
            if reduceMotion {
                withAnimation(animation) { currentQuestionIndex = target }
                return
            }
            let previous = currentQuestionIndex
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentQuestionIndex = target
                peekQuestionIndex = previous
                pageDragOffset += CGFloat(target - previous) * pageWidth
            }
            settlePage(animation)
        default:
            settlePage(ChatMotion.questionPageTurn(reduceMotion: reduceMotion))
        }
    }

    private func settlePage(_ animation: Animation) {
        withAnimation(animation, completionCriteria: .removed) {
            pageDragOffset = 0
        } completion: {
            if pageDragOffset == 0 { peekQuestionIndex = nil }
        }
    }

    private func revealOtherEditor(_ question: ExtensionFormQuestion, proxy: ScrollViewProxy, animated: Bool) {
        withAnimation(animated && !reduceMotion ? ChatMotion.extensionSelectionControl : nil) {
            proxy.scrollTo(otherEditorScrollID(question), anchor: .bottom)
        }
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
                    if selected {
                        focusedQuestionID = question.id
                    } else {
                        pendingOtherFocusQuestionID = question.id
                    }
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
                        guard !submitting, !expired else { return }
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
                    .accessibilityLabel("Other response for \(question.header ?? question.question)")
                    .onAppear {
                        guard pendingOtherFocusQuestionID == question.id else { return }
                        pendingOtherFocusQuestionID = nil
                        focusedQuestionID = question.id
                    }
                    .transition(.opacity)
            }
        }
        .background {
            Color.clear
                .tronGlassSurface(accent: selected ? .tronAmber : .tronCyan, tintOpacity: selected ? 0.16 : 0.06)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(reduceMotion ? nil : ChatMotion.extensionSelectionControl, value: selected)
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
        pendingOtherFocusQuestionID = nil
        selectedDetent = .medium
        now = Date()
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
        focusedQuestionID = nil
        submitting = true
        errorMessage = nil
        let expectedToken = presentationSurfaceToken
        Task { @MainActor in
            do {
                try await model.answerInteraction(interaction, sessionID: sessionID, value: value, cancelled: cancelled)
                model.extensionInteractionDrafts.clear(sessionID: sessionID, interaction: interaction)
                guard PresentationPublicationPolicy.allows(ambient: presentationActivity, coordinator: presentationActivityCoordinator, token: expectedToken) else { return }
                if !cancelled { TronHaptics.shared.play(.answerSubmitted) }
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

enum ExtensionFormExpiryClockPolicy {
    static func ticks(deadline: Date?, now: Date) -> Bool {
        guard let deadline else { return false }
        return now < deadline
    }
}

private struct QuestionPagePanGesture: UIGestureRecognizerRepresentable {
    struct Sample {
        let state: UIGestureRecognizer.State
        let translation: CGFloat
        let velocity: CGFloat
    }

    let isEnabled: Bool
    let onAction: (Sample) -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanGestureRecognizer {
        HorizontalPanGestureRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        onAction(Sample(
            state: recognizer.state,
            translation: recognizer.translation(in: recognizer.view).x,
            velocity: recognizer.velocity(in: recognizer.view).x
        ))
    }

    final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
        private var origin: CGPoint?

        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            maximumNumberOfTouches = 1
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if origin == nil { origin = touches.first?.location(in: view) }
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible, let origin, let point = touches.first?.location(in: view) {
                let dx = abs(point.x - origin.x), dy = abs(point.y - origin.y)
                if max(dx, dy) > 8, dx <= dy * 1.2 {
                    state = .failed
                    return
                }
            }
            super.touchesMoved(touches, with: event)
        }

        override func reset() {
            origin = nil
            super.reset()
        }

        override func shouldBeRequiredToFail(by other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer
        }
    }
}
