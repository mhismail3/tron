import SwiftUI
import UIKit

/// Answered provider choice prompts stay visible so the user can change an
/// earlier answer. The SDK login is a sequential prompt stream, so changing a
/// choice restarts the same method and replays the kept answers, matching each
/// replayed prompt by message and option IDs. A prompt that no longer matches
/// ends the replay and the user continues from there.
struct ProviderAuthSelectionTrail: Equatable {
    struct Step: Equatable {
        let message: String
        let options: [ProviderAuthPromptState.Option]
        let chosenID: String
    }

    private(set) var steps: [Step] = []
    private var replay: [Step] = []

    var isReplaying: Bool { !replay.isEmpty }

    mutating func reset() {
        steps = []
        replay = []
    }

    mutating func record(_ prompt: ProviderAuthPromptState, chosenID: String) {
        guard prompt.kind == .select else { return }
        steps.append(Step(message: prompt.message, options: prompt.options, chosenID: chosenID))
    }

    /// Replaces the answer at `index`, dropping later answers, and queues the
    /// resulting answers for the restarted operation.
    mutating func change(stepAt index: Int, to optionID: String) {
        guard steps.indices.contains(index),
              steps[index].chosenID != optionID,
              steps[index].options.contains(where: { $0.id == optionID }) else { return }
        let changed = Step(message: steps[index].message, options: steps[index].options, chosenID: optionID)
        steps = Array(steps[..<index]) + [changed]
        replay = steps
    }

    /// The queued answer for this prompt, without consuming it.
    func replayAnswer(for prompt: ProviderAuthPromptState) -> String? {
        guard let next = replay.first, matches(next, prompt) else { return nil }
        return next.chosenID
    }

    /// Consumes the queued answer for this prompt. A non-matching prompt ends
    /// the replay and discards the answers it can no longer confirm.
    mutating func consumeReplay(for prompt: ProviderAuthPromptState) -> String? {
        guard let next = replay.first else { return nil }
        guard matches(next, prompt) else {
            steps.removeLast(replay.count)
            replay = []
            return nil
        }
        replay.removeFirst()
        return next.chosenID
    }

    private func matches(_ step: Step, _ prompt: ProviderAuthPromptState) -> Bool {
        prompt.kind == .select
            && prompt.message == step.message
            && prompt.options.map(\.id) == step.options.map(\.id)
    }
}

/// One standard settings group of selectable rows, shared by provider
/// connection methods and provider choice prompts. Every option stays visible;
/// the chosen row carries a checkmark and busy work disables the group.
struct ProviderChoiceGroup: View {
    struct Choice: Identifiable {
        let id: String
        /// Nil for plain prompt options, which use a radio indicator instead.
        let icon: String?
        let title: String
        let subtitle: String?
    }

    let title: String
    let choices: [Choice]
    let selectedID: String?
    let busyID: String?
    let isDisabled: Bool
    let onSelect: (String) -> Void

