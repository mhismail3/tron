import Foundation
import UIKit
import UserNotifications

/// Routes select git-workflow events to user-visible notifications.
///
/// The plan specifies APNs for `worktree.session_finalized` only — other
/// events use in-app banners. When the app is in the foreground, we let the
/// in-app UI surface the event and do nothing here. When the app is in the
/// background, we schedule a local notification so the user sees it when they
/// next look at their device.
@MainActor
final class GitNotificationRouter {
    static let shared = GitNotificationRouter()

    private init() {}

    /// Post a finalize-completed notification for the given session.
    ///
    /// Called by the `worktree.session_finalized` event handler when the app is
    /// not actively displaying this session.
    func postFinalizeCompleted(
        sessionId: String,
        sourceBranch: String,
        targetBranch: String,
        mergeCommit: String?,
        success: Bool
    ) {
        // Only fire APNs when the app is genuinely backgrounded. `.inactive`
        // is transient (Control Center, incoming call, app-switcher preview)
        // and the in-app banner will surface the event the moment we return
        // to `.active` — duplicating it as a notification is spammy.
        guard UIApplication.shared.applicationState == .background else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = success ? "Session merged to \(targetBranch)" : "Finalize failed"
        var body = "\(sourceBranch) → \(targetBranch)"
        if let commit = mergeCommit {
            body += " · \(String(commit.prefix(7)))"
        }
        content.body = body
        content.sound = .default
        content.userInfo = [
            "type": "worktree.session_finalized",
            "sessionId": sessionId,
            "success": success
        ]
        content.threadIdentifier = "tron.git.\(sessionId)"

        let request = UNNotificationRequest(
            identifier: "tron.git.finalize.\(sessionId).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        // Completion executes on an arbitrary background queue. Under Swift
        // 6 actor isolation, touching `@MainActor`-isolated state (our
        // logger) from there is a data race, so we hop back to the main
        // actor explicitly.
        UNUserNotificationCenter.current().add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                TronLogger.shared.error(
                    "GitNotificationRouter failed to post notification: \(error.localizedDescription)",
                    category: .notification
                )
            }
        }
    }
}
