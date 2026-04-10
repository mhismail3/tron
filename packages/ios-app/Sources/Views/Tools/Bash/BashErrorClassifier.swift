import Foundation

// MARK: - Bash Error Classifier

/// Maps server-provided structured error metadata into a display classification.
///
/// The server (`packages/agent/src/tools/system/bash.rs::classify_bash_error`)
/// writes a structured `errorClass` string into `tool.details` alongside
/// `exitCode` and `timedOut`. This classifier reads those fields and produces
/// an `ErrorClassification` for the detail sheet. No text scanning is done
/// client-side.
enum BashErrorClassifier {
    /// Classify a bash failure from the server-provided details payload.
    static func classify(details: [String: AnyCodable]?) -> ErrorClassification {
        let errorClass = details?.string("errorClass")
        let exitCode = BashDetailsHelper.exitCode(from: details)

        switch errorClass {
        case "timeout":
            return ErrorClassification(
                icon: "clock.badge.exclamationmark",
                title: "Command Timed Out",
                code: nil,
                suggestion: "The command exceeded its time limit."
            )
        case "permission_denied":
            return ErrorClassification(
                icon: "lock.fill",
                title: "Permission Denied",
                code: "EACCES",
                suggestion: "The process does not have permission to execute this command."
            )
        case "blocked":
            return ErrorClassification(
                icon: "hand.raised.fill",
                title: "Command Blocked",
                code: nil,
                suggestion: "The command matched a destructive pattern and was refused."
            )
        case "interrupted":
            return ErrorClassification(
                icon: "stop.fill",
                title: "Interrupted",
                code: nil,
                suggestion: "The command was interrupted before it could finish."
            )
        default:
            if let code = exitCode, code != 0 {
                return ErrorClassification(
                    icon: "exclamationmark.triangle.fill",
                    title: "Command Failed",
                    code: "EXIT \(code)",
                    suggestion: "The command exited with a non-zero status code."
                )
            }
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Command Failed",
                code: nil,
                suggestion: "An unexpected error occurred while running the command."
            )
        }
    }
}
