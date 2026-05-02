import SwiftUI

// MARK: - Error Handler

/// Centralized error routing.
///
/// Transient / connection-class errors are routed to `ToastCenter` (non-blocking banner).
/// Fatal / actionable errors are routed to the modal `.alert()` queue via `handleFatal`.
///
/// Silent logging (`log`, `logWarning`, `logError`) is unchanged and does not surface to the user.
@MainActor
@Observable
final class ErrorHandler {

    // MARK: - Singleton

    static let shared = ErrorHandler()

    // MARK: - Modal queue (fatal errors)

    /// Queue of pending fatal error messages shown as modal `.alert()`.
    /// `handle`-style transient errors no longer enter this queue.
    private var errorQueue: [QueuedError] = []

    /// The currently displayed fatal error, if any.
    var currentError: QueuedError? { errorQueue.first }

    /// Whether a fatal error alert should be shown.
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

        fileprivate var toastSeverity: ToastCenter.Severity {
            switch self {
            case .error: return .error
            case .warning: return .warning
            case .info: return .info
            }
        }
    }

    // MARK: - Private

    /// Maximum queued fatal errors to prevent unbounded growth from error storms.
    private let maxQueueSize = 5

    private let logger = TronLogger.shared

    @ObservationIgnored
    private let toastCenter: ToastCenter

    // MARK: - Init

    init(toastCenter: ToastCenter = .shared) {
        self.toastCenter = toastCenter
    }

    // MARK: - Public API — transient (toast)

    /// Handle any transient Error with logging and a non-blocking toast.
    /// Connection-class errors are deduplicated by a shared key so storms collapse.
    func handle(_ error: Error, context: String? = nil) {
        let message = formatMessage(error: error, context: context)
        logger.error(message, category: .session)
        toastCenter.push(
            message,
            severity: .error,
            dedupKey: Self.classifyDedupKey(for: error)
        )
    }

    /// Show an error/warning/info message directly as a non-blocking toast.
    func showError(_ message: String, severity: ErrorSeverity = .error) {
        switch severity {
        case .error: logger.error(message, category: .session)
        case .warning: logger.warning(message, category: .session)
        case .info: logger.info(message, category: .session)
        }

        toastCenter.push(message, severity: severity.toastSeverity)
    }

    // MARK: - Public API — fatal (modal)

    /// Handle a fatal / actionable error with logging and modal `.alert()` display.
    /// Reserved for errors the user must act on (e.g., session not found on server).
    func handleFatal(_ error: Error, context: String? = nil) {
        let message = formatMessage(error: error, context: context)
        logger.error(message, category: .session)
        enqueueFatal(message, severity: .error)
    }

    /// Dismiss the current fatal error and advance to the next queued fatal (if any).
    func clearError() {
        guard !errorQueue.isEmpty else { return }
        errorQueue.removeFirst()
    }

    /// Clear all queued fatal errors.
    func clearAll() {
        errorQueue.removeAll()
    }

    // MARK: - Public API — silent (log only)

    /// Log an error without surfacing it to the user.
    func log(_ error: Error, context: String? = nil) {
        let message = formatMessage(error: error, context: context)
        logger.error(message, category: .session)
    }

    /// Log a warning without surfacing it to the user.
    func logWarning(_ message: String) {
        logger.warning(message, category: .session)
    }

    /// Log an error silently (with default category).
    func logError(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        logger.error(message, category: .session)
    }

    /// Log an error silently (with explicit category).
    func logError(_ error: Error, context: String, category: LogCategory) {
        let message = "\(context): \(error.localizedDescription)"
        logger.error(message, category: category)
    }

    // MARK: - Helpers

    private func formatMessage(error: Error, context: String?) -> String {
        if let context {
            return "\(context): \(error.localizedDescription)"
        }
        return error.localizedDescription
    }

    /// Classify an error into a dedup key for toast suppression. Connection-class errors
    /// all collapse to a single key so storms don't flood the banner stack.
    static func classifyDedupKey(for error: Error) -> String? {
        if case .unauthorized = error as? WebSocketError {
            // Re-pair is a single, distinct CTA — keep it on its own key so the toast doesn't
            // collapse into the transient connection bucket and lose its specific copy.
            return "connection.unauthorized"
        }
        if ConnectionErrorClassifier.isTransientTransport(error) {
            return ConnectionErrorClassifier.transientDedupKey
        }

        return nil
    }

    // MARK: - Private

    private func enqueueFatal(_ message: String, severity: ErrorSeverity) {
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

// MARK: - View Modifier for Fatal Error Alerts

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
    /// Attach the global fatal-error alert modifier to this view.
    /// Transient errors surface via `ToastCenter`; this modifier only handles fatal alerts.
    func withErrorHandler() -> some View {
        modifier(ErrorAlertModifier(errorHandler: ErrorHandler.shared))
    }
}
