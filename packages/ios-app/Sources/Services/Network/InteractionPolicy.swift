import Foundation

/// Central read-only / interaction policy for the app.
///
/// Every mutation surface (send button, mic, new session, archive swipe,
/// plugin source, etc.) reads predicates from this type via the SwiftUI environment
/// and applies `.disabled(!policy.canX)`. No surface checks connection state directly anymore.
///
/// Transitions into `.connected` are debounced (default 500ms) to avoid UI flicker from rapid
/// reconnects. Transitions out of `.connected` (disconnect, failed, reconnecting) flip read-only
/// mode on immediately, so the UI locks fast when the server drops.
///
/// The initial state bypasses debouncing — if the app launches already connected, the UI is
/// interactive right away.
@Observable
@MainActor
final class InteractionPolicy {

    // MARK: - Dependencies

    @ObservationIgnored
    private let connection: ConnectionManager

    @ObservationIgnored
    private let clock: any AsyncClock

    @ObservationIgnored
    private let debounceDuration: Duration

    // MARK: - Public state

    /// Raw passthrough of the current connection state.
    var state: ConnectionState { connection.state }

    /// Debounced "are we ready for writes" flag — the single truth for UI gating.
    private(set) var isConnected: Bool

    var isReadOnly: Bool { !isConnected }

    var isReconnecting: Bool {
        switch state {
        case .connecting, .reconnecting, .deployRestarting: return true
        default: return false
        }
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// True when the server rejected the upgrade with HTTP 401 — the user
    /// must re-pair before mutations resume.
    var isUnauthorized: Bool {
        if case .unauthorized = state { return true }
        return false
    }

    /// Localized text for banners/tooltips explaining why writes are blocked.
    /// Returns `nil` when connected.
    var readOnlyReason: String? {
        switch state {
        case .connected: return nil
        case .disconnected: return "Not connected to server"
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt, let seconds):
            if seconds > 0 {
                return "Reconnecting (attempt \(attempt)) in \(seconds)s"
            } else {
                return "Reconnecting (attempt \(attempt))"
            }
        case .deployRestarting(let seconds):
            if seconds > 0 {
                return "Server is restarting (\(seconds)s)"
            } else {
                return "Server is restarting"
            }
        case .failed(let reason): return reason
        case .unauthorized: return "Re-pair this server to continue"
        }
    }

    // MARK: - Semantic predicates

    var canSendMessage: Bool        { isConnected }
    var canRecordAudio: Bool        { isConnected }
    var canCreateSession: Bool      { isConnected }
    var canMutateSession: Bool      { isConnected }
    var canManagePluginSources: Bool          { isConnected }
    var canLoadServerData: Bool     { isConnected }

    // MARK: - Private

    @ObservationIgnored
    private var debounceTask: Task<Void, Never>?

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    // MARK: - Init

    init(connection: ConnectionManager,
         clock: any AsyncClock = SystemAsyncClock(),
         debounceDuration: Duration = .milliseconds(500)) {
        self.connection = connection
        self.clock = clock
        self.debounceDuration = debounceDuration
        // Initial state bypasses debounce — if already connected, UI is writable immediately.
        self.isConnected = connection.state.isConnected
        startObserving()
    }

    deinit {
        observationTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Observation

    private func startObserving() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            var lastState: ConnectionState? = nil
            while !Task.isCancelled {
                guard let self else { return }
                // Read current state at the top so we never miss a transition between cycles.
                let currentState = self.connection.state
                if lastState != currentState {
                    self.apply(newState: currentState)
                    lastState = currentState
                }

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.connection.state
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    private func apply(newState: ConnectionState) {
        // Any pending debounce is invalidated by a new transition.
        debounceTask?.cancel()
        debounceTask = nil

        if !newState.isConnected {
            // Offline transitions are immediate — lock the UI fast.
            if isConnected { isConnected = false }
            return
        }

        // Already debounced-connected — nothing to do.
        if isConnected { return }

        // Debounced flip: wait for `debounceDuration`, then re-check state and flip on.
        debounceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(for: self.debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if self.connection.state.isConnected {
                self.isConnected = true
            }
        }
    }
}
