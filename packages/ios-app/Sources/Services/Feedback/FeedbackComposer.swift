import Foundation

/// Prepares subject/body text for the iOS "Send feedback" action.
/// Diagnostic data is attached separately as a redacted JSON bundle; this
/// composer only owns the human-readable envelope around that attachment.
///
/// Tests in `Tests/Observability/FeedbackComposerTests.swift` pin
/// the output format so future SDK changes don't silently regress.
struct FeedbackComposer {
    static let recipientInfoPlistKey = "TRONFeedbackEmail"

    let appVersion: String
    let buildNumber: String

    func subject() -> String {
        "Tron feedback — \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))"
    }

    static func configuredRecipient(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        guard let raw = infoDictionary?[recipientInfoPlistKey] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    /// Full body: user notes, environment block, and attachment note.
    func assembleBody(
        userNotes: String,
        attachmentFileName: String?,
        logSummary: DiagnosticsBundleLogSummary
    ) -> String {
        var parts: [String] = []

        if !userNotes.isEmpty {
            parts.append(userNotes)
            parts.append("")
        }

        parts.append(diagnosticsSummarySentence(logSummary))
        parts.append(
            "Included log entries: iOS \(logSummary.iosLogCount), server \(logSummary.serverLogCount)"
        )
        parts.append("")
        parts.append("---")
        parts.append("App version: \(VersionDisplay.label(for: appVersion)) (build \(buildNumber))")
        parts.append("Platform: iOS")
        parts.append("")

        if let attachmentFileName {
            parts.append("Attached diagnostics bundle: \(attachmentFileName)")
        } else {
            parts.append("No diagnostics attachment was generated.")
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func diagnosticsSummarySentence(_ logSummary: DiagnosticsBundleLogSummary) -> String {
        if let earliest = logSummary.earliestLogTimestamp,
           let latest = logSummary.latestLogTimestamp {
            let start = Self.bodyTimestampFormatter.string(from: earliest)
            let end = Self.bodyTimestampFormatter.string(from: latest)
            return "Attached is a JSON diagnostics bundle with recent Tron logs from \(start) to \(end)."
        }
        return "Attached is a JSON diagnostics bundle with recent Tron diagnostics."
    }

    nonisolated(unsafe) private static let bodyTimestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

enum FeedbackDeliveryRoute: Equatable, Sendable {
    case mail(recipient: String)
    case mailUnavailable(message: String)
}

enum FeedbackDeliveryPlanner {
    static let missingRecipientMessage = "Feedback email is not configured."
    static let mailUnavailableMessage = "Mail is not configured on this device. "
        + "Configure a Mail account to send diagnostics."

    static func route(configuredRecipient: String?, canSendMail: Bool) -> FeedbackDeliveryRoute {
        guard let recipient = configuredRecipient?.trimmingCharacters(in: .whitespacesAndNewlines),
              !recipient.isEmpty,
              !recipient.contains("$(")
        else {
            return .mailUnavailable(message: missingRecipientMessage)
        }
        guard canSendMail else {
            return .mailUnavailable(message: mailUnavailableMessage)
        }
        return .mail(recipient: recipient)
    }
}
