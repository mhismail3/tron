import SwiftUI
import UIKit

/// The visible provider configuration sheet owns this operation-keyed auth
/// content so selecting a credential method never opens an unrelated presenter.
struct ProviderAuthFlowContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let prompt = model.authPrompt {
                AuthPromptContent(prompt: prompt)
            } else if let event = model.authEvent {
                AuthEventContent(event: event)
            } else {
                TronLoadingState(label: "Finishing provider login…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
                                .foregroundStyle(Color.tronEmerald)
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
                    title: submitting ? "Saving…" : "Save",
                    systemImage: "square.and.arrow.down",
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
    @Environment(\.openURL) private var openURL
    let event: AppModel.AuthEventState

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
    }

    @ViewBuilder private var authURLContent: some View {
        if let instructions = event.instructions {
            OnboardingCard {
                Text(instructions)
                    .font(TronTypography.body)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let url = event.url {
            Button { openURL(url) } label: {
                Label("Open Provider Login", systemImage: "safari")
            }
            .buttonStyle(TronActionButtonStyle(role: .primary))
            Text(url.absoluteString)
                .font(TronTypography.codeContent)
                .foregroundStyle(Color.tronTextSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
