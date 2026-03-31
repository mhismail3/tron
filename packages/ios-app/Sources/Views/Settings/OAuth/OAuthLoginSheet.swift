import SwiftUI

// MARK: - OAuth Provider

struct OAuthProvider: Identifiable {
    let id: String
    let displayName: String
    let accentColor: Color

    static let anthropic = OAuthProvider(id: "anthropic", displayName: "Anthropic", accentColor: .tronCoral)
    static let openai = OAuthProvider(id: "openai-codex", displayName: "OpenAI", accentColor: .tronSlate)

    static func from(_ providerId: String) -> OAuthProvider? {
        switch providerId {
        case "anthropic": return .anthropic
        case "openai-codex": return .openai
        default: return nil
        }
    }
}

// MARK: - OAuth Login Sheet

struct OAuthLoginSheet: View {
    let provider: OAuthProvider

    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var flowState: OAuthFlowState = .label
    @State private var accountLabel: String = defaultAccountLabel
    @State private var manualCode = ""

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        NavigationStack {
            Group {
                switch flowState {
                case .label:
                    labelView

                case .loading:
                    loadingView("Starting sign in...")

                case .webView(_, let url):
                    OAuthWebView(
                        url: url,
                        onCodeReceived: { code in handleCodeReceived(code) },
                        onError: { message in flowState = .error(message) }
                    )

                case .manualEntry:
                    manualEntryView

                case .exchanging:
                    loadingView("Completing sign in...")

                case .success:
                    successView

                case .error(let message):
                    errorView(message)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Sign in to \(provider.displayName)")
                        .font(TronTypography.button)
                        .foregroundStyle(provider.accentColor)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
                if case .webView = flowState {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if case .webView(let flowId, let url) = flowState {
                                flowState = .manualEntry(flowId: flowId, url: url)
                            }
                        } label: {
                            Image(systemName: "text.cursor")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronTextSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var labelView: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Account label")
                .font(TronTypography.subheadline)
                .foregroundStyle(.tronTextSecondary)

            TextField("e.g. moose@iphone", text: $accountLabel)
                .font(TronTypography.codeCaption)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Button {
                flowState = .loading
                Task { await beginOAuthFlow() }
            } label: {
                Text("Continue")
                    .font(TronTypography.button)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(provider.accentColor)
            .disabled(accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer()
        }
    }

    private func loadingView(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text)
                .font(TronTypography.body)
                .foregroundStyle(.tronTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var successView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(provider.accentColor)
            Text("Signed in")
                .font(TronTypography.headline)
                .foregroundStyle(provider.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var manualEntryView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tronTextSecondary)

            Text("If sign-in opened in another app, paste the authorization code below")
                .font(TronTypography.body)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            TextField("Paste authorization code", text: $manualCode)
                .font(TronTypography.codeCaption)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 32)

            HStack(spacing: 12) {
                Button {
                    if case .manualEntry(let flowId, let url) = flowState {
                        flowState = .webView(flowId: flowId, url: url)
                    }
                } label: {
                    Text("Back to Browser")
                        .font(TronTypography.buttonSM)
                }
                .buttonStyle(.bordered)

                Button {
                    submitManualCode()
                } label: {
                    Text("Submit")
                        .font(TronTypography.buttonSM)
                }
                .buttonStyle(.borderedProminent)
                .tint(provider.accentColor)
                .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Spacer()
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tronError)
            Text(message)
                .font(TronTypography.body)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                flowState = .label
            } label: {
                Text("Try Again")
                    .font(TronTypography.button)
            }
            .buttonStyle(.borderedProminent)
            .tint(provider.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Flow Logic

    private func beginOAuthFlow() async {
        do {
            let response = try await rpcClient.auth.oauthBegin(provider: provider.id)
            guard let url = URL(string: response.authUrl) else {
                flowState = .error("Invalid authorization URL")
                return
            }
            flowState = .webView(flowId: response.flowId, url: url)
        } catch {
            flowState = .error(error.localizedDescription)
        }
    }

    private func handleCodeReceived(_ code: String) {
        guard case .webView(let flowId, _) = flowState else { return }
        exchangeCode(flowId: flowId, code: code)
    }

    private func submitManualCode() {
        let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        guard case .manualEntry(let flowId, _) = flowState else { return }
        exchangeCode(flowId: flowId, code: code)
    }

    private func exchangeCode(flowId: String, code: String) {
        flowState = .exchanging
        let label = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                _ = try await rpcClient.auth.oauthComplete(
                    flowId: flowId,
                    code: code,
                    label: label
                )
                flowState = .success
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            } catch {
                flowState = .error(error.localizedDescription)
            }
        }
    }

    private static var defaultAccountLabel: String {
        let user = NSUserName().isEmpty ? "user" : NSUserName()
        let device = UIDevice.current.name
            .lowercased()
            .components(separatedBy: .whitespaces)
            .last ?? "device"
        return "\(user)@\(device)"
    }
}

// MARK: - Flow State

private enum OAuthFlowState {
    case label
    case loading
    case webView(flowId: String, url: URL)
    case manualEntry(flowId: String, url: URL)
    case exchanging
    case success
    case error(String)
}
