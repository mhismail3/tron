import SwiftUI
import WebKit

/// WKWebView-based sheet for displaying rendered UI from json-render-server.
/// The web view points directly at the container URL, showing live interactive content.
@available(iOS 26.0, *)
struct RenderUISheetView: View {
    let url: URL
    let title: String?
    let status: RenderUIStatus
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebViewWrapper(url: url)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Text(title ?? "Preview")
                                .font(.headline)
                            statusIndicator
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .rendering:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.tronSuccess)
                .font(.caption)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tronError)
                .font(.caption)
        }
    }
}

/// UIViewRepresentable wrapper for WKWebView.
struct WebViewWrapper: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        if webView.url != url {
            webView.load(request)
        }
    }
}
