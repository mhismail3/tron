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

    func body(serverDescription: String, logs: String) -> String {
        let redactedLogs = redactor.redactMessage(logs).trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ### Summary


        ### Environment

        - App: \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))
        - macOS: \(osVersion)
        - Server: \(serverDescription)

        ### Recent logs

        ```text
        \(redactedLogs.isEmpty ? "No logs captured." : redactedLogs)
        ```
        """
    }

    func openPlan(serverDescription: String, logs: String) -> FeedbackIssueOpenPlan? {
        let title = title()
        let fullBody = body(serverDescription: serverDescription, logs: logs)
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