    var body: some View {
        TronSettingsGroup(title, accent: .tronEmerald) {
            VStack(spacing: 0) {
                ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                    if index > 0 { TronSettingsDivider(accent: .tronEmerald) }
                    Button { if choice.id != selectedID { onSelect(choice.id) } } label: {
                        TronSettingsRow(
                            icon: choice.icon ?? (selectedID == choice.id ? "checkmark.circle.fill" : "circle"),
                            title: choice.title,
                            subtitle: choice.subtitle,
                            accent: .tronEmerald
                        ) {
                            if busyID == choice.id {
                                TronPulseLoadingIndicator(size: 18)
                            } else if choice.icon != nil, selectedID == choice.id {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                    .tronSettingsAccent()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityAddTraits(selectedID == choice.id ? .isSelected : [])
                }
            }
        }
    }
}

/// The visible provider configuration sheet owns this operation-keyed auth
/// content so selecting a credential method never opens an unrelated presenter.
/// Answered choices remain in place above the current step; nothing animates
/// in or out, so each step simply appears below the last.
struct ProviderAuthFlowContent: View {
    @Environment(AppModel.self) private var model
    let trail: ProviderAuthSelectionTrail
    let answeringPromptID: String?
    let answeringOptionID: String?
    let isDisabled: Bool
    let onChoose: (ProviderAuthPromptState, String) -> Void
    let onChangeStep: (Int, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            if let recovered = model.recoveredAuthOperationID,
               model.authEvent?.operationId == recovered || model.authPrompt?.operationId == recovered {
                RecoveredAuthControls(operationID: recovered)
            }
            ForEach(Array(trail.steps.enumerated()), id: \.offset) { index, step in
                ProviderChoiceGroup(
                    title: Self.title(step.message),
                    choices: step.options.map(Self.choice),
                    selectedID: step.chosenID,
                    busyID: nil,
                    isDisabled: isDisabled,
                    onSelect: { onChangeStep(index, $0) }
                )
            }
            if let event = model.authEvent,
               event.kind == .authURL || model.authPrompt == nil {
                AuthEventContent(event: event)
            }
            if let prompt = model.authPrompt, trail.replayAnswer(for: prompt) == nil {
                if prompt.kind == .select {
                    ProviderChoiceGroup(
                        title: Self.title(prompt.message),
                        choices: prompt.options.map(Self.choice),
                        selectedID: nil,
                        busyID: answeringPromptID == prompt.id ? answeringOptionID : nil,
                        isDisabled: isDisabled,
                        onSelect: { onChoose(prompt, $0) }
                    )
                } else {
                    AuthPromptContent(prompt: prompt)
                }
            }
        }
    }

    /// SDK prompt messages are written as terminal questions ("Select …:").
    static func title(_ message: String) -> String {
        var title = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasSuffix(":") { title.removeLast() }
        return title
    }

    private static func choice(_ option: ProviderAuthPromptState.Option) -> ProviderChoiceGroup.Choice {
        ProviderChoiceGroup.Choice(id: option.id, icon: nil, title: option.label, subtitle: option.description)
    }
}

/// Shown when the Gateway recovered an earlier login for this provider instead
/// of starting another. The flow below continues it; Restart and Cancel are
/// explicit because a reconnect or reopened sheet must never restart OAuth.
private struct RecoveredAuthControls: View {
    @Environment(AppModel.self) private var model
    let operationID: String
    @State private var working = false

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: TronSpacing.md) {
                Text("Login already in progress")
                    .font(TronTypography.sheetSectionHeader)
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                TronCaption("Continue below, or restart to get a new login link. Restarting makes the previous authorization link invalid.")
                HStack(spacing: TronSpacing.md) {
                    Button { restart() } label: {
                        Label("Restart Login", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(TronActionButtonStyle())
                    Button { cancel() } label: {
                        Label("Cancel Login", systemImage: "xmark")
                    }
                    .buttonStyle(TronActionButtonStyle(role: .destructive))
                }
                .disabled(working)
            }
        }
    }

    private func restart() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do { try await model.restartAuth(operationID: operationID) }
            catch is CancellationError { }
            catch { model.presentError(error) }
        }
    }

    private func cancel() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            await model.cancelAuth(operationID: operationID)
        }
    }
}

private struct AuthPromptContent: View {
    @Environment(AppModel.self) private var model
    let prompt: AppModel.AuthPromptState
    @State private var value = ""
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            Text(prompt.message)
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Group {
                if prompt.kind == .secret {
                    SecureField(prompt.placeholder ?? "Value", text: $value)
                        .textContentType(.password)
                } else {
                    TextField(prompt.placeholder ?? "Value", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .tronField(monospaced: prompt.kind == .secret)

            TronPrimaryActionButton(
                title: submitting ? "Submitting…" : (prompt.kind == .manualCode ? "Complete Login" : "Save"),
                systemImage: prompt.kind == .manualCode ? "checkmark.shield" : TronSaveActionPresentation.systemImage,
                isBusy: submitting,
                isEnabled: !value.isEmpty && !submitting
            ) { submit(value) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: prompt.id) { _, _ in value = "" }
    }

    private func submit(_ response: String) {
        guard !submitting else { return }
        submitting = true
        Task {
            defer { submitting = false }
            do { try await model.answerAuth(response) }
            catch is CancellationError { }
            catch { model.presentError(error) }
        }
    }
}

private struct AuthEventContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let event: AppModel.AuthEventState
    @State private var browserSession = ProviderOAuthBrowserSession()
    @State private var openingBrowser = false
    @State private var browserActive = false
    @State private var browserError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            switch event.kind {
            case .progress:
                OnboardingCard {
                    TronLoadingState(label: event.message ?? "Waiting for the provider…")
                }
            case .authURL:
                authURLContent
            case .deviceCode:
                deviceCodeContent
            case .info:
                infoContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: event.operationId) { _, _ in resetBrowser() }
        .onChange(of: event.kind) { _, kind in
            if kind != .authURL { resetBrowser() }
        }
        .onDisappear { resetBrowser() }
    }

