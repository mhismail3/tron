import Foundation

/// Delegate protocol for DashboardPoller actions
@MainActor
protocol DashboardPollerDelegate: AnyObject {
    /// Called when the poller needs to pre-warm the connection
    func pollerShouldPreWarm() async

    /// Called when the poller should poll all sessions
    func pollerShouldPollSessions() async

    /// Returns whether there are any processing sessions (affects polling interval)
    func pollerHasProcessingSessions() -> Bool
}

/// Manages dashboard polling lifecycle with background suspension.
/// Handles adaptive polling intervals and battery-saving background suspension.
@MainActor
final class DashboardPoller {

    // MARK: - Properties

    private var pollingTask: Task<Void, Never>?
    private(set) var isActive = false
    private(set) var isInBackground = false

    /// Continuation for resuming polling when app returns to foreground
    private var backgroundContinuation: CheckedContinuation<Void, Never>?

    /// Delegate for polling actions
    weak var delegate: DashboardPollerDelegate?

    // MARK: - Polling Intervals

    /// Interval when sessions are processing (faster updates)
    private let processingInterval: Int = 2

    /// Interval when idle (slower to save battery)
    private let idleInterval: Int = 10

    // MARK: - Initialization

    init() {}

    // MARK: - Lifecycle

    /// Start polling for session processing states.
    /// Call this when dashboard becomes visible.
    func start() {
        guard !isActive else { return }
        isActive = true
        logger.info("Starting dashboard polling for session states")

        pollingTask = Task { [weak self] in
            // Pre-warm connection immediately for faster session entry
            await self?.delegate?.pollerShouldPreWarm()

            while !Task.isCancelled {
                guard let self = self else { break }

                // Truly suspend when in background (saves battery)
                if self.isInBackground {
                    await withCheckedContinuation { continuation in
                        self.backgroundContinuation = continuation
                    }
                    // Resumed by setBackgroundState when app returns to foreground
                    continue
                }

                // Poll sessions
                await self.delegate?.pollerShouldPollSessions()

                // Adaptive polling interval
                let hasProcessing = self.delegate?.pollerHasProcessingSessions() ?? false
                let interval = hasProcessing ? self.processingInterval : self.idleInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Stop polling.
    /// Call this when leaving dashboard.
    func stop() {
        guard isActive else { return }
        isActive = false
        pollingTask?.cancel()
        pollingTask = nil
        logger.info("Stopped dashboard polling")
    }

    /// Set background state to pause/resume polling.
    /// Call this from scene phase changes.
    func setBackgroundState(_ inBackground: Bool) {
        guard isInBackground != inBackground else { return }

        isInBackground = inBackground

        if inBackground {
            logger.info("App entering background - suspending dashboard polling", category: .session)
        } else {
            logger.info("App returning to foreground - resuming dashboard polling", category: .session)
            // Resume any suspended polling task
            backgroundContinuation?.resume()
            backgroundContinuation = nil
        }
    }
}
