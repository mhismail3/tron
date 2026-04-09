import SwiftUI

// MARK: - Search Error Classifier

/// Reads the structured `errorClass` field from `tool.details` and maps it
/// to a display classification. Never scans error message text.
///
/// The server (`packages/agent/src/tools/search/search_tool.rs`) populates
/// `details.errorClass` with `"invalid_pattern"` or `"other"`.
enum SearchErrorClassifier {
    static func classify(details: [String: AnyCodable]?) -> ErrorClassification {
        let cls = details?["errorClass"]?.value as? String
        switch cls {
        case "invalid_pattern":
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Invalid Pattern",
                code: nil,
                suggestion: "Check the regex pattern syntax.")
        default:
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Search Failed",
                code: nil,
                suggestion: "An unexpected error occurred during search.")
        }
    }

    /// Raw error message pulled from `details.error`.
    static func errorMessage(from details: [String: AnyCodable]?) -> String? {
        details?["error"]?.value as? String
    }
}
