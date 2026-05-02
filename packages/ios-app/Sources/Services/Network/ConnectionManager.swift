import Foundation

/// Central policy layer over the raw connection transport.
///
/// Responsibilities:
/// - Mirrors `ConnectionStateProvider.connectionState` into an `@Observable` `state` property
///   so all consumers have a single source of truth.
/// - Offers `runOnReconnect(label:_:)` — a dedup'd, single-shot hook that fires once on the
///   next `.connected` transition (or immediately if already connected, unless the caller
///   asks to wait for a future reconnect edge).
/// - Forwards `manualRetry()` to the underlying transport.
///
/// Replaces the scattered ad-hoc `rpcClient.connectionState` observers throughout the app.
@Observable
@MainActor
final class ConnectionManager {

    // MARK: - Public state

    private(set) var state: ConnectionState

    // MARK: - Private

    @ObservationIgnored
    private weak var provider: (any ConnectionStateProvider)?

    @ObservationIgnored
    private var hooks: [String: @MainActor () async -> Void] = [:]

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    @ObservationIgnored
    private let logger = TronLogger.shared

    // MARK: - Init

    init(provider: any ConnectionStateProvider) {
        self.provider = provider
        self.state = provider.connectionState
        startObserving()
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Public API

    /// Register a single-shot closure keyed by `label`.
    ///
    /// - If `state.isConnected` is currently true and `fireIfAlreadyConnected` is true, the
    ///   block runs immediately (on a new Task).
    /// - Otherwise, the block is stored and fires on the next non-connected → `.connected`
    ///   transition.
    /// - Re-registering the same `label` replaces any pending block (coalesce).
    /// - Once fired, the registration is cleared — further reconnects do not re-invoke it.
    func runOnReconnect(
        label: String,
        fireIfAlreadyConnected: Bool = true,
        _ block: @escaping @MainActor () async -> Void
    ) {
        if fireIfAlreadyConnected && state.isConnected {
            Task { await block() }
            return
        }
        hooks[label] = block
    }

    /// Cancel a pending hook before it fires. No-op if the label isn't registered.
    func cancelHook(label: String) {
        hooks.removeValue(forKey: label)
    }

    /// Forward manual retry to the underlying transport. Invoked by pill/banner Retry tap.
    func manualRetry() async {
        await provider?.manualRetry()
    }

    // MARK: - Observation

    private func startObserving() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            var hasInstalledObservation = false
            while !Task.isCancelled {
                guard let self, let provider = self.provider else { return }

                // Always read current state at the top of the loop so we never miss a transition
                // that happened between callbacks.
                let currentState = provider.connectionState
                if self.state != currentState {
                    self.applyStateChange(currentState)
                } else if hasInstalledObservation && currentState.isConnected {
                    // Observation can wake for a rapid connected -> reconnecting -> connected
                    // cycle after the provider has already returned to `.connected`. Hooks that
                    // explicitly asked for a future reconnect edge should still run.
                    self.drainHooks()
                }

                hasInstalledObservation = true
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = provider.connectionState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func applyStateChange(_ newState: ConnectionState) {
        let wasConnected = state.isConnected
        state = newState
        if !wasConnected && newState.isConnected {
            drainHooks()
        }
    }

    private func drainHooks() {
        let toFire = hooks
        hooks.removeAll()
        for (label, block) in toFire {
            Task { [logger] in
                logger.debug("Firing reconnect hook '\(label)'", category: .rpc)
                await block()
            }
        }
    }
}
