import AppKit
import Foundation

/// Opens a prefilled GitHub issue from the menu bar feedback item.
/// Log capture is best-effort and never routes through Mail.
@MainActor
enum MenuBarFeedbackAction {
    static func present(
        snapshot: GatewayStatusSnapshot,
        dependencies: GatewayDependencies
    ) async {
        let logs: String
        if case .signedIn(let host) = await dependencies.requirements.tailscaleStatus() {
            switch await MenuBarLogReader.fetchRecentLogs(
                host: host,
                port: dependencies.configuration.gatewayPort,
                token: dependencies.credentials.bearerToken()
            ) {
            case .success(let value):
                logs = value
            case .failure(let error):
                logs = "Log capture failed: \(error.message)"
            }
        } else {
            logs = "Log capture failed: Tailscale is unavailable."
        }

        let composer = FeedbackIssueComposer(
            appVersion: bundleVersion(key: "TRONCanonicalVersion")
                ?? bundleVersion(key: "CFBundleShortVersionString")
                ?? "0.1.0",
            buildNumber: bundleVersion(key: "CFBundleVersion") ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )

        let gatewayDescription = snapshot.feedbackDescription
        guard let plan = composer.openPlan(gatewayDescription: gatewayDescription, logs: logs) else {
            await MenuBarNotifier.post(title: "Feedback unavailable", body: "Could not build the GitHub issue URL.")
            return
        }

        if plan.copiedFullBodyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(composer.body(gatewayDescription: gatewayDescription, logs: logs), forType: .string)
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

private extension GatewayStatusSnapshot {
    var feedbackDescription: String {
        switch state {
        case .checking:
            return "checking"
        case .running(let version, let port):
            return "running on port \(port), version \(version.map { VersionDisplay.label(for: $0) } ?? "?")"
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
