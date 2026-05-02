import Foundation

enum ConnectionStatusCopy {
    static let connectedServerUnavailableDescription = "The connected server can't be reached."
    static let reconnectingActiveServer = "Reconnecting to the connected server."
    static let repairActiveServerPairing = "Re-pair this server to reconnect."
}

enum ConnectionToastPolicy {
    static let dedupKey = "connection.active-server-unavailable"

    struct Presentation: Equatable, Sendable {
        let message: String
        let severity: ToastCenter.Severity
        let autoDismiss: ToastCenter.AutoDismiss
        let includesRetry: Bool
    }

    static func presentation(for state: ConnectionState, hasActiveServer: Bool) -> Presentation? {
        guard hasActiveServer else { return nil }

        switch state {
        case .disconnected, .failed:
            return Presentation(
                message: ConnectionStatusCopy.connectedServerUnavailableDescription,
                severity: .warning,
                autoDismiss: .sticky,
                includesRetry: true
            )
        case .reconnecting:
            return Presentation(
                message: ConnectionStatusCopy.reconnectingActiveServer,
                severity: .warning,
                autoDismiss: .sticky,
                includesRetry: true
            )
        case .unauthorized:
            return Presentation(
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
