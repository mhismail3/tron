import AppKit
import Foundation

/// Opens a prefilled GitHub issue from the menu bar feedback item.
/// Log capture is best-effort and never routes through Mail.
@MainActor
enum MenuBarFeedbackAction {
    static func present(snapshot: ServerStatusSnapshot, setup: EnvironmentSetup, token: String?) async {
        let logs: String
        guard let host = await setup.resolvedTailscaleHost() else {
            logs = "Log capture failed: \(MenuBarLogReadError.serverUnavailable.message)"
            return await presentIssue(snapshot: snapshot, logs: logs)
        }
        switch await MenuBarLogReader.fetchRecentLogs(
            host: host,
            port: setup.serverPort,
            token: token
        ) {
        case .success(let value):
            logs = value
        case .failure(let error):
            logs = "Log capture failed: \(error.message)"
        }
        await presentIssue(snapshot: snapshot, logs: logs)
    }

    private static func presentIssue(snapshot: ServerStatusSnapshot, logs: String) async {

        let composer = FeedbackIssueComposer(
            appVersion: bundleVersion(key: "TRONCanonicalVersion")
                ?? bundleVersion(key: "CFBundleShortVersionString")
                ?? "0.1.0",
            buildNumber: bundleVersion(key: "CFBundleVersion") ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        let serverDescription = snapshot.feedbackDescription
        guard let plan = composer.openPlan(serverDescription: serverDescription, logs: logs) else {
            await MenuBarNotifier.post(title: "Feedback unavailable", body: "Could not build the GitHub issue URL.")
            return
        }

        if plan.copiedFullBodyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(composer.body(serverDescription: serverDescription, logs: logs), forType: .string)
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

private extension ServerStatusSnapshot {
    var feedbackDescription: String {
        switch state {
        case .checking:
            return "checking"
        case .running(let version, let port):
            return "running on port \(port), version \(version.map { VersionDisplay.label(for: $0) } ?? "?")"
        case .needsRepair(let version, let port, let reason):
            return "installation needs repair on port \(port), version \(version.map { VersionDisplay.label(for: $0) } ?? "?") (\(reason))"
        case .busy(let action):
            return action.rawValue.lowercased()
        case .paused:
            return "paused"
        case .failed(let reason):
            return "failed (\(reason))"
        case .unauthorized:
            return "token missing or rejected"
        }
    }
}
