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

    /// Whether the pill is visible. Separate from displayedState to decouple
    /// show/hide animation from content updates (prevents glitchy re-renders).
    @State private var isVisible: Bool

    /// The state we're actually displaying. Updated immediately on every
    /// connectionState change — content transitions handle smooth text updates.
    @State private var displayedState: ConnectionState

    /// Debounce task for connected→hide transition
    @State private var debounceTask: Task<Void, Never>?

    init(connectionState: ConnectionState, isReady: Bool = true, onRetry: @escaping () async -> Void) {
        self.connectionState = connectionState
        self.isReady = isReady
        self.onRetry = onRetry
        let notConnected = !connectionState.isConnected
        _hasSeenDisconnect = State(initialValue: notConnected)
        _isVisible = State(initialValue: notConnected)
        _displayedState = State(initialValue: connectionState)
    }

    var body: some View {
        Group {
            if isVisible, hasSeenDisconnect, isReady {
                pillContent
                    .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.35), value: isVisible)
        .animation(.smooth(duration: 0.35), value: isReady)
        .onChange(of: connectionState) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Pill Content

    private var pillContent: some View {
        let color = statusColor
        return Button {
            Task { await onRetry() }
        } label: {
            HStack(spacing: 6) {
                statusIcon
                    .frame(width: TronTypography.sizeBodySM, height: TronTypography.sizeBodySM)

                Text(statusText)
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(color)

                if let seconds = countdownSeconds, seconds > 0 {
                    Text("(\(seconds)s)")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(color.opacity(0.5))
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .disabled(displayedState.isConnected)
        .glassEffect(
            .regular.tint(color.opacity(0.25)).interactive(),
            in: .capsule
        )
        .animation(.smooth(duration: 0.25), value: statusText)
        .animation(.smooth(duration: 0.25), value: countdownSeconds)
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        let iconSize = TronTypography.sizeBodySM
        let color = statusColor
        switch displayedState {
        case .connecting, .reconnecting:
            ProgressView()
                .scaleEffect(0.6)
                .tint(color)
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(color)
        case .disconnected, .failed:
            Image(systemName: "wifi.slash")
                .font(TronTypography.sans(size: iconSize, weight: .medium))
                .foregroundStyle(color)
        }
    }

    // MARK: - Status Text & Color

    private var statusText: String {
        switch displayedState {
        case .disconnected, .failed:
            return "Not Connected (Tap to retry)"
        case .connecting:
            return "Connecting"
        case .reconnecting(let attempt, _):
            return "Reconnecting (Attempt \(attempt))"
        case .connected:
            return "Connected"
        }
    }

    private var countdownSeconds: Int? {
        if case .reconnecting(_, let seconds) = displayedState {
            return seconds
        }
        return nil
    }

    private var statusColor: Color {
        switch displayedState {
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

        // Always update displayed state for content changes (text, countdown, color)
        displayedState = newState

        if newState.isConnected {
            // Show pill briefly, then hide
            if !isVisible {
                // Was already hidden — just stay hidden
                return
            }
            debounceTask = Task {
                try? await Task.sleep(for: .seconds(2.0))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if connectionState.isConnected {
                        isVisible = false
                    }
                }
            }
        } else {
            isVisible = true
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
