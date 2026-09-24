import SwiftUI
import UIKit

/// The visible provider configuration sheet owns this operation-keyed auth
/// content so selecting a credential method never opens an unrelated presenter.
struct ProviderAuthFlowContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var contentKey: String {
        "\(model.authEvent?.kind.rawValue ?? ""):\(model.authEvent?.operationId ?? ""):\(model.authPrompt?.id ?? "")"
    }

    private var revealTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.section) {
            if let recovered = model.recoveredAuthOperationID,
               model.authEvent?.operationId == recovered || model.authPrompt?.operationId == recovered {
                RecoveredAuthControls(operationID: recovered)
                    .transition(revealTransition)
            }
            if let event = model.authEvent,
               event.kind == .authURL || model.authPrompt == nil {
                AuthEventContent(event: event)
                    .transition(revealTransition)
            }
            if let prompt = model.authPrompt {
                AuthPromptContent(prompt: prompt)
                    .transition(revealTransition)
            }
            if model.authPrompt == nil && model.authEvent == nil {
                TronLoadingState(label: "Finishing provider login…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(revealTransition)
            }
        }
        .animation(
            reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.24),
            value: contentKey
        )
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
            do { try await model.restartAuth() }
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

            if prompt.kind == .select {
                ForEach(prompt.options) { option in
                    Button {
                        submit(option.id)
                    } label: {
                        HStack(alignment: .top, spacing: TronSpacing.md) {
                            Image(systemName: "chevron.right.circle")
                                .tronSettingsAccent()
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                                Text(option.label)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                    .foregroundStyle(Color.tronTextPrimary)
                                if let description = option.description {
                                    Text(description)
                                        .font(TronTypography.bodySM)
                                        .foregroundStyle(Color.tronTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(TronActionButtonStyle())
                    .disabled(submitting)
                }
            } else {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .transition(
                            reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
                        )
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
        .animation(
            reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.2),
            value: browserError
        )
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
