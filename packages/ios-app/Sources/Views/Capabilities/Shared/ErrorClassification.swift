import Foundation

// MARK: - Error Classification

/// Structured error classification rendered from capability metadata or server-provided
/// execution details. The client does not classify by retired built-in names.
struct ErrorClassification {
    let icon: String
    let title: String
    let code: String?
    let suggestion: String
}
