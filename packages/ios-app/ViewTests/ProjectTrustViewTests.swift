import XCTest
@testable import TronMobile

@MainActor
final class ProjectTrustViewTests: ShuffledTestCase {
    func testEarlierTrustReceiptCannotReplaceLaterCanonicalBlock() async throws {
        try await trust("held") { app in
            try await acceptTrustThenBlock(app)
            try await app.activate("fixture.release-trust")
            try await counts(app, contain: "firstReply:1")
            try await assertBlockedWithoutLateTrust(app)
            try await assertOriginalCommands(app, count: 2)
        }
    }

    func testEarlierInspectCannotReplaceLaterCanonicalBlock() async throws {
        try await trust("inspect-value-held") { app in
            try await holdOlderInspectThenBlock(app)
            try await app.activate("fixture.release-trust-reads")
            try await counts(app, contain: "releasedReads:2")
            try await assertBlockedWithoutLateTrust(app)
            try await assertOriginalCommands(app, count: 2)
        }
    }

    func testEarlierInspectErrorCannotPublishAfterLaterCanonicalBlock() async throws {
        try await trust("inspect-error-held") { app in
            try await holdOlderInspectThenBlock(app)
            try await app.activate("fixture.release-trust-reads")
            try await counts(app, contain: "releasedReads:2")
            await settle()
            XCTAssertFalse(app.element("fixture.trust-notices")?.accessibilityLabel?.contains("Earlier trust read failure") == true,
                           "An earlier trust read cannot publish an error into the newer inspection")
            XCTAssertNotNil(app.staticText("Resources blocked"))
            try await assertOriginalCommands(app, count: 2)
        }
    }

    func testMatchingSingleBlockSettlesWithoutAnotherCommand() async throws {
        try await trust("ordered") { app in
            try await app.until("the project root") { app.staticText("Applies to project root") != nil }
            XCTAssertNotNil(app.staticText("/fixture"))
            try await app.activate("Do Not Load Project Resources")
            try await app.until("Resources blocked") { app.staticText("Resources blocked") != nil }
            try await counts(app, contain: "canonical:false")
            try await assertOriginalCommands(app, count: 1)
        }
    }

    func testOrderedTrustThenBlockShowsBothCanonicalResults() async throws {
        try await trust("ordered") { app in
            try await app.activate("Trust Project")
            try await app.until("Trusted") { app.staticText("Trusted") != nil }
            try await positive(app, "readsTrue")
            try await app.activate("Do Not Load Project Resources")
            try await app.until("Resources blocked") { app.staticText("Resources blocked") != nil }
            try await positive(app, "readsFalse")
            try await assertOriginalCommands(app, count: 2)
        }
    }

    func testOriginalTrustCannotAttachToReplacementMacWithSameCWD() async throws {
        try await trust("held") { app in
            try await app.activate("Trust Project")
            try await counts(app, contain: "held:1")
            try await app.until("Trusted") { app.staticText("Trusted") != nil }
            try await app.activate("fixture.replace-trust-profile")
            try await positive(app, "readsFalse", id: "fixture.trust-replacement")
            try await app.until("Resources blocked") { app.staticText("Resources blocked") != nil }
            try await app.activate("fixture.release-trust")
            try await assertBlockedWithoutLateTrust(app)
            try await assertOriginalCommands(app, count: 1)
            try await counts(app, id: "fixture.trust-replacement", contain: "sets:0 commands:0 repeats:0")
        }
    }

    private func trust(_ scenario: String, _ body: (MountedFixture) async throws -> Void) async throws {
        try await mounted(["-tron-project-trust-fixture", "-project-trust-scenario", scenario]) { app in
            try await app.until("the decision prompt") { app.staticText("Decision needed") != nil }
            try await body(app)
        }
    }

    private func acceptTrustThenBlock(_ app: MountedFixture) async throws {
        try await app.activate("Trust Project")
        try await counts(app, contain: "held:1")
        try await app.activate("Do Not Load Project Resources")
        try await counts(app, contain: "sets:2 commands:2 repeats:0")
        try await positive(app, "readsFalse")
        try await app.until("Resources blocked") { app.staticText("Resources blocked") != nil }
    }

    private func holdOlderInspectThenBlock(_ app: MountedFixture) async throws {
        try await app.activate("Trust Project")
        try await counts(app, contain: "heldReads:2")
        try await app.activate("Do Not Load Project Resources")
        try await positive(app, "readsFalse")
        try await app.until("Resources blocked") { app.staticText("Resources blocked") != nil }
    }

    private func assertBlockedWithoutLateTrust(_ app: MountedFixture) async throws {
        try await app.until("Resources blocked") { app.staticText("Resources blocked") != nil }
        await settle()
        XCTAssertNil(app.staticText("Trusted"), "An earlier accepted trust receipt must not replace the latest canonical inspection")
        XCTAssertNotNil(app.staticText("Resources blocked"))
    }

    private func assertOriginalCommands(_ app: MountedFixture, count: Int) async throws {
        try await counts(app, contain: "sets:\(count) commands:\(count) repeats:0")
        try await counts(app, contain: "wrongCWD:0")
    }

    private func counts(_ app: MountedFixture, id: String = "fixture.trust-original", contain expected: String) async throws {
        try await app.until("\(id) reports \(expected)") {
            app.element(id)?.accessibilityLabel?.contains(expected) == true
        }
    }

    private func positive(_ app: MountedFixture, _ field: String, id: String = "fixture.trust-original") async throws {
        try await app.until("\(id) reports a positive \(field)") {
            app.element(id)?.accessibilityLabel?.range(of: "\\b\(field):[1-9][0-9]*\\b", options: .regularExpression) != nil
        }
    }

    private func settle() async {
        for _ in 0..<30 { await MountedFixture.nextFrame() }
    }
}
