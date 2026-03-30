import SwiftUI

// MARK: - Search Error Classifier

enum SearchErrorClassifier: ErrorClassifying {
    static func classify(_ message: String) -> ErrorClassification {
        if message.contains("Invalid regex") || message.contains("invalid pattern") || message.contains("unterminated") {
            return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Invalid Pattern", code: nil, suggestion: "Check the regex pattern syntax.")
        }
        if message.contains("Permission denied") || message.contains("EACCES") {
            return ErrorClassification(icon: "lock.fill", title: "Permission Denied", code: "EACCES", suggestion: "The process does not have permission to search this location.")
        }
        if message.contains("No such file") || message.contains("ENOENT") || message.contains("not found") {
            return ErrorClassification(icon: "questionmark.folder", title: "Path Not Found", code: "ENOENT", suggestion: "Check that the search path exists.")
        }
        return ErrorClassification(icon: "exclamationmark.triangle.fill", title: "Search Failed", code: nil, suggestion: "An unexpected error occurred during search.")
    }
}
