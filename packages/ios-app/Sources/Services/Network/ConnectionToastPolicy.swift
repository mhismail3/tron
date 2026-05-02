import Foundation

enum ConnectionStatusCopy {
    static let connectedServerUnavailableDescription = "The connected server can't be reached."
    static let reconnectingActiveServer = "Reconnecting to the connected server."
    static let repairActiveServerPairing = "Re-pair this server to reconnect."
}

enum ConnectionToastPolicy {
    static let dedupKey = "connection.active-server-unavailable"
    static let retryableAutoDismiss: ToastCenter.AutoDismiss = .after(.seconds(6))

    /// Semantic banner identity. Reconnecting countdown ticks should not count as new banners.
    enum Kind: Equatable, Sendable {
        case unavailable
        case reconnecting
        case failed
        case unauthorized
    }

    struct Presentation: Equatable, Sendable {
        let kind: Kind
        let message: String
        let severity: ToastCenter.Severity
        let autoDismiss: ToastCenter.AutoDismiss
        let includesRetry: Bool
    }

    static func presentation(for state: ConnectionState, hasActiveServer: Bool) -> Presentation? {
        guard hasActiveServer else { return nil }

        switch state {
        case .disconnected:
            return Presentation(
                kind: .unavailable,
                message: ConnectionStatusCopy.connectedServerUnavailableDescription,
                severity: .warning,
                autoDismiss: retryableAutoDismiss,
                includesRetry: true
            )
        case .failed:
            return Presentation(
                kind: .failed,
                message: ConnectionStatusCopy.connectedServerUnavailableDescription,
                severity: .error,
                autoDismiss: retryableAutoDismiss,
                includesRetry: true
            )
        case .reconnecting:
            return Presentation(
                kind: .reconnecting,
                message: ConnectionStatusCopy.reconnectingActiveServer,
                severity: .warning,
                autoDismiss: retryableAutoDismiss,
                includesRetry: true
            )
        case .unauthorized:
            return Presentation(
                kind: .unauthorized,
                message: ConnectionStatusCopy.repairActiveServerPairing,
                severity: .error,
                autoDismiss: .sticky,
                includesRetry: false
            )
        case .connecting, .connected, .deployRestarting:
            return nil
        }
    }

    static func shouldDismiss(for state: ConnectionState, hasActiveServer: Bool) -> Bool {
        !hasActiveServer || state.isConnected
    }
}
