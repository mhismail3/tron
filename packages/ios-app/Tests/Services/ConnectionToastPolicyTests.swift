import Testing
import Foundation

@testable import TronMobile

@Suite("Connection toast policy")
struct ConnectionToastPolicyTests {
    @Test("does not show without an active server")
    func noActiveServerSuppressesToast() {
        #expect(ConnectionToastPolicy.presentation(for: .disconnected, hasActiveServer: false) == nil)
        #expect(ConnectionToastPolicy.shouldDismiss(for: .disconnected, hasActiveServer: false))
    }

    @Test("connected state dismisses active server toast")
    func connectedDismissesToast() {
        #expect(ConnectionToastPolicy.presentation(for: .connected, hasActiveServer: true) == nil)
        #expect(ConnectionToastPolicy.shouldDismiss(for: .connected, hasActiveServer: true))
    }

    @Test("disconnected active server shows retryable unavailable toast")
    func disconnectedShowsUnavailableToast() {
        let presentation = ConnectionToastPolicy.presentation(for: .disconnected, hasActiveServer: true)

        #expect(presentation?.message == ConnectionStatusCopy.connectedServerUnavailableDescription)
        #expect(presentation?.severity == .warning)
        #expect(presentation?.autoDismiss == ConnectionToastPolicy.retryableAutoDismiss)
        #expect(presentation?.includesRetry == true)
        #expect(presentation?.kind == .unavailable)
    }

    @Test("reconnecting active server shows retryable reconnecting toast")
    func reconnectingShowsToast() {
        let presentation = ConnectionToastPolicy.presentation(
            for: .reconnecting(attempt: 1, nextRetrySeconds: 2),
            hasActiveServer: true
        )

        #expect(presentation?.message == ConnectionStatusCopy.reconnectingActiveServer)
        #expect(presentation?.severity == .warning)
        #expect(presentation?.autoDismiss == ConnectionToastPolicy.retryableAutoDismiss)
        #expect(presentation?.includesRetry == true)
        #expect(presentation?.kind == .reconnecting)
    }

    @Test("reconnecting countdown ticks keep one semantic banner kind")
    func reconnectingCountdownKeepsStableKind() {
        let first = ConnectionToastPolicy.presentation(
            for: .reconnecting(attempt: 1, nextRetrySeconds: 5),
            hasActiveServer: true
        )
        let nextTick = ConnectionToastPolicy.presentation(
            for: .reconnecting(attempt: 1, nextRetrySeconds: 4),
            hasActiveServer: true
        )

        #expect(first?.kind == .reconnecting)
        #expect(nextTick?.kind == .reconnecting)
    }

    @Test("failed active server shows action-required error toast")
    func failedShowsErrorToast() {
        let presentation = ConnectionToastPolicy.presentation(
            for: .failed(reason: "Request timed out"),
            hasActiveServer: true
        )

        #expect(presentation?.message == ConnectionStatusCopy.connectedServerUnavailableDescription)
        #expect(presentation?.severity == .error)
        #expect(presentation?.autoDismiss == ConnectionToastPolicy.retryableAutoDismiss)
        #expect(presentation?.includesRetry == true)
        #expect(presentation?.kind == .failed)
    }

    @Test("connecting suppresses startup banner flash")
    func connectingSuppressesStartupFlash() {
        #expect(ConnectionToastPolicy.presentation(for: .connecting, hasActiveServer: true) == nil)
        #expect(!ConnectionToastPolicy.shouldDismiss(for: .connecting, hasActiveServer: true))
    }

    @Test("unauthorized active server shows non-retry repair toast")
    func unauthorizedShowsRepairToast() {
        let presentation = ConnectionToastPolicy.presentation(
            for: .unauthorized(reason: "Server rejected authentication"),
            hasActiveServer: true
        )

        #expect(presentation?.message == ConnectionStatusCopy.repairActiveServerPairing)
        #expect(presentation?.severity == .error)
        #expect(presentation?.autoDismiss == .sticky)
        #expect(presentation?.includesRetry == false)
        #expect(presentation?.kind == .unauthorized)
    }
}
