import SwiftUI

/// A connection status pill that appears at the bottom of the chat when connection issues occur.
/// Uses native iOS 26 liquid glass animations - no custom animation hacks.
@available(iOS 26.0, *)
struct ConnectionStatusPill: View {
    let connectionState: ConnectionState
    let onRetry: () async -> Void

    /// Tracks if we've ever seen a non-connected state in this session
    @State private var hasSeenDisconnect = false

    /// The state we're actually displaying (debounced)
    /// When nil, pill is hidden. When set, pill is shown.
    @State private var displayedState: ConnectionState?

    /// Debounce task for state changes
    @State private var debounceTask: Task<Void, Never>?

    private let debounceDelay: TimeInterval = 0.3

    /// Whether the pill should be visible
    private var isVisible: Bool {
        hasSeenDisconnect && displayedState != nil
    }

    var body: some View {
        Group {
            if let state = displayedState, hasSeenDisconnect {
                pillContent(for: state)
                    // Native iOS transition - scale up/down with fade
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .onChange(of: connectionState) { _, newState in
            handleStateChange(newState)
        }
        .onAppear {
            if !connectionState.isConnected {
                hasSeenDisconnect = true
                // Animate the initial appearance
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    displayedState = connectionState
                }
            }
        }
    }

    @ViewBuilder
    private func pillContent(for state: ConnectionState) -> some View {
        Button {
            Task { await onRetry() }
        } label: {
            HStack(spacing: 8) {
                statusIcon(for: state)

                Text(statusText(for: state))
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))

                // Countdown for reconnecting
                if case .reconnecting(_, let seconds) = state, seconds > 0 {
                    Text("(\(seconds)s)")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // Smooth transitions for internal content changes
            .contentTransition(.interpolate)
        }
        .buttonStyle(.plain)
        .disabled(state.isConnected)
        .glassEffect(
            .regular.tint(tintColor(for: state)).interactive(),
            in: .capsule
        )
    }

    @ViewBuilder
    private func statusIcon(for state: ConnectionState) -> some View {
        switch state {
        case .disconnected:
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
        case .connecting:
            ProgressView()
                .scaleEffect(0.65)
                .tint(.white)
        case .reconnecting:
            ProgressView()
                .scaleEffect(0.65)
                .tint(.white)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func statusText(for state: ConnectionState) -> String {
        switch state {
        case .disconnected: return "Not Connected"
        case .connecting: return "Connecting..."
        case .reconnecting(let attempt, let seconds):
            if seconds > 0 {
                return "Reconnecting (Attempt \(attempt))"
            } else {
                return "Attempting Connection..."
            }
        case .connected: return "Connected"
        case .failed: return "Not Connected - Tap to Retry"
        }
    }

    private func tintColor(for state: ConnectionState) -> Color {
        switch state {
        case .connected: return .tronEmerald.opacity(0.6)
        case .failed: return .tronError.opacity(0.5)
        case .reconnecting, .connecting: return .tronWarning.opacity(0.5)
        case .disconnected: return .tronError.opacity(0.4)
        }
    }

    private func handleStateChange(_ newState: ConnectionState) {
        debounceTask?.cancel()

        if !newState.isConnected {
            hasSeenDisconnect = true
        }

        guard hasSeenDisconnect else { return }

        if newState.isConnected {
            // Transitioning to connected - debounce to prevent flicker
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(debounceDelay))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    // Only show "Connected" if we were showing a non-connected state
                    if let current = displayedState, !current.isConnected {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            displayedState = newState
                        }

                        // Schedule disappearance after showing "Connected" briefly
                        debounceTask = Task {
                            try? await Task.sleep(for: .seconds(2.0))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                if connectionState.isConnected {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                        displayedState = nil
                                    }
                                }
                            }
                        }
                    } else {
                        // Was already nil or already connected - just clear
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            displayedState = nil
                        }
                    }
                }
            }
        } else {
            // Non-connected states - update immediately with animation
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                displayedState = newState
            }
        }
    }
}

// MARK: - Preview

@available(iOS 26.0, *)
#Preview("Connection States") {
    VStack(spacing: 20) {
        ConnectionStatusPill(connectionState: .disconnected) { }
        ConnectionStatusPill(connectionState: .connecting) { }
        ConnectionStatusPill(connectionState: .reconnecting(attempt: 1, nextRetrySeconds: 5)) { }
        ConnectionStatusPill(connectionState: .reconnecting(attempt: 2, nextRetrySeconds: 0)) { }
        ConnectionStatusPill(connectionState: .connected) { }
        ConnectionStatusPill(connectionState: .failed(reason: "Connection lost")) { }
    }
    .padding()
    .background(Color.black)
}
