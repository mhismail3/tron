import XCTest
@testable import TronMobile

@MainActor
final class IntegrationSheetsViewTests: ShuffledTestCase {
    func testOllamaUnlimitedAccessibilityAndTypeSizes() async throws {
        let card = "Unlimited. Local models run on this Mac with no account usage limits."
        for large in [false, true] {
            try await mounted(integrations("ollama-detail") + (large ? ["-fixture-large-type"] : []),
                              contentSize: large ? .accessibilityExtraExtraExtraLarge : .large) { app in
                try await app.activate("Details for Ollama")
                try await app.until("the Ollama unlimited card") { app.element(card) != nil }
            }
        }
    }

    func testRetryConnectionRecoversReconnectingDetails() async throws {
        try await assertRetryRecovers(scenario: "connection-retry", state: "Reconnecting")
    }

    func testOpenedTransportFailureDoesNotClaimMacUnreachable() async throws {
        try await mounted(integrations("connection-opened-failure")) { app in
            try await app.until("two failed sockets") { app.staticText("failed sockets 2") != nil }
            try await app.until("the reconnecting status") { node(app, "Connection status: Reconnecting") != nil }
            for _ in 0..<5 { await MountedFixture.nextFrame() }
            XCTAssertNil(node(app, "Mac unreachable"), "An opened transport failure must not claim Mac unreachable")
            try await tapRetry(app)
            try await app.until("the connection is restored") { node(app, "Connection status: Connected") != nil }
        }
    }

    private func assertRetryRecovers(scenario: String, state: String) async throws {
        try await mounted(integrations(scenario)) { app in
            try await app.until("the \(state) status") { node(app, state) != nil }
            try await tapRetry(app)
            try await app.until("the connection is restored") { node(app, "Connection status: Connected") != nil }
            XCTAssertNil(retry(app), "A recovered connection offers no retry")
        }
    }

    private func tapRetry(_ app: MountedFixture) async throws {
        try await app.until("the Retry Connection action") { retry(app) != nil }
        XCTAssertTrue(retry(app)?.accessibilityActivate() == true)
    }

    private func retry(_ app: MountedFixture) -> NSObject? {
        node(app, "Retry Connection", button: true)
    }

    private func node(_ app: MountedFixture, _ text: String, button: Bool = false) -> NSObject? {
        MountedFixture.elements(in: app.top).last {
            $0.accessibilityLabel?.contains(text) == true && (!button || $0.accessibilityTraits.contains(.button))
        }
    }

    private func integrations(_ scenario: String) -> [String] {
        ["-tron-integrations-fixture", "-integrations-scenario", scenario]
    }
}
