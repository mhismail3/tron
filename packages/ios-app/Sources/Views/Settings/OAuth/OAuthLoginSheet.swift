import AuthenticationServices
import SwiftUI

// MARK: - OAuth Provider

struct OAuthProvider: Identifiable {
    let id: String
    let displayName: String
    let assetIcon: String
    let accentColor: Color

    /// Google blocks embedded WKWebViews (Error 403: disallowed_useragent).
    /// Use ASWebAuthenticationSession (system browser) instead.
    var usesSystemBrowser: Bool { id == "google" }

    static let anthropic = OAuthProvider(id: "anthropic", displayName: "Anthropic", assetIcon: "IconAnthropic", accentColor: .tronCoral)
    static let openai = OAuthProvider(id: "openai-codex", displayName: "OpenAI", assetIcon: "IconOpenAI", accentColor: .tronSlate)
    static let google = OAuthProvider(id: "google", displayName: "Google", assetIcon: "IconGoogle", accentColor: .tronCyan)

    static func from(_ providerId: String) -> OAuthProvider? {
        switch providerId {
        case "anthropic": return .anthropic
        case "openai-codex": return .openai
        case "google": return .google
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
    @State private var webAuthSession: ASWebAuthenticationSession?
    @State private var loopbackServer: OAuthLoopbackServer?

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

                case .systemBrowser:
                    loadingView("Complete sign in in the browser...")

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
                    Text(provider.displayName)
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(provider.accentColor)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
                if case .label = flowState {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            flowState = .loading
                            Task { await beginOAuthFlow() }
                        } label: {
                            Text("Continue")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(provider.accentColor)
                        }
                        .disabled(accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        .adaptivePresentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    // MARK: - Subviews

    private var labelView: some View {
        VStack(spacing: TronSpacing.section) {
            Image(provider.assetIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(provider.accentColor)
                .frame(width: 36, height: 36)

            Text("Label this account for easy identification")
                .font(TronTypography.body)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, TronSpacing.large)

            VStack(alignment: .leading, spacing: TronSpacing.sm) {
                TextField("e.g. work-laptop", text: $accountLabel)
                    .textFieldStyle(.plain)
                    .font(TronTypography.input)
                    .foregroundStyle(.tronTextPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .multilineTextAlignment(.center)
                    .tronInputPadding()
                    .background {
                        glassFieldBackground
                    }
            }
            .padding(.horizontal, TronSpacing.large)

            Spacer()
        }
        .padding(.top, TronSpacing.large)
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
        VStack(spacing: TronSpacing.section) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 36))
                .foregroundStyle(.tronTextSecondary)

            Text("If sign-in opened in another app, paste the authorization code below")
                .font(TronTypography.body)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, TronSpacing.large)

            TextField("Paste authorization code", text: $manualCode)
                .textFieldStyle(.plain)
                .font(TronTypography.input)
                .foregroundStyle(.tronTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .tronInputPadding()
                .background {
                    glassFieldBackground
                }
                .padding(.horizontal, TronSpacing.large)

            HStack(spacing: 12) {
                Button {
                    if case .manualEntry(let flowId, let url) = flowState {
                        if provider.usesSystemBrowser {
                            flowState = .systemBrowser(flowId: flowId, url: url)
                            startSystemBrowserAuth(flowId: flowId, url: url)
                        } else {
                            flowState = .webView(flowId: flowId, url: url)
                        }
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
        .padding(.top, TronSpacing.large)
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

    @ViewBuilder
    private var glassFieldBackground: some View {
        let shape = RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
        if #available(iOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(
                    .regular.tint(provider.accentColor.opacity(0.12)),
                    in: shape
                )
        } else {
            shape
                .fill(provider.accentColor.opacity(0.12))
        }
    }

    // MARK: - Flow Logic

    private func beginOAuthFlow() async {
        do {
            let response = try await rpcClient.auth.oauthBegin(provider: provider.id)
            guard let url = URL(string: response.authUrl) else {
                flowState = .error("Invalid authorization URL")
                return
            }
            if provider.usesSystemBrowser {
                flowState = .systemBrowser(flowId: response.flowId, url: url)
                startSystemBrowserAuth(flowId: response.flowId, url: url)
            } else {
                flowState = .webView(flowId: response.flowId, url: url)
            }
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

    private static let loopbackScheme = "tron-oauth"

    private func startSystemBrowserAuth(flowId: String, url: URL) {
        // Start a loopback HTTP server so Google's redirect to localhost:45289
        // is caught and bounced to a custom URL scheme that
        // ASWebAuthenticationSession can intercept.
        let server = OAuthLoopbackServer(port: 45289, redirectScheme: Self.loopbackScheme)
        do {
            try server.start()
        } catch {
            flowState = .error("Failed to start local auth server: \(error.localizedDescription)")
            return
        }
        loopbackServer = server

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: Self.loopbackScheme
        ) { [self] callbackURL, error in
            loopbackServer?.stop()
            loopbackServer = nil
            webAuthSession = nil

            if let error = error {
                if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    flowState = .manualEntry(flowId: flowId, url: url)
                    return
                }
                flowState = .error(error.localizedDescription)
                return
            }

            guard let callbackURL = callbackURL else {
                flowState = .error("No callback received")
                return
            }

            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
            if let errorParam = components?.queryItems?.first(where: { $0.name == "error" })?.value {
                let desc = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
                flowState = .error(desc ?? errorParam)
                return
            }

            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                exchangeCode(flowId: flowId, code: code)
            } else {
                flowState = .error("No authorization code in callback URL")
            }
        }

        session.presentationContextProvider = SystemBrowserContextProvider.shared
        webAuthSession = session
        session.start()
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
    case systemBrowser(flowId: String, url: URL)
    case manualEntry(flowId: String, url: URL)
    case exchanging
    case success
    case error(String)
}

// MARK: - System Browser Context

private final class SystemBrowserContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SystemBrowserContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else {
            return ASPresentationAnchor()
        }
        return window
    }
}