    private func resetBrowser() {
        browserSession.cancel()
        browserError = nil
        openingBrowser = false
        browserActive = false
    }

    @ViewBuilder private var authURLContent: some View {
        Group {
            if let instructions = event.instructions {
                OnboardingCard {
                    Text(instructions)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let url = event.url {
                Button { openProviderLogin(url) } label: {
                    if openingBrowser {
                        Label("Opening Provider Login…", systemImage: "safari")
                    } else {
                        Label(browserActive ? "Open Provider Login Again" : "Open Provider Login", systemImage: "safari")
                    }
                }
                .buttonStyle(TronActionButtonStyle(role: .primary))
                .disabled(openingBrowser || (event.callbackCapture == nil && !manualTextPromptForEvent))
                if let browserError {
                    TronCaption(browserError)
                        .foregroundStyle(Color.tronError)
                }
                if event.callbackCapture == nil && !manualTextPromptForEvent {
                    TronCaption("Waiting for this login attempt to request a manual callback…")
                }
                if let host = url.host() {
                    if event.callbackCapture == nil && manualTextPromptForEvent {
                        TronCaption("Secure login at \(host). After authorization, return here and paste the callback URL or code.")
                    } else {
                        TronCaption("Secure login at \(host). Tron returns here after authorization.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var deviceCodeContent: some View {
        if let code = event.userCode {
            OnboardingCard {
                VStack(spacing: TronSpacing.md) {
                    Text("Device code")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                    Text(code)
                        .font(TronTypography.code(size: 28, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                    Button { UIPasteboard.general.string = code } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(TronActionButtonStyle())
                }
            }
        }
        if let url = event.verificationURL {
            Button { openURL(url) } label: {
                Label("Open Verification Page", systemImage: "safari")
            }
            .buttonStyle(TronActionButtonStyle(role: .primary))
        }
        if let seconds = event.expiresInSeconds {
            TronCaption("The code expires in approximately \(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s").")
        }
    }

    private var manualTextPromptForEvent: Bool {
        ProviderAuthBrowserPolicy.supportsManualCallback(event: event, prompt: model.authPrompt)
    }

    private func openProviderLogin(_ url: URL) {
        browserError = nil
        guard model.authEvent?.operationId == event.operationId else {
            browserError = "This login attempt has expired. Start provider login again."
            return
        }
        guard let capture = event.callbackCapture else {
            if manualTextPromptForEvent {
                openURL(url)
            } else {
                browserError = "This login needs a secure callback, but none is available yet. Wait for the provider's login prompt or start login again."
            }
            return
        }
        openingBrowser = true
        Task { @MainActor in
            defer { openingBrowser = false }
            do {
                try await browserSession.start(
                    authorizationURL: url,
                    capture: capture,
                    onComplete: { callback in
                        browserActive = false
                        Task { @MainActor in
                            do {
                                try await model.submitBrowserAuthCallback(
                                    callback,
                                    operationID: event.operationId
                                )
                            } catch is CancellationError { }
                            catch { model.presentError(error) }
                        }
                    },
                    onCancel: {
                        browserActive = false
                    },
                    onError: { error in
                        browserActive = false
                        browserError = error.localizedDescription
                    }
                )
                browserActive = true
            } catch is CancellationError { }
            catch { browserError = error.localizedDescription }
        }
    }

    @ViewBuilder private var infoContent: some View {
        if let message = event.message {
            OnboardingCard {
                Text(message)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        ForEach(event.links) { link in
            Button { openURL(link.url) } label: {
                Label(link.label ?? link.url.host() ?? "Open Link", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(TronActionButtonStyle())
        }
    }
}
