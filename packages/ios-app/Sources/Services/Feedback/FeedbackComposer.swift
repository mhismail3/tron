import Foundation

/// Prepares the subject + body for the iOS "Send feedback" mail
/// composer. All mail formatting lives here — the SwiftUI wrapper
/// around `MFMailComposeViewController` just hands these strings to
/// UIKit.
///
/// Redaction is applied to log lines via `SentryRedactor` so bearer
/// tokens and `/Users/<name>/` paths never leak into a feedback
/// thread.
///
/// Tests in `Tests/Observability/FeedbackComposerTests.swift` pin
/// the output format so future SDK changes don't silently regress.
struct FeedbackComposer {
    static let recipient = "feedback@tron.computer"

    let appVersion: String
    let buildNumber: String

    private let redactor = SentryRedactor()

    /// Default tail size matches plan §F "last 200 lines of logs".
    static let defaultLogTailLimit = 200

    func subject() -> String {
        "Tron feedback — \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))"
    }

    /// Formats a sequence of log entries as one line per entry with
    /// ISO8601 timestamp, category name, level, and redacted message.
    /// Entries are assumed to be newest-last (ascending by time).
    func formatLogs(
        _ entries: [(Date, LogCategory, LogLevel, String)],
        tailLimit: Int = defaultLogTailLimit
    ) -> String {
        let slice = Array(entries.suffix(tailLimit))
        let formatter = Self.isoFormatter

        return slice.map { entry in
            let ts = formatter.string(from: entry.0)
            let cat = entry.1.rawValue
            let level = Self.levelLabel(entry.2)
            let message = redactor.redactMessage(entry.3)
            return "\(ts) [\(cat)] \(level) \(message)"
        }.joined(separator: "\n")
    }

    /// Full body: user notes, environment block, log tail.
    func assembleBody(userNotes: String, logs: [(Date, LogCategory, LogLevel, String)]) -> String {
        var parts: [String] = []

        if !userNotes.isEmpty {
            parts.append(userNotes)
            parts.append("")
        }

        parts.append("---")
        parts.append("App version: \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))")
        parts.append("Platform: iOS")
        parts.append("")

        parts.append("Recent logs (last \(Self.defaultLogTailLimit)):")
        if logs.isEmpty {
            parts.append("(no logs captured)")
        } else {
            parts.append(formatLogs(logs))
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    // ISO8601DateFormatter is thread-safe for `string(from:)` per its
    // documentation, but Swift 6 flags it as non-Sendable. The formatter
    // is never mutated after construction and we only call a read-only
    // method; mark unsafe is the idiomatic workaround used elsewhere in
    // this codebase (mirrors LogEntry's formatter in TronLogger).
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func levelLabel(_ level: LogLevel) -> String {
        switch level {
        case .verbose: return "VERBOSE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .none: return "NONE"
        }
    }
}
