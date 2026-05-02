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
///   notification-center swipes during foreground return don't each trigger an RPC. The
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

    // MARK: - Public API

    /// Attach a `ConnectionManager` so disconnected requests can be queued for reconnect.
    /// Called lazily by `DependencyContainer` after both services exist.
    func attachConnectionManager(_ manager: ConnectionManager) {
        self.connectionManager = manager
    }

    /// Request a session list refresh. The actual RPC call happens asynchronously and may be
    /// coalesced, debounced, or queued depending on current state.
    func request(reason: RefreshReason) {
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
    /// Used when an RPC began while the transport looked connected but URLSession reported
    /// native socket churn (for example `ECONNABORTED` during foreground return). Waiting for
    /// a future reconnect edge avoids immediately retrying against the same stale socket.
    func deferUntilReconnect() {
        foregroundDebounceTask?.cancel()
        foregroundDebounceTask = nil
        registerReconnectHook(fireIfAlreadyConnected: false)
    }

    // MARK: - Internals

    private func registerReconnectHook(fireIfAlreadyConnected: Bool = true) {
        guard let manager = connectionManager else {
            // No manager attached — nothing else we can do; caller will try again next time.
            return
        }
        manager.runOnReconnect(
            label: Self.hookLabel,
            fireIfAlreadyConnected: fireIfAlreadyConnected
        ) { [weak self] in
            guard let self else { return }
            self.startOrCoalesce()
        }
    }

    private func scheduleForegroundDebounce() {
        foregroundDebounceTask?.cancel()
        foregroundDebounceTask = Task { [weak self, clock, foregroundDebounce] in
            do {
                try await clock.sleep(for: foregroundDebounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.isConnectedCheck() else {
                self.registerReconnectHook()
                return
            }
            self.startOrCoalesce()
        }
    }

    private func startOrCoalesce() {
        if inflightTask != nil {
            pending = true
            return
        }
        spawnInflight()
    }

    private func spawnInflight() {
        inflightTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefresh()
            self.onInflightComplete()
        }
    }

    private func onInflightComplete() {
        inflightTask = nil
        if pending {
            pending = false
            spawnInflight()
        }
    }
}
