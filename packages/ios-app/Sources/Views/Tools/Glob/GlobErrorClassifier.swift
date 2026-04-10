import SwiftUI

// MARK: - Glob Error Classifier

/// Reads the structured `errorClass` field from `tool.details` and maps it
/// to a display classification. Never scans error message text.
///
/// The server (`packages/agent/src/tools/fs/find.rs`) populates
/// `details.errorClass` with `"invalid_pattern"` or `"other"`.
enum GlobErrorClassifier {
    static func classify(details: [String: AnyCodable]?) -> ErrorClassification {
        switch details?.string("errorClass") {
        case "invalid_pattern":
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Invalid Glob Pattern",
                code: nil,
                suggestion: "Check the glob pattern syntax (e.g. `**/*.rs`).")
        default:
            return ErrorClassification(
                icon: "exclamationmark.triangle.fill",
                title: "Find Failed",
                code: nil,
                suggestion: "An unexpected error occurred while searching.")
        }
    }

    /// Raw error message pulled from `details.error`.
    static func errorMessage(from details: [String: AnyCodable]?) -> String? {
        details?.string("error")
    }
}
