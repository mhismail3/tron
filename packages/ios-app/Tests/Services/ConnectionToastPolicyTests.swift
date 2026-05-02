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
        #expect(presentation?.autoDismiss == .sticky)
        #expect(presentation?.includesRetry == true)
    }

    @Test("reconnecting active server shows retryable reconnecting toast")
    func reconnectingShowsToast() {
        let presentation = ConnectionToastPolicy.presentation(
            for: .reconnecting(attempt: 1, nextRetrySeconds: 2),
            hasActiveServer: true
        )

        #expect(presentation?.message == ConnectionStatusCopy.reconnectingActiveServer)
        #expect(presentation?.severity == .warning)
        #expect(presentation?.autoDismiss == .sticky)
        #expect(presentation?.includesRetry == true)
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
    }
}
