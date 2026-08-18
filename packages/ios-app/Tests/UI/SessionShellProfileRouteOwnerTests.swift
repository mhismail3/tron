import Testing
@testable import TronMobile

@MainActor
@Suite("Session shell profile route ownership")
struct SessionShellProfileRouteOwnerTests {
    @Test("A-B-A profile changes synchronously revoke and clear each mounted route")
    func profileRoundTripClearsRoutes() {
        var owner = SessionShellProfileRouteOwner()
        var route: AppModel.SessionNavigationRoute? = .init(
            sessionID: "session-a", editorText: nil
        )
        let targets: [String: AppModel.SessionPresentationTarget] = [
            "session-a": .init(sessionID: "session-a", generation: 1),
            "session-b": .init(sessionID: "session-b", generation: 2),
        ]
        var revoked: [AppModel.SessionPresentationTarget] = []

        owner.reconcile(
            profileID: "profile-a",
            presentedSession: &route,
            presentationTarget: { targets[$0] },
            revoke: { revoked.append($0) }
        )
        #expect(route?.sessionID == "session-a")
        #expect(revoked.isEmpty)

        owner.reconcile(
            profileID: "profile-b",
            presentedSession: &route,
            presentationTarget: { targets[$0] },
            revoke: { revoked.append($0) }
        )
        #expect(route == nil)
        #expect(revoked == [.init(sessionID: "session-a", generation: 1)])

        route = .init(sessionID: "session-b", editorText: nil)
        owner.reconcile(
            profileID: "profile-a",
            presentedSession: &route,
            presentationTarget: { targets[$0] },
            revoke: { revoked.append($0) }
        )
        #expect(route == nil)
        #expect(revoked == [
            .init(sessionID: "session-a", generation: 1),
            .init(sessionID: "session-b", generation: 2),
        ])
    }

    @Test("production reconciliation revokes presentation, composer, and share authority")
    func appModelIntegration() throws {
        let model = AppModel()
        let snapshot = try SessionScenarioBuilder(seed: 311).openingTail(targetEncodedBytes: 4_096)
        model.installHostedSubscribedSnapshot(snapshot, token: "profile-a-token")
        let firstTarget = try #require(model.mountedPresentationTarget)
        _ = model.composerDrafts.installHostedPresentation(
            profileID: "profile-a", target: firstTarget, lifecycleGeneration: 0
        )

        var owner = SessionShellProfileRouteOwner()
        var route: AppModel.SessionNavigationRoute? = .init(
            sessionID: snapshot.sessionId, editorText: nil
        )
        owner.reconcile(
            profileID: "profile-a",
            presentedSession: &route,
            presentationTarget: model.presentationTarget(for:),
            revoke: model.revokePresentationIntake
        )
        #expect(model.ownsPresentation(firstTarget))
        #expect(model.composerDrafts.admits(firstTarget))

        owner.reconcile(
            profileID: "profile-b",
            presentedSession: &route,
            presentationTarget: model.presentationTarget(for:),
            revoke: model.revokePresentationIntake
        )
        #expect(route == nil)
        #expect(!model.ownsPresentation(firstTarget))
        #expect(!model.composerDrafts.admits(firstTarget))

        model.installHostedSubscribedSnapshot(snapshot, token: "profile-b-token")
        let secondTarget = try #require(model.mountedPresentationTarget)
        _ = model.composerDrafts.installHostedPresentation(
            profileID: "profile-b", target: secondTarget, lifecycleGeneration: 0
        )
        route = .init(sessionID: snapshot.sessionId, editorText: nil)
        owner.reconcile(
            profileID: "profile-a",
            presentedSession: &route,
            presentationTarget: model.presentationTarget(for:),
            revoke: model.revokePresentationIntake
        )
        #expect(route == nil)
        #expect(!model.ownsPresentation(secondTarget))
        #expect(!model.composerDrafts.admits(secondTarget))
    }
}
