import SwiftUI
import MessageUI

/// UIViewControllerRepresentable wrapping `MFMailComposeViewController`
/// so the SwiftUI settings page can present it in a `.sheet(...)`.
///
/// The actual subject/body/recipient composition happens in
/// `FeedbackComposer` — this view only forwards the prepared strings
/// and surfaces the composer's result via `onDismiss`.
struct FeedbackMailView: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let recipient: String
    let onDismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        controller.mailComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {
        // No-op — the controller is built once in `makeUIViewController`.
    }

    @MainActor
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onDismiss: @MainActor () -> Void
        init(onDismiss: @escaping @MainActor () -> Void) {
            self.onDismiss = onDismiss
        }
        nonisolated func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            // Delegate callbacks from MFMailComposeViewController land
            // on the main thread; the `nonisolated` annotation satisfies
            // ObjC bridging while the body hops back to MainActor for
            // the UIKit dismissal + dismissal callback.
            Task { @MainActor [weak self] in
                controller.dismiss(animated: true) {
                    self?.onDismiss()
                }
            }
        }
    }
}

/// Helper so the Settings page can display a "Mail isn't configured"
/// fallback when `canSendMail()` is false. Returns `true` if the
/// device has a configured mail account.
enum FeedbackMailAvailability {
    static func canSendMail() -> Bool {
        MFMailComposeViewController.canSendMail()
    }
}
