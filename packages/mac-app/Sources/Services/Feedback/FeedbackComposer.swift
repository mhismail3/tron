import Foundation
import AppKit

/// Mac port of the iOS `FeedbackComposer`. Produces subject + body
/// strings with a log tail from `tron logs --tail 200 --json`, then
/// hands them to `NSSharingService.sharingService(named: .composeEmail)`
/// so the user's default mail app opens a pre-filled draft.
///
/// Redaction is applied to log lines before they land in the mail
/// body (via `SentryRedactor`).
struct FeedbackComposer {
    static let recipient = "feedback@tron.computer"
    static let defaultLogTailLimit = 200

    let appVersion: String
    let buildNumber: String

    private let redactor = SentryRedactor()

    func subject() -> String {
        "Tron feedback — v\(appVersion) (\(buildNumber))"
    }

    /// Formats a JSON-decoded log entry sequence returned by
    /// `tron logs --json`. Each entry must carry `ts`, `category`,
    /// `level`, `message` keys.
    func formatLogs(_ entries: [LogEntry], tailLimit: Int = defaultLogTailLimit) -> String {
        let slice = Array(entries.suffix(tailLimit))
        return slice.map { entry in
            let ts = Self.isoFormatter.string(from: entry.timestamp)
            let message = redactor.redactMessage(entry.message)
            return "\(ts) [\(entry.category)] \(entry.level) \(message)"
        }.joined(separator: "\n")
    }

    func assembleBody(userNotes: String, logs: [LogEntry]) -> String {
        var parts: [String] = []
        if !userNotes.isEmpty {
            parts.append(userNotes)
            parts.append("")
        }
        parts.append("---")
        parts.append("App version: \(appVersion) (\(buildNumber))")
        parts.append("Platform: macOS")
        parts.append("")
        parts.append("Recent logs (last \(Self.defaultLogTailLimit)):")
        if logs.isEmpty {
            parts.append("(no logs captured)")
        } else {
            parts.append(formatLogs(logs))
        }
        return parts.joined(separator: "\n")
    }

    /// Presents the system mail composer via `NSSharingService`. If
    /// `.composeEmail` isn't available on this host (e.g. Mail.app
    /// removed), falls back to opening `mailto:` via `NSWorkspace`.
    @MainActor
    func present(userNotes: String, logs: [LogEntry]) {
        let subject = self.subject()
        let body = assembleBody(userNotes: userNotes, logs: logs)

        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [Self.recipient]
            service.subject = subject
            service.perform(withItems: [body])
            return
        }

        Self.fallbackMailto(subject: subject, body: body)
    }

    /// Fallback mailto URL used when `NSSharingService.composeEmail`
    /// isn't registered. Relies on the default mail handler.
    static func fallbackMailto(subject: String, body: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Helpers

    // `ISO8601DateFormatter` is thread-safe for read-only calls like
    // `string(from:)` but Swift 6 flags it as non-`Sendable`. Matches
    // the iOS side (Sources/Services/Feedback/FeedbackComposer.swift).
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Matches the shape emitted by `tron logs --tail N --json`.
    /// Decoded via `Codable`.
    struct LogEntry: Codable {
        let timestamp: Date
        let category: String
        let level: String
        let message: String

        enum CodingKeys: String, CodingKey {
            case timestamp = "ts"
            case category
            case level
            case message
        }
    }
}
