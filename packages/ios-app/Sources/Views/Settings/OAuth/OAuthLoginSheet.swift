import SwiftUI

struct OAuthLoginSheet: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var flowState: OAuthFlowState = .loading
    @State private var manualCode = ""

    private var rpcClient: RPCClient { dependencies.rpcClient }

    var body: some View {
        NavigationStack {
            Group {
                switch flowState {
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
                    Text("Sign in to Anthropic")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
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
        .task { await beginOAuthFlow() }
    }

    // MARK: - Subviews

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
                .foregroundStyle(.tronEmerald)
            Text("Signed in")
                .font(TronTypography.headline)
                .foregroundStyle(.tronEmerald)
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
                .tint(.tronEmerald)
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
                flowState = .loading
                Task { await beginOAuthFlow() }
            } label: {
                Text("Try Again")
                    .font(TronTypography.button)
            }
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Flow Logic

    private func beginOAuthFlow() async {
        do {
            let response = try await rpcClient.auth.oauthBegin(provider: "anthropic")
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

        Task {
            do {
                _ = try await rpcClient.auth.oauthComplete(
                    flowId: flowId,
                    code: code,
                    label: accountLabel
                )
                flowState = .success
                try? await Task.sleep(for: .seconds(1))
                dismiss()
            } catch {
                flowState = .error(error.localizedDescription)
            }
        }
    }

    private var accountLabel: String {
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
    case loading
    case webView(flowId: String, url: URL)
    case manualEntry(flowId: String, url: URL)
    case exchanging
    case success
    case error(String)
}
