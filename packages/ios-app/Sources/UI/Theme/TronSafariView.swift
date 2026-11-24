import SafariServices
import SwiftUI

struct TronSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = UIColor(Color.tronPrimary)
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        controller.preferredControlTintColor = UIColor(Color.tronPrimary)
    }
}
