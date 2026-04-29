import Foundation

struct FeedbackIssueOpenPlan: Equatable {
    let url: URL
    let copiedFullBodyToClipboard: Bool
}

/// Pure GitHub issue composer for the Mac menu bar feedback action.
/// Redacts log text before it enters the prefilled issue body.
struct FeedbackIssueComposer {
    static let maxPrefilledURLLength = 7_000
    private static let repoOwner = "mh" + "is" + "mail" + "3"
    private static let repoName = "tron"

    let appVersion: String
    let buildNumber: String
    let osVersion: String

    private let redactor = DiagnosticsRedactor()

    func title() -> String {
        "Mac menu bar feedback - \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))"
    }

    func body(snapshot: ServerStatusSnapshot, logs: String) -> String {
        let redactedLogs = redactor.redactMessage(logs).trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ### Summary


        ### Environment

        - App: \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))
        - macOS: \(osVersion)
        - Server: \(snapshot.feedbackDescription)

        ### Recent logs

        ```text
        \(redactedLogs.isEmpty ? "No logs captured." : redactedLogs)
        ```
        """
    }

    func openPlan(snapshot: ServerStatusSnapshot, logs: String) -> FeedbackIssueOpenPlan? {
        let title = title()
        let fullBody = body(snapshot: snapshot, logs: logs)
        if let fullURL = Self.issueURL(title: title, body: fullBody),
           fullURL.absoluteString.count <= Self.maxPrefilledURLLength {
            return FeedbackIssueOpenPlan(url: fullURL, copiedFullBodyToClipboard: false)
        }

        guard let titleOnlyURL = Self.issueURL(title: title, body: """
        Full feedback details were copied to the clipboard because the prefilled issue body was too large.
        """) else {
            return nil
        }
        return FeedbackIssueOpenPlan(url: titleOnlyURL, copiedFullBodyToClipboard: true)
    }

    static func issueURL(title: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repoOwner)/\(repoName)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url
    }
}

private extension ServerStatusSnapshot {
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
