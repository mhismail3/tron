import Foundation

// MARK: - Error Classification

/// Structured error classification returned by tool-specific error classifiers.
struct ErrorClassification {
    let icon: String
    let title: String
    let code: String?
    let suggestion: String
}

/// Protocol for tool-specific error classifiers.
/// Each tool's detail parser conforms with its own domain-specific matching logic.
protocol ErrorClassifying {
    static func classify(_ message: String) -> ErrorClassification
}
