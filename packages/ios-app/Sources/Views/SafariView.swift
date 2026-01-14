import SwiftUI
import UIKit
import SafariServices

/// A SwiftUI wrapper for SFSafariViewController.
/// Used by the OpenBrowser tool to display web content in native Safari.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var entersReaderIfAvailable: Bool = false

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = entersReaderIfAvailable

        let safari = SFSafariViewController(url: url, configuration: config)
        safari.preferredControlTintColor = UIColor(named: "TronEmerald") ?? .systemGreen

        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // SFSafariViewController doesn't support URL updates after creation
    }
}

#Preview {
    SafariView(url: URL(string: "https://apple.com")!)
}
