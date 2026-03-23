import SwiftUI
import WebKit

struct OAuthWebView: UIViewRepresentable {
    let url: URL
    let onCodeReceived: @MainActor (String) -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeReceived: onCodeReceived, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCodeReceived: @MainActor (String) -> Void
        let onError: @MainActor (String) -> Void

        init(onCodeReceived: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void) {
            self.onCodeReceived = onCodeReceived
            self.onError = onError
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  url.host == "console.anthropic.com",
                  url.path.contains("/oauth/code/callback")
            else {
                decisionHandler(.allow)
                return
            }

            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

            // Check for error param (auth denied)
            if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
                let desc = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
                onError(desc ?? error)
                decisionHandler(.cancel)
                return
            }

            if let code = components?.queryItems?.first(where: { $0.name == "code" })?.value {
                onCodeReceived(code)
            } else {
                onError("No authorization code in callback URL")
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError(error.localizedDescription)
        }
    }
}
