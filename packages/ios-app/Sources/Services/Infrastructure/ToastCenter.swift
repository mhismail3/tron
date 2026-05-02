import Foundation

/// Centralized non-blocking notification surface. Replaces modal `.alert()` for transient
/// errors. Modal alerts remain for fatal/actionable errors (see `ErrorHandler.handleFatal`).
///
/// Features:
/// - Severity levels (`info`/`warning`/`error`) with default auto-dismiss durations.
/// - `dedupKey`-based suppression or replacement for app-level state banners.
/// - Overflow trimming with preference for retry toasts (to keep actionable signals visible).
/// - Optional retry handler → toast shows a Retry button and is sticky by default.
///
/// Use `ToastCenter.shared` from production code. Tests create their own instance with an
/// injected `MockAsyncClock`.
@Observable
@MainActor
final class ToastCenter {

    // MARK: - Types

    enum Severity: Sendable, Equatable {
        case info, warning, error

        fileprivate var defaultAutoDismiss: Duration {
            switch self {
            case .info: return .seconds(2)
            case .warning: return .seconds(3)
            case .error: return .seconds(4)
            }
        }
    }

    /// Toast dismissal timing policy.
    enum AutoDismiss: Sendable, Equatable {
        /// Use severity defaults (info 2s / warning 3s / error 4s). Retry toasts are sticky.
        case standard
        /// Never auto-dismiss; user must tap / swipe / dismiss via Retry.
        case sticky
        /// Auto-dismiss after the given duration.
        case after(Duration)
    }

    /// Behavior when pushing a toast whose `dedupKey` is already visible.
    enum DuplicatePolicy: Sendable, Equatable {
        /// Ignore the new push and keep the visible toast unchanged.
        case suppress
        /// Remove the visible toast for that key and show the new one.
        case replace
    }

    struct Toast: Identifiable, Equatable {
        let id: UUID
        let message: String
        let severity: Severity
        let dedupKey: String?
        let hasRetry: Bool

        @ObservationIgnored
        let retryHandler: (@MainActor () async -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool {
            lhs.id == rhs.id
                && lhs.message == rhs.message
                && lhs.severity == rhs.severity
                && lhs.dedupKey == rhs.dedupKey
                && lhs.hasRetry == rhs.hasRetry
        }
    }

    // MARK: - Shared

    static let shared = ToastCenter()

    // MARK: - State

    private(set) var toasts: [Toast] = []

    // MARK: - Dependencies

    @ObservationIgnored
    private let clock: any AsyncClock

    @ObservationIgnored
    private let maxVisible: Int

    @ObservationIgnored
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Init

    init(clock: any AsyncClock = SystemAsyncClock(), maxVisible: Int = 3) {
        self.clock = clock
        self.maxVisible = maxVisible
    }

    // MARK: - Public API

    /// Push a new toast. Duplicate-key pushes are suppressed by default while a toast with that
    /// key is still visible. App-level state banners can opt into replacement when the underlying
    /// state changed and the visible message/action must change with it. Overflow past
    /// `maxVisible` trims the oldest non-retry toast.
    ///
    /// - Parameters:
    ///   - message: User-facing text.
    ///   - severity: Visual/semantic severity. Defaults to `.error`.
    ///   - dedupKey: Optional key used to suppress duplicates.
    ///   - duplicatePolicy: Whether duplicate-key pushes suppress or replace a visible toast.
    ///   - autoDismiss: Dismissal timing policy. `.standard` uses severity defaults
    ///     (info 2s / warning 3s / error 4s) unless `retryHandler` is non-nil (→ sticky).
    ///   - retryHandler: Optional callback for a Retry button. Makes `.standard` mean sticky.
    func push(
        _ message: String,
        severity: Severity = .error,
        dedupKey: String? = nil,
        duplicatePolicy: DuplicatePolicy = .suppress,
        autoDismiss: AutoDismiss = .standard,
        retryHandler: (@MainActor () async -> Void)? = nil
    ) {
        if let key = dedupKey {
            let duplicateIds = toasts
                .filter { $0.dedupKey == key }
                .map(\.id)
            if !duplicateIds.isEmpty {
                switch duplicatePolicy {
                case .suppress:
                    return
                case .replace:
                    for id in duplicateIds {
                        dismiss(id)
                    }
                }
            }
        }

        let resolvedDismiss: Duration? = {
            switch autoDismiss {
            case .sticky: return nil
            case .after(let duration): return duration
            case .standard: return retryHandler == nil ? severity.defaultAutoDismiss : nil
            }
        }()

        let toast = Toast(
            id: UUID(),
            message: message,
            severity: severity,
            dedupKey: dedupKey,
            hasRetry: retryHandler != nil,
            retryHandler: retryHandler
        )

        toasts.append(toast)
        enforceOverflow()

        if let duration = resolvedDismiss {
            scheduleDismiss(id: toast.id, after: duration)
        }
    }

    /// Dismiss a specific toast by ID. Cancels its auto-dismiss timer.
    func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks.removeValue(forKey: id)
        toasts.removeAll { $0.id == id }
    }

    /// Dismiss every visible toast for a deduplication key.
    /// Used by app-level state banners that should clear as soon as the
    /// underlying state recovers.
    func dismiss(dedupKey: String) {
        let ids = toasts
            .filter { $0.dedupKey == dedupKey }
            .map(\.id)
        for id in ids {
            dismiss(id)
        }
    }

    /// Dismiss every toast and cancel every pending auto-dismiss timer.
    func dismissAll() {
        for task in dismissTasks.values { task.cancel() }
        dismissTasks.removeAll()
        toasts.removeAll()
    }

    // MARK: - Test helper

    #if DEBUG
    func clearForTesting() {
        dismissAll()
    }
    #endif

    // MARK: - Private

    private func enforceOverflow() {
        guard toasts.count > maxVisible else { return }
        // Prefer dropping non-retry toasts. Only the oldest is dropped per push.
        if let idx = toasts.firstIndex(where: { !$0.hasRetry }) {
            let removed = toasts.remove(at: idx)
            dismissTasks[removed.id]?.cancel()
            dismissTasks.removeValue(forKey: removed.id)
        } else {
            // All remaining toasts are retry toasts — drop the very oldest anyway.
            let removed = toasts.removeFirst()
            dismissTasks[removed.id]?.cancel()
            dismissTasks.removeValue(forKey: removed.id)
        }
    }

    private func scheduleDismiss(id: UUID, after duration: Duration) {
        let task = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.dismiss(id)
        }
        dismissTasks[id] = task
    }
}
