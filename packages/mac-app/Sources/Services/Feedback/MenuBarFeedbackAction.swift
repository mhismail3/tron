import AppKit
import Foundation

/// Opens a prefilled GitHub issue from the menu bar feedback item.
/// Log capture is best-effort and never routes through Mail.
@MainActor
enum MenuBarFeedbackAction {
    static func present(snapshot: ServerStatusSnapshot) async {
        let logs: String
        switch await MenuBarLogReader.fetchRecentLogs() {
        case .success(let value):
            logs = value
        case .failure(let error):
            logs = "Log capture failed: \(error.message)"
        }

        let composer = FeedbackIssueComposer(
            appVersion: bundleVersion(key: "TRONCanonicalVersion")
                ?? bundleVersion(key: "CFBundleShortVersionString")
                ?? "0.1.0",
            buildNumber: bundleVersion(key: "CFBundleVersion") ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        guard let plan = composer.openPlan(snapshot: snapshot, logs: logs) else {
            await MenuBarNotifier.post(title: "Feedback unavailable", body: "Could not build the GitHub issue URL.")
            return
        }

        if plan.copiedFullBodyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(composer.body(snapshot: snapshot, logs: logs), forType: .string)
            await MenuBarNotifier.post(
                title: "Feedback details copied",
                body: "Paste the copied details into the GitHub issue body."
            )
        }

        NSWorkspace.shared.open(plan.url)
    }

    private static func bundleVersion(key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
}
