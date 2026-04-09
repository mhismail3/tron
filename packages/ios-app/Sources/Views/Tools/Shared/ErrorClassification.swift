import Foundation

// MARK: - Error Classification

/// Structured error classification returned by tool-specific error classifiers.
///
/// Classifiers read from server-provided `tool.details.errorClass` — they
/// never scan error message text. See `BashErrorClassifier`,
/// `WebFetchDetailParser`, `WebSearchDetailParser`, `SearchErrorClassifier`,
/// and `GlobErrorClassifier`.
struct ErrorClassification {
    let icon: String
    let title: String
    let code: String?
    let suggestion: String
}
