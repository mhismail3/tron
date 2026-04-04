import SwiftUI

// MARK: - Error Handler

/// Centralized error handling service.
/// Queues errors so rapid successive failures are not silently overwritten.
@MainActor
@Observable
final class ErrorHandler {
    // MARK: - Singleton

    static let shared = ErrorHandler()

    // MARK: - State

    /// Queue of pending error messages (FIFO). The first entry is the one currently displayed.
    private var errorQueue: [QueuedError] = []

    /// The currently displayed error, if any.
    var currentError: QueuedError? { errorQueue.first }

    /// Whether an error alert should be shown.
    var showError: Bool { !errorQueue.isEmpty }

    // MARK: - Types

    struct QueuedError: Equatable {
        let message: String
        let severity: ErrorSeverity
    }

    enum ErrorSeverity: Equatable {
        case error
        case warning
        case info
    }

    // MARK: - Private

    /// Maximum queued errors to prevent unbounded growth from error storms.
    private let maxQueueSize = 5

    private let logger = TronLogger.shared

    private init() {}

    // MARK: - Public API

    /// Handle any Error with logging and user notification.
    /// Queued — does not overwrite a currently displayed error.
    func handle(_ error: Error, context: String? = nil) {
        let message: String
        if let context {
            message = "\(context): \(error.localizedDescription)"
        } else {
            message = error.localizedDescription
        }

        logger.error(message, category: .session)
        enqueue(message, severity: .error)
    }

    /// Show an error/warning/info message directly.
    func showError(_ message: String, severity: ErrorSeverity = .error) {
        switch severity {
        case .error:
            logger.error(message, category: .session)
        case .warning:
            logger.warning(message, category: .session)
        case .info:
            logger.info(message, category: .session)
        }

        enqueue(message, severity: severity)
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

    /// Dismiss the current error and advance to the next queued error (if any).
    func clearError() {
        guard !errorQueue.isEmpty else { return }
        errorQueue.removeFirst()
    }

    /// Clear all queued errors.
    func clearAll() {
        errorQueue.removeAll()
    }

    /// Log an error silently without showing to user.
    func logError(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        logger.error(message, category: .session)
    }

    /// Log an error silently without showing to user (with category).
    func logError(_ error: Error, context: String, category: LogCategory) {
        let message = "\(context): \(error.localizedDescription)"
        logger.error(message, category: category)
    }

    // MARK: - Private

    private func enqueue(_ message: String, severity: ErrorSeverity) {
        // Deduplicate: don't add if the same message is already in the queue.
        guard !errorQueue.contains(where: { $0.message == message }) else { return }

        if errorQueue.count >= maxQueueSize {
            // Drop the oldest non-displayed error to make room.
            if errorQueue.count > 1 {
                errorQueue.remove(at: 1)
            }
        }

        errorQueue.append(QueuedError(message: message, severity: severity))
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
                    Text(error.message)
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
