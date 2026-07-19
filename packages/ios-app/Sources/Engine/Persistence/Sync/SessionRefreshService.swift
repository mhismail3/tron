import Foundation

/// Central coordinator for `session.list` refresh requests.
///
/// Replaces ~7 scattered `refreshSessionList()` call sites with one coalesced entry point
/// (`request(reason:)`). Rules:
///
/// - **connected + idle** → perform immediately
/// - **connected + inflight** → set `pending = true`; run once more when the inflight completes
/// - **connected + inflight + pending** → drop (pending is a flag, not a counter)
/// - **any non-connected state** → register a hook with `ConnectionManager` under label
///   `"session-refresh"`. Repeated requests replace the hook (coalesce by label).
/// - **`.foreground` reason** carries a short debounce (default 1s) so rapid Control Center /
///   notification-center swipes during foreground return don't each trigger an engine protocol. The
///   connection is re-checked after the debounce because foregrounding may discover a stale
///   socket and start a reconnect while the debounce is sleeping.
@MainActor
final class SessionRefreshService {

    // MARK: - Types

    enum RefreshReason: String, Sendable {
        case foreground
        case connectionEstablished
        case settingsChanged
        case unknownSession
        case serverHint
    }

    // MARK: - Dependencies

    private let performRefresh: @MainActor () async -> Void
    private let isConnectedCheck: @MainActor () -> Bool
    private let clock: any AsyncClock
    private let foregroundDebounce: Duration
    private weak var connectionManager: ConnectionManager?

    // MARK: - Coalescing state

    private var inflightTask: Task<Void, Never>?
    private var pending: Bool = false
    private var foregroundDebounceTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var isStopped = false

    private static let hookLabel = "session-refresh"

    // MARK: - Init

    init(
        performRefresh: @escaping @MainActor () async -> Void,
        isConnected: @escaping @MainActor () -> Bool,
        clock: any AsyncClock = SystemAsyncClock(),
        foregroundDebounce: Duration = .seconds(1),
        connectionManager: ConnectionManager? = nil
    ) {
        self.performRefresh = performRefresh
        self.isConnectedCheck = isConnected
        self.clock = clock
        self.foregroundDebounce = foregroundDebounce
        self.connectionManager = connectionManager
    }

    deinit {
        MainActor.assumeIsolated {
            connectionManager?.cancelHook(label: Self.hookLabel)
            foregroundDebounceTask?.cancel()
            inflightTask?.cancel()
            shutdownTask?.cancel()
        }
    }

    // MARK: - Public API

    /// Attach a `ConnectionManager` so disconnected requests can be queued for reconnect.
    /// Called lazily by `DependencyContainer` after both services exist.
    func attachConnectionManager(_ manager: ConnectionManager) {
        connectionManager?.cancelHook(label: Self.hookLabel)
        self.connectionManager = manager
        if isStopped {
            manager.cancelHook(label: Self.hookLabel)
        }
    }

    /// Request a session list refresh. The actual engine invocation happens asynchronously and may be
    /// coalesced, debounced, or queued depending on current state.
    func request(reason: RefreshReason) {
        guard !isStopped else { return }
        // Any non-foreground request cancels the foreground debounce — its slot will be taken.
        if reason != .foreground {
            foregroundDebounceTask?.cancel()
            foregroundDebounceTask = nil
        }

        // Offline: register hook to fire on reconnect.
        guard isConnectedCheck() else {
            registerReconnectHook()
            return
        }

        // Foreground: debounce.
        if reason == .foreground {
            scheduleForegroundDebounce()
            return
        }

        // Connected + non-foreground → perform now (coalesced via inflight/pending).
        startOrCoalesce()
    }

    /// Defer a failed refresh until a future connected transition.
    ///
    /// Used when an engine protocol began while the transport looked connected but URLSession reported
    /// native socket churn (for example `ECONNABORTED` during foreground return). Waiting for
    /// a future reconnect edge avoids immediately retrying against the same stale socket.
    func deferUntilReconnect() {
        guard !isStopped else { return }
        foregroundDebounceTask?.cancel()
        foregroundDebounceTask = nil
        registerReconnectHook(fireIfAlreadyConnected: false)
    }

    /// Marks the coordinator terminal, cancels pending ownership, and joins
    /// every accepted debounce/inflight handle exactly once.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        isStopped = true
        pending = false
        connectionManager?.cancelHook(label: Self.hookLabel)
        let pendingDebounceTask = foregroundDebounceTask
        let acceptedInflightTask = inflightTask
        pendingDebounceTask?.cancel()
        acceptedInflightTask?.cancel()

        let drain = Task { @MainActor in
            await pendingDebounceTask?.value
            await acceptedInflightTask?.value
        }
        shutdownTask = drain
        await drain.value
    }

    // MARK: - Internals

    private func registerReconnectHook(fireIfAlreadyConnected: Bool = true) {
        guard !isStopped else { return }
        guard let manager = connectionManager else {
            // No manager attached — nothing else we can do; caller will try again next time.
            return
        }
        manager.runOnReconnect(
            label: Self.hookLabel,
            fireIfAlreadyConnected: fireIfAlreadyConnected
        ) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.startOrCoalesce()
        }
    }

    private func scheduleForegroundDebounce() {
        guard !isStopped else { return }
        foregroundDebounceTask?.cancel()
        foregroundDebounceTask = Task { [weak self, clock, foregroundDebounce] in
            do {
                try await clock.sleep(for: foregroundDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, !self.isStopped else { return }
            guard self.isConnectedCheck() else {
                self.registerReconnectHook()
                return
            }
            self.startOrCoalesce()
        }
    }

    private func startOrCoalesce() {
        guard !isStopped else { return }
        if inflightTask != nil {
            pending = true
            return
        }
        spawnInflight()
    }

    private func spawnInflight() {
        guard !isStopped else { return }
        inflightTask = Task { [weak self] in
            guard let self, !self.isStopped else { return }
            await self.performRefresh()
            self.onInflightComplete()
        }
    }

    private func onInflightComplete() {
        inflightTask = nil
        if isStopped {
            pending = false
        } else if pending {
            pending = false
            spawnInflight()
        }
    }
}
