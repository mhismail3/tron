import Foundation

private struct ConnectionManagerObservation: Equatable {
    let state: ConnectionState
    let continuityGeneration: UInt64
    let continuityOwnerId: UUID
}

/// Central policy layer over the raw connection transport.
///
/// Responsibilities:
/// - Mirrors connection state and the ready-socket generation so all consumers
///   have one continuity source of truth.
/// - Offers `runOnReconnect(label:_:)` — a dedup'd, single-shot hook that fires once on the
///   next usable transport epoch (or immediately if already connected, unless the caller
///   asks to wait for a future epoch).
/// - Forwards `manualRetry()` to the underlying transport.
///
/// Replaces the scattered ad-hoc `engineClient.connectionState` observers throughout the app.
@Observable
@MainActor
final class ConnectionManager {

    // MARK: - Public state

    private(set) var state: ConnectionState
    private(set) var continuityGeneration: UInt64
    private(set) var continuityOwnerId: UUID

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
        self.continuityGeneration = provider.continuityGeneration
        self.continuityOwnerId = provider.continuityOwnerId
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
    /// - Otherwise, the block is stored and fires when a new usable transport
    ///   epoch becomes observable.
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
        guard let provider else { return }
        observationTask = Task { [weak self, weak provider] in
            var hasInstalledObservation = false
            while !Task.isCancelled {
                guard let provider else { return }

                // Always read current state at the top of the loop so we never miss a transition
                // that happened between callbacks.
                let current = ConnectionManagerObservation(
                    state: provider.connectionState,
                    continuityGeneration: provider.continuityGeneration,
                    continuityOwnerId: provider.continuityOwnerId
                )
                do {
                    guard let self else { return }
                    if state != current.state
                        || continuityGeneration != current.continuityGeneration
                        || continuityOwnerId != current.continuityOwnerId {
                        applyContinuityChange(
                            state: current.state,
                            generation: current.continuityGeneration,
                            ownerId: current.continuityOwnerId
                        )
                    } else if hasInstalledObservation && current.state.isConnected {
                        // Observation can wake for a rapid connected -> reconnecting -> connected
                        // cycle after the provider has already returned to `.connected`. Hooks that
                        // explicitly asked for a future reconnect edge should still run.
                        drainHooks()
                    }
                }

                hasInstalledObservation = true
                await waitForObservationChange {
                    ConnectionManagerObservation(
                        state: provider.connectionState,
                        continuityGeneration: provider.continuityGeneration,
                        continuityOwnerId: provider.continuityOwnerId
                    )
                }
            }
        }
    }

    private func applyContinuityChange(
        state newState: ConnectionState,
        generation newGeneration: UInt64,
        ownerId newOwnerId: UUID
    ) {
        let previous = EngineConnectionContinuity(
            state: state,
            generation: continuityGeneration,
            ownerId: continuityOwnerId
        )
        state = newState
        continuityGeneration = newGeneration
        continuityOwnerId = newOwnerId
        let current = EngineConnectionContinuity(
            state: newState,
            generation: newGeneration,
            ownerId: newOwnerId
        )
        if current.requiresReconciliation(after: previous) {
            drainHooks()
        }
    }

    private func drainHooks() {
        let toFire = hooks
        hooks.removeAll()
        for (label, block) in toFire {
            Task { [logger] in
                logger.debug("Firing reconnect hook '\(label)'", category: .engine)
                await block()
            }
        }
    }
}
