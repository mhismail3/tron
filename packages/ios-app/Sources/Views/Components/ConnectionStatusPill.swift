import SwiftUI

/// A connection status pill that appears at the bottom of the chat when connection issues occur.
/// Matches the visual style of CommandToolChip — glass capsule, tinted text, blur transitions.
@available(iOS 26.0, *)
struct ConnectionStatusPill: View {
    let connectionState: ConnectionState
    let isReady: Bool
    let onRetry: () async -> Void

    /// Tracks if we've ever seen a non-connected state in this session
    @State private var hasSeenDisconnect: Bool

    /// The state we're actually displaying (debounced on connected transition).
    /// When nil, pill is hidden. When set, pill is shown.
    @State private var displayedState: ConnectionState?

    /// Debounce task for connected→hide transition
    @State private var debounceTask: Task<Void, Never>?

    init(connectionState: ConnectionState, isReady: Bool = true, onRetry: @escaping () async -> Void) {
        self.connectionState = connectionState
        self.isReady = isReady
        self.onRetry = onRetry
        // Seed state from initial connectionState so the pill works inside LazyVStack
        // where onAppear may be deferred until scroll-into-view.
        let notConnected = !connectionState.isConnected
        _hasSeenDisconnect = State(initialValue: notConnected)
        _displayedState = State(initialValue: notConnected ? connectionState : nil)
    }

    var body: some View {
        Group {
            if let state = displayedState, hasSeenDisconnect, isReady {
                pillContent(for: state)
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.3), value: displayedState)
        .animation(.smooth(duration: 0.3), value: isReady)
        .onChange(of: connectionState) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Pill Content

    @ViewBuilder
    private func pillContent(for state: ConnectionState) -> some View {
        let color = statusColor(for: state)
        Button {
            Task { await onRetry() }
        } label: {
            HStack(spacing: 6) {
                statusIcon(for: state)

                Text(statusText(for: state))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(color)
                    .transition(.blurReplace)

                if case .reconnecting(_, let seconds) = state, seconds > 0 {
                    Text("(\(seconds)s)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(color.opacity(0.5))
                        .transition(.blurReplace)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentTransition(.interpolate)
            .animation(.smooth(duration: 0.3), value: statusText(for: state))
        }
        .buttonStyle(.plain)
        .disabled(state.isConnected)
        .glassEffect(
            .regular.tint(color.opacity(0.25)).interactive(),
            in: .capsule
        )
    }

    // MARK: - Status Icon

    @ViewBuilder
    private func statusIcon(for state: ConnectionState) -> some View {
        let iconSize = TronTypography.sizeBodySM
        let color = statusColor(for: state)
        switch state {
        case .connecting, .reconnecting:
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: iconSize, height: iconSize)
                .tint(color)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(color)
        case .disconnected:
            Image(systemName: "wifi.slash")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(color)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(color)
        }
    }

    // MARK: - Status Text & Color

    private func statusText(for state: ConnectionState) -> String {
        switch state {
        case .disconnected: return "Not Connected"
        case .connecting: return "Connecting"
        case .reconnecting(let attempt, _):
            return "Reconnecting (Attempt \(attempt))"
        case .connected: return "Connected"
        case .failed: return "Connection Failed"
        }
    }

    private func statusColor(for state: ConnectionState) -> Color {
        switch state {
        case .connected: return .tronEmerald
        case .connecting, .reconnecting: return .tronWarning
        case .disconnected, .failed: return .tronError
        }
    }

    // MARK: - State Machine

    private func handleStateChange(_ newState: ConnectionState) {
        debounceTask?.cancel()

        if !newState.isConnected {
            hasSeenDisconnect = true
        }

        guard hasSeenDisconnect else { return }

        if newState.isConnected {
            // Show "Connected" briefly, then dismiss
            if let current = displayedState, !current.isConnected {
                displayedState = newState

                debounceTask = Task {
                    try? await Task.sleep(for: .seconds(2.0))
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if connectionState.isConnected {
                            displayedState = nil
                        }
                    }
                }
            } else {
                displayedState = nil
            }
        } else {
            displayedState = newState
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview("Connection States") {
    VStack(spacing: 16) {
        ConnectionStatusPill(connectionState: .disconnected) { }
        ConnectionStatusPill(connectionState: .connecting) { }
        ConnectionStatusPill(connectionState: .reconnecting(attempt: 1, nextRetrySeconds: 5)) { }
        ConnectionStatusPill(connectionState: .reconnecting(attempt: 2, nextRetrySeconds: 0)) { }
        ConnectionStatusPill(connectionState: .connected) { }
        ConnectionStatusPill(connectionState: .failed(reason: "Connection lost")) { }
    }
    .padding()
    .background(Color.tronBackground)
}
