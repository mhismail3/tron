import SwiftUI
import MessageUI

struct FeedbackMailAttachment: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let fileName: String
}

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
    let attachments: [FeedbackMailAttachment]
    let onDismiss: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        for attachment in attachments {
            controller.addAttachmentData(
                attachment.data,
                mimeType: attachment.mimeType,
                fileName: attachment.fileName
            )
        }
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
/// alert when `canSendMail()` is false. Returns `true` if the device
/// has a configured mail account.
enum FeedbackMailAvailability {
    @MainActor
    static func canSendMail() -> Bool {
        MFMailComposeViewController.canSendMail()
    }
}
