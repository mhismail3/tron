import Foundation
import Testing

@testable import TronMobile

/// Behavioral tests for `WebSocketService`'s bearer-token integration —
/// Phase 3 of the onboarding plan (per-preset bearer auth on the WS upgrade
/// request, plus the new `.unauthorized` state machine path).
///
/// These tests exercise the upgrade-request shape and the state-machine
/// transitions without doing real network I/O. End-to-end "real 401 from
/// real server" is verified manually during Phase 3.7 dogfood (flipping
/// `server.auth.enforced=true` on the local dev server and watching iOS
/// land in `.unauthorized` with the re-pair CTA).
@Suite("WebSocketService bearer auth")
@MainActor
struct WebSocketAuthTests {

    private func makeURL() -> URL {
        URL(string: "ws://127.0.0.1:55555/nonexistent")!
    }

    // MARK: - Upgrade request shape

    @Test("upgrade request includes Bearer header when provider returns a token")
    func upgradeRequestHasBearerHeader() {
        let token = "test-bearer-token-43-chars-base64-padding-eq"
        let ws = WebSocketService(serverURL: makeURL()) { token }

        let request = ws.makeUpgradeRequest()

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test("upgrade request omits Authorization when provider returns nil")
    func upgradeRequestOmitsHeaderWhenNil() {
        // Mirrors the legacy / un-paired preset case: server-provided preset
        // exists but no bearer in Keychain. The header must not be sent so
        // the server's 401 response triggers `.unauthorized` rather than the
        // request being silently rejected with the wrong token.
        let ws = WebSocketService(serverURL: makeURL()) { nil }

        let request = ws.makeUpgradeRequest()

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("upgrade request omits Authorization when no provider is supplied")
    func upgradeRequestOmitsHeaderWithoutProvider() {
        // Backwards-compatibility safety net: existing call sites that don't
        // pass a provider must continue to send no header (server with
        // `auth.enforced=false` accepts; with `enforced=true` returns 401).
        let ws = WebSocketService(serverURL: makeURL())

        let request = ws.makeUpgradeRequest()

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("provider is re-evaluated on every upgrade — token rotation flows through")
    func providerEvaluatedPerUpgrade() {
        // Token rotation on the server side means the user re-pairs via the
        // .unauthorized CTA, which writes a fresh token into the Keychain.
        // The provider closure must re-read on every connect so the next
        // attempt picks up the rotated token.
        nonisolated(unsafe) var current = "old-token"
        let ws = WebSocketService(serverURL: makeURL()) { current }

        #expect(ws.makeUpgradeRequest().value(forHTTPHeaderField: "Authorization") == "Bearer old-token")

        current = "new-token"

        #expect(ws.makeUpgradeRequest().value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
    }

    @Test("upgrade request preserves the configured timeout")
    func upgradeRequestKeepsTimeout() {
        let ws = WebSocketService(serverURL: makeURL()) { "tok" }

        let request = ws.makeUpgradeRequest()

        #expect(request.timeoutInterval == 30)
    }

    // MARK: - .unauthorized state machine

    @Test("markUnauthorized parks state in .unauthorized with the supplied reason")
    func markUnauthorizedTransitionsState() {
        let ws = WebSocketService(serverURL: makeURL())
        #expect(ws.connectionState == .disconnected)

        ws.markUnauthorized(reason: "Server rejected authentication")

        #expect(ws.connectionState == .unauthorized(reason: "Server rejected authentication"))
    }

    @Test(".unauthorized is distinct from .failed and .disconnected")
    func unauthorizedDistinctFromOtherTerminalStates() {
        let unauthorized: ConnectionState = .unauthorized(reason: "x")
        let failed: ConnectionState = .failed(reason: "x")
        let disconnected: ConnectionState = .disconnected

        #expect(unauthorized != failed)
        #expect(unauthorized != disconnected)
        #expect(failed != disconnected)
    }

    @Test(".unauthorized.canInteract is false (read-only mode)")
    func unauthorizedIsReadOnly() {
        let state: ConnectionState = .unauthorized(reason: "x")
        #expect(state.canInteract == false)
        #expect(state.isConnected == false)
        #expect(state.isReconnecting == false)
    }

    @Test(".unauthorized displayText surfaces a re-pair CTA copy")
    func unauthorizedDisplayCopy() {
        let state: ConnectionState = .unauthorized(reason: "Server rejected authentication")
        // Lock in the user-facing copy so accidental refactors of the pill
        // text are caught here rather than in manual QA.
        #expect(state.displayText.lowercased().contains("re-pair"))
    }

    // MARK: - Manual retry from .unauthorized

    @Test("manualRetry from .unauthorized clears the state and attempts to connect")
    func manualRetryFromUnauthorized() async {
        // After the user re-pairs (writes a new token + restarts the WS),
        // calling manualRetry must NOT leave us stuck in .unauthorized. The
        // state should advance toward .connecting (and then likely fail
        // with .reconnecting since the URL is bogus — that's OK; the assert
        // is that we left .unauthorized).
        let ws = WebSocketService(serverURL: makeURL())
        ws.markUnauthorized(reason: "Server rejected authentication")
        #expect(ws.connectionState == .unauthorized(reason: "Server rejected authentication"))

        await ws.manualRetry()

        if case .unauthorized = ws.connectionState {
            Issue.record("manualRetry left state in .unauthorized")
        }
    }

    // MARK: - Migration path: legacy preset → no header → 401 → .unauthorized

    @Test("migration: nil-token provider produces no header and accepts a 401-driven .unauthorized transition")
    func migrationFlowNoTokenToUnauthorized() {
        // Compose the contract: a provider returning nil produces a request
        // with no Authorization header. The integration with URLSessionDelegate
        // (Phase 3.5) marks the resulting 401 as `.unauthorized`. The unit
        // test simulates the second half via direct `markUnauthorized`.
        let ws = WebSocketService(serverURL: makeURL()) { nil }

        let request = ws.makeUpgradeRequest()
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        ws.markUnauthorized(reason: "Server rejected authentication (no token)")
        #expect(ws.connectionState == .unauthorized(reason: "Server rejected authentication (no token)"))
    }
}
