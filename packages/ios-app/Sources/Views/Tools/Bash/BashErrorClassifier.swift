import Foundation

// MARK: - Bash Error Classifier

enum BashErrorClassifier: ErrorClassifying {
    static func classify(_ message: String) -> ErrorClassification {
        if let exitCode = extractExitCode(from: message) {
            return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Command Failed", code: "EXIT \(exitCode)", suggestion: "The command exited with a non-zero status code.")
        }
        if message.contains("timed out") || message.contains("timeout") {
            return ErrorClassification(icon: "clock.badge.exclamationmark", title: "Command Timed Out", code: nil, suggestion: "The command exceeded its time limit.")
        }
        if message.contains("Permission denied") || message.contains("EACCES") {
            return ErrorClassification(icon: "lock.fill", title: "Permission Denied", code: "EACCES", suggestion: "The process does not have permission to execute this command.")
        }
        return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Command Failed", code: nil, suggestion: "An unexpected error occurred while running the command.")
    }

    private static func extractExitCode(from message: String) -> Int? {
        let pattern = /exit code (\d+)/
        guard let match = message.firstMatch(of: pattern) else { return nil }
        return Int(match.1)
    }
}
