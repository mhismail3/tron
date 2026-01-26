import SwiftUI

// MARK: - Error Handler

/// Centralized error handling service
/// Provides consistent error reporting, logging, and user notification
@MainActor
@Observable
final class ErrorHandler {
    // MARK: - Singleton

    static let shared = ErrorHandler()

    // MARK: - State

    /// Current error message to display
    private(set) var currentError: String?

    /// Whether to show the error alert
    private(set) var showError: Bool = false

    /// Error severity for the current error
    private(set) var currentSeverity: ErrorSeverity = .error

    // MARK: - Types

    enum ErrorSeverity {
        /// Critical errors that require user attention
        case error
        /// Warnings that may affect functionality
        case warning
        /// Informational messages
        case info

        var logLevel: LogCategory {
            switch self {
            case .error: return .session
            case .warning: return .session
            case .info: return .session
            }
        }
    }

    // MARK: - Private

    private let logger = TronLogger.shared

    private init() {}

    // MARK: - Public API

    /// Handle a TronError with appropriate logging and user notification
    func handle(_ error: TronError, context: String? = nil) {
        let message: String
        if let context {
            message = "\(context): \(error.localizedDescription)"
        } else {
            message = error.localizedDescription
        }

        // Log the error
        logger.error(message, category: .session)

        // Show to user
        currentError = message
        currentSeverity = .error
        showError = true
    }

    /// Handle any Error with appropriate logging and user notification
    func handle(_ error: Error, context: String? = nil) {
        // Convert to TronError if possible
        if let tronError = error as? TronError {
            handle(tronError, context: context)
            return
        }

        let message: String
        if let context {
            message = "\(context): \(error.localizedDescription)"
        } else {
            message = error.localizedDescription
        }

        logger.error(message, category: .session)
        currentError = message
        currentSeverity = .error
        showError = true
    }

    /// Show an error message directly
    func showError(_ message: String, severity: ErrorSeverity = .error) {
        switch severity {
        case .error:
            logger.error(message, category: .session)
        case .warning:
            logger.warning(message, category: .session)
        case .info:
            logger.info(message, category: .session)
        }

        currentError = message
        currentSeverity = severity
        showError = true
    }

    /// Log an error without showing to user
    func log(_ error: Error, context: String? = nil) {
        let message: String
        if let context {
            message = "\(context): \(error.localizedDescription)"
        } else {
            message = error.localizedDescription
        }
        logger.error(message, category: .session)
    }

    /// Log a warning without showing to user
    func logWarning(_ message: String) {
        logger.warning(message, category: .session)
    }

    /// Clear the current error state
    func clearError() {
        currentError = nil
        showError = false
    }

    /// Wrap an async throwing operation with error handling.
    /// Context is required to ensure meaningful error messages.
    func withErrorHandling<T>(
        context: String,
        operation: () async throws -> T
    ) async -> T? {
        do {
            return try await operation()
        } catch {
            handle(error, context: context)
            return nil
        }
    }

    /// Wrap a throwing operation with error handling (non-async).
    /// Context is required to ensure meaningful error messages.
    func withErrorHandling<T>(
        context: String,
        operation: () throws -> T
    ) -> T? {
        do {
            return try operation()
        } catch {
            handle(error, context: context)
            return nil
        }
    }

    /// Log an error silently without showing to user.
    /// Context is required to ensure meaningful error messages.
    func logError(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        logger.error(message, category: .session)
    }

    /// Log an error silently without showing to user (with category).
    /// Context is required to ensure meaningful error messages.
    func logError(_ error: Error, context: String, category: LogCategory) {
        let message = "\(context): \(error.localizedDescription)"
        logger.error(message, category: category)
    }
}

// MARK: - View Modifier for Error Alerts

struct ErrorAlertModifier: ViewModifier {
    @Bindable var errorHandler: ErrorHandler

    func body(content: Content) -> some View {
        content
            .alert("Error", isPresented: Binding(
                get: { errorHandler.showError },
                set: { if !$0 { errorHandler.clearError() } }
            )) {
                Button("OK") {
                    errorHandler.clearError()
                }
            } message: {
                if let error = errorHandler.currentError {
                    Text(error)
                }
            }
    }
}

extension View {
    /// Attach the global error handler alerts to this view
    func withErrorHandler() -> some View {
        modifier(ErrorAlertModifier(errorHandler: ErrorHandler.shared))
    }
}
