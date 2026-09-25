import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@MainActor
@Suite("Presentation activity coordination")
struct PresentationActivityCoordinatorTests {
    @Test("managed SwiftUI sheet and system boundaries register and retire through a hosted scene")
    func hostedLifecycleBoundaries() async throws {
        let coordinator = PresentationActivityCoordinator()
        let state = PresentationActivityHostedState()
        let root = PresentationActivityHostedView(state: state)
            .environment(\.tronPresentationActivityCoordinator, coordinator)
        let controller = UIHostingController(rootView: root)
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        try await waitForSurfaceCount(1, coordinator: coordinator)
        state.sheetPresented = true
        try await waitForSurfaceCount(2, coordinator: coordinator)
        try await waitForPresentedSurface(from: controller)
        state.sheetPresented = false
        await Task.yield()
        await dismissPresentedSurface(from: controller)
        try await waitForSurfaceCount(1, coordinator: coordinator)

        state.systemPresented = true
        try await waitForSurfaceCount(2, coordinator: coordinator)
        state.systemPresented = false
        try await waitForSurfaceCount(1, coordinator: coordinator)
    }

    @Test("exact descendant visuals survive dismissal intent but not completed retirement or other branches")
    func descendantVisualOwnership() throws {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "chat", generation: UUID())
        let other = PresentationSurfaceToken(id: "other", generation: UUID())
        coordinator.register(root, parent: nil)
        coordinator.register(other, parent: nil)
        var lease = PresentationDismissalLease()
        let registered = lease.register(identity: "browser-sheet")
        let sheet = try #require(registered)
        coordinator.register(sheet, parent: root)
        #expect(coordinator.hasMountedDescendant(id: "browser-sheet", of: root))
        #expect(!coordinator.hasMountedDescendant(id: "browser-sheet", of: other))
        #expect(!coordinator.hasMountedDescendant(id: "different-browser", of: root))
        lease.beginDismissal()
        #expect(coordinator.hasMountedDescendant(id: "browser-sheet", of: root))
        let transition = lease.completeDismissal(nextIdentity: nil)
        coordinator.retire(try #require(transition.retired))
        #expect(!coordinator.hasMountedDescendant(id: "browser-sheet", of: root))
        #expect(!coordinator.hasMountedDescendant(id: "browser-sheet", of: nil))
    }

    @Test("the topmost surface owns motion while its ancestors keep descendant data live")
    func activeLineageSeparatesPublicationFromMotion() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "chat", generation: UUID())
        let child = PresentationSurfaceToken(id: "tool-run", generation: UUID())
        let grandchild = PresentationSurfaceToken(id: "tool-detail", generation: UUID())
        coordinator.register(root, parent: nil)
        coordinator.register(child, parent: root)
        coordinator.register(grandchild, parent: child)

        #expect(coordinator.activity(for: root) == .presentingDescendant)
        #expect(coordinator.activity(for: child) == .presentingDescendant)
        #expect(coordinator.activity(for: grandchild) == .active)
        #expect(coordinator.activity(for: root).allowsDataPublication)
        #expect(!coordinator.activity(for: root).allowsPresentationPublication)
        #expect(!coordinator.activity(for: root).allowsContinuousAnimation)
        #expect(!coordinator.activity(for: root).allowsViewportObservation)
    }

    @Test("a child remains active when binding intent registers before its parent appears")
    func topologyWinsOverCallbackOrder() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "root", generation: UUID())
        let child = PresentationSurfaceToken(id: "child", generation: UUID())
        coordinator.register(child, parent: root)
        coordinator.register(root, parent: nil)
        #expect(coordinator.activity(for: root) == .presentingDescendant)
        #expect(coordinator.activity(for: child) == .active)
    }

    @Test("the newest independent branch is topmost without corrupting either topology")
    func independentBranchesUseRegistrationOrder() {
        let coordinator = PresentationActivityCoordinator()
        let first = PresentationSurfaceToken(id: "first", generation: UUID())
        let second = PresentationSurfaceToken(id: "second", generation: UUID())
        coordinator.register(first, parent: nil)
        coordinator.register(second, parent: nil)
        #expect(coordinator.activity(for: first) == .covered)
        #expect(coordinator.activity(for: second) == .active)

        coordinator.retire(second)
        #expect(coordinator.activity(for: first) == .active)
        #expect(coordinator.mountedSurfaceCount == 1)
    }

    @Test("retiring a child reactivates its parent")
    func childRetirementReactivatesParent() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "chat", generation: UUID())
        let child = PresentationSurfaceToken(id: "manage", generation: UUID())
        coordinator.register(root, parent: nil)
        coordinator.register(child, parent: root)
        coordinator.retire(child)
        #expect(coordinator.activity(for: root) == .active)
        #expect(coordinator.mountedSurfaceCount == 1)
    }

    @Test("retiring a parent also retires its descendants")
    func branchRetirementIsAtomic() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "root", generation: UUID())
        let child = PresentationSurfaceToken(id: "child", generation: UUID())
        let grandchild = PresentationSurfaceToken(id: "grandchild", generation: UUID())
        coordinator.register(root, parent: nil)
        coordinator.register(child, parent: root)
        coordinator.register(grandchild, parent: child)
        coordinator.retire(root)
        #expect(coordinator.mountedSurfaceCount == 0)
        #expect(coordinator.activity(for: grandchild) == .covered)
    }

    @Test("fork handoff reaches the chat only after every nested surface retires")
    func forkHandoffRetiresEverySurface() throws {
        let coordinator = PresentationActivityCoordinator()
        let chat = PresentationSurfaceToken(id: "chat", generation: UUID())
        let context = PresentationSurfaceToken(id: "context", generation: UUID())
        let history = PresentationSurfaceToken(id: "history", generation: UUID())
        let selection = PresentationSurfaceToken(id: "selection", generation: UUID())
        let confirmation = PresentationSurfaceToken(id: "confirmation", generation: UUID())
        coordinator.register(chat, parent: nil)
        coordinator.register(context, parent: chat)
        coordinator.register(history, parent: context)
        coordinator.register(selection, parent: history)
        coordinator.register(confirmation, parent: selection)

        var owners = Array(repeating: ChatForkNavigationOwner(), count: 4)
        let route = AppModel.SessionNavigationRoute(sessionID: "fork", editorText: nil)
        owners[0].stage(route)
        for index in 0..<owners.count {
            let surface = [confirmation, selection, history, context][index]
            coordinator.retire(surface)
            let consumed = owners[index].consume()
            let forwarded = try #require(consumed)
            if index + 1 < owners.count { owners[index + 1].stage(forwarded) }
            #expect(coordinator.activity(for: chat) == (index == owners.count - 1 ? .active : .presentingDescendant))
        }
        #expect(coordinator.mountedSurfaceCount == 1)
    }

    @Test("a child delayed beyond exact parent retirement cannot escape as an independent branch")
    func retiredParentRejectsLateChildRegistration() {
        let coordinator = PresentationActivityCoordinator()
        let parent = PresentationSurfaceToken(id: "tool-run", generation: UUID())
        let lateChild = PresentationSurfaceToken(id: "tool-detail", generation: UUID())
        coordinator.register(parent, parent: nil)
        coordinator.retire(parent)
        coordinator.register(lateChild, parent: parent)

        #expect(coordinator.mountedSurfaceCount == 0)
        #expect(coordinator.activity(for: lateChild) == .covered)

        let replacementParent = PresentationSurfaceToken(id: parent.id, generation: UUID())
        let replacementChild = PresentationSurfaceToken(id: lateChild.id, generation: UUID())
        coordinator.register(replacementParent, parent: nil)
        coordinator.register(replacementChild, parent: replacementParent)
        #expect(coordinator.activity(for: replacementParent) == .presentingDescendant)
        #expect(coordinator.activity(for: replacementChild) == .active)
    }

    @Test("a stale generation cannot retire a replacement")
    func generationsAreIndependent() {
        let coordinator = PresentationActivityCoordinator()
        let old = PresentationSurfaceToken(id: "settings", generation: UUID())
        let replacement = PresentationSurfaceToken(id: "settings", generation: UUID())
        coordinator.register(old, parent: nil)
        coordinator.retire(old)
        coordinator.register(replacement, parent: nil)
        coordinator.retire(old)
        #expect(coordinator.mountedSurfaceCount == 1)
        #expect(coordinator.activity(for: replacement) == .active)
    }

    @Test("same-ID interaction scopes retire old success and error effects")
    func sameInteractionIDScopesReplaceManagedPresentation() throws {
        let sessionID = "ask-user-scope-session"
        let form = ExtensionFormDescriptor(
            version: 1,
            title: "Choose a database",
            questions: [ExtensionFormQuestion(
                id: "database", question: "Which database?",
                options: [ExtensionFormOption(id: "postgres", label: "Postgres"), ExtensionFormOption(id: "sqlite", label: "SQLite")],
                multiSelect: false, allowOther: false
            )],
            allowCancel: true
        )
        let old = ExtensionInteraction(
            id: "same-id", hostEpoch: "epoch-a", presentationRevision: 1,
            method: .form, title: form.title, form: form
        )
        let newEpoch = ExtensionInteraction(
            id: old.id, hostEpoch: "epoch-b", presentationRevision: 1,
            method: .form, title: form.title, form: form
        )
        let newRevision = ExtensionInteraction(
            id: old.id, hostEpoch: newEpoch.hostEpoch, presentationRevision: 2,
            method: .form, title: form.title, form: form
        )
        let identity: (ExtensionInteraction) -> String = {
            ExtensionInteractionPresentationIdentity.value(sessionID: sessionID, interaction: $0)
        }
        // Negative control: the retired ID-only route would retain one token
        // across both scope changes and therefore cannot fence a late result.
        var legacyLease = PresentationDismissalLease()
        let legacyIdentity = "chat.\(sessionID).interaction.\(old.id)"
        _ = legacyLease.register(identity: legacyIdentity)
        let legacyTransition = legacyLease.replace(identity: legacyIdentity)
        #expect(legacyTransition.retired == nil)
        #expect(legacyTransition.registered == nil)

        var lease = PresentationDismissalLease()
        let registeredOldToken = lease.register(identity: identity(old))
        let oldToken = try #require(registeredOldToken)
        let coordinator = PresentationActivityCoordinator()
        coordinator.register(oldToken, parent: nil)
        var publishedEffects = 0
        func publish(_ token: PresentationSurfaceToken, outcome: Result<Void, Error>) {
            guard coordinator.activity(for: token).allowsPresentationPublication else { return }
            _ = outcome
            publishedEffects += 1
        }

        let epochTransition = lease.replace(identity: identity(newEpoch))
        let epochToken = try #require(epochTransition.registered)
        #expect(epochTransition.retired == oldToken)
        coordinator.retire(oldToken)
        coordinator.register(epochToken, parent: nil)
        publish(oldToken, outcome: .success(()))
        publish(oldToken, outcome: .failure(NSError(domain: "PresentationActivityCoordinatorTests", code: 1)))
        #expect(publishedEffects == 0)
        #expect(coordinator.activity(for: epochToken) == .active)

        let revisionTransition = lease.replace(identity: identity(newRevision))
        let revisionToken = try #require(revisionTransition.registered)
        #expect(revisionTransition.retired == epochToken)
        coordinator.retire(epochToken)
        coordinator.register(revisionToken, parent: nil)
        publish(epochToken, outcome: .success(()))
        publish(epochToken, outcome: .failure(NSError(domain: "PresentationActivityCoordinatorTests", code: 1)))
        publish(revisionToken, outcome: .success(()))
        #expect(publishedEffects == 1)
        #expect(coordinator.activity(for: revisionToken) == .active)

        let suiteName = "PresentationActivityCoordinatorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let drafts = ExtensionInteractionDraftStore(defaults: defaults)
        drafts.saveForm(
            StoredExtensionFormDraft(
                draft: ExtensionFormDraft(form: form), activeOtherQuestionIDs: [], currentQuestionIndex: 0
            ),
            sessionID: sessionID,
            interaction: newRevision
        )
        #expect(drafts.formDraft(sessionID: sessionID, interaction: newRevision) != nil)
        drafts.clear(sessionID: sessionID, interaction: old)
        #expect(drafts.formDraft(sessionID: sessionID, interaction: newRevision) != nil)
    }

    @Test("managed item replacement retires same-ID scoped interaction content")
    func managedItemReplacementUsesScopedIdentity() async throws {
        let sessionID = "managed-interaction-probe"
        let form = ExtensionFormDescriptor(
            version: 1,
            title: "Choose a database",
            questions: [ExtensionFormQuestion(
                id: "database", question: "Which database?",
                options: [ExtensionFormOption(id: "postgres", label: "Postgres"), ExtensionFormOption(id: "sqlite", label: "SQLite")],
                multiSelect: false, allowOther: false
            )],
            allowCancel: true
        )
        let old = ExtensionInteraction(
            id: "same-id", hostEpoch: "epoch-a", presentationRevision: 1,
            method: .form, title: form.title, form: form
        )
        let successor = ExtensionInteraction(
            id: old.id, hostEpoch: "epoch-b", presentationRevision: 2,
            method: .form, title: form.title, form: form
        )
        let coordinator = PresentationActivityCoordinator()
        let state = ManagedInteractionProbeState()
        let controller = UIHostingController(
            rootView: ManagedInteractionProbeView(sessionID: sessionID, state: state)
                .environment(\.tronPresentationActivityCoordinator, coordinator)
        )
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        state.interaction = old
        try await waitForSurfaceCount(1, coordinator: coordinator)
        try await waitForProbeTokenCount(1, state: state)
        let oldToken = try #require(state.tokens.first)
        #expect(coordinator.activity(for: oldToken) == .active)

        state.interaction = successor
        try await waitForProbeTokenCount(2, state: state)
        let successorToken = try #require(state.tokens.last)
        #expect(successorToken != oldToken)
        #expect(coordinator.activity(for: oldToken) == .covered)
        #expect(coordinator.activity(for: successorToken) == .active)

        state.publishIfAllowed(oldToken, coordinator: coordinator)
        #expect(state.publishedCount == 0)
        state.publishIfAllowed(successorToken, coordinator: coordinator)
        #expect(state.publishedCount == 1)

        state.interaction = nil
        try await waitForSurfaceCount(0, coordinator: coordinator)
        state.interaction = successor
        try await waitForSurfaceCount(1, coordinator: coordinator)
        try await waitForProbeTokenCount(3, state: state)
        let reopenedToken = try #require(state.tokens.last)
        #expect(reopenedToken != successorToken)
        #expect(coordinator.activity(for: reopenedToken) == .active)
        state.interaction = nil
        await dismissPresentedSurface(from: controller)
    }

    @Test("coordinator authority rejects a missing token but standalone activity may publish")
    func tokenlessPublicationFailsClosedUnderCoordinator() {
        let coordinator = PresentationActivityCoordinator()
        #expect(!PresentationPublicationPolicy.allows(
            ambient: .active, coordinator: coordinator, token: nil
        ))
        #expect(PresentationPublicationPolicy.allows(
            ambient: .active, coordinator: nil, token: nil
        ))
        #expect(!PresentationPublicationPolicy.allows(
            ambient: .covered, coordinator: nil, token: nil
        ))
    }

    @Test("a stale dismissal completes its old lease without retiring a rapid replacement")
    func dismissalLeaseDefersRapidReplacement() throws {
        var lease = PresentationDismissalLease()
        let registeredOld = lease.register(identity: "sheet")
        let old = try #require(registeredOld)
        lease.beginDismissal()
        #expect(lease.register(identity: "sheet") == nil)

        let transition = lease.completeDismissal(nextIdentity: "sheet")
        #expect(transition.retired == old)
        let replacement = try #require(transition.registered)
        #expect(replacement.id == old.id)
        #expect(replacement.generation != old.generation)
        #expect(lease.registeredToken == replacement)
    }

    @Test("direct item replacement retires only the previous item generation")
    func dismissalLeaseReplacesItemsExactly() throws {
        var lease = PresentationDismissalLease()
        let registeredFirst = lease.register(identity: "item-a")
        let first = try #require(registeredFirst)
        let transition = lease.replace(identity: "item-b")
        #expect(transition.retired == first)
        let second = try #require(transition.registered)
        #expect(second.id == "item-b")
        #expect(second.generation != first.generation)
        #expect(lease.completeDismissal(nextIdentity: "item-b").retired == nil)
        #expect(lease.registeredToken == second)
    }

    private func waitForPresentedSurface(from controller: UIViewController) async throws {
        for _ in 0..<200 {
            if controller.presentedViewController != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PresentationActivityHostedError.presentationTimedOut
    }

    private func dismissPresentedSurface(from controller: UIViewController) async {
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
    }

    private func waitForProbeTokenCount(
        _ expected: Int,
        state: ManagedInteractionProbeState
    ) async throws {
        for _ in 0..<200 {
            if state.tokens.count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PresentationActivityHostedError.probeTimedOut(expected: expected, actual: state.tokens.count)
    }

    private func waitForSurfaceCount(
        _ expected: Int,
        coordinator: PresentationActivityCoordinator
    ) async throws {
        for _ in 0..<200 {
            if coordinator.mountedSurfaceCount == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PresentationActivityHostedError.timedOut(
            expected: expected,
            actual: coordinator.mountedSurfaceCount
        )
    }

    @Test("duplicate lifecycle callbacks are harmless")
    func lifecycleCallbacksAreIdempotent() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "root", generation: UUID())
        coordinator.register(root, parent: nil)
        coordinator.register(root, parent: nil)
        coordinator.retire(root)
        coordinator.retire(root)
        #expect(coordinator.mountedSurfaceCount == 0)
    }
}

@MainActor
@Observable
private final class ManagedInteractionProbeState {
    var interaction: ExtensionInteraction?
    private(set) var tokens: [PresentationSurfaceToken] = []
    private(set) var publishedCount = 0

    func record(_ token: PresentationSurfaceToken?) {
        guard let token, tokens.last != token else { return }
        tokens.append(token)
    }

    func publishIfAllowed(_ token: PresentationSurfaceToken, coordinator: PresentationActivityCoordinator) {
        guard coordinator.activity(for: token).allowsPresentationPublication else { return }
        publishedCount += 1
    }
}

private struct ManagedInteractionProbeView: View {
    let sessionID: String
    @Bindable var state: ManagedInteractionProbeState

    var body: some View {
        Color.clear
            .tronManagedSheet(
                item: $state.interaction,
                identity: { ExtensionInteractionPresentationIdentity.value(sessionID: sessionID, interaction: $0) }
            ) { interaction in
                ManagedInteractionTokenProbe(interaction: interaction, state: state)
            }
    }
}

private struct ManagedInteractionTokenProbe: View {
    let interaction: ExtensionInteraction
    let state: ManagedInteractionProbeState
    @Environment(\.tronPresentationSurfaceToken) private var token

    var body: some View {
        Color.clear
            .accessibilityLabel(interaction.title)
            .onAppear { state.record(token) }
            .onChange(of: token) { _, updated in state.record(updated) }
    }
}

@MainActor
@Observable
private final class PresentationActivityHostedState {
    var sheetPresented = false
    var systemPresented = false
}

private struct PresentationActivityHostedView: View {
    @Bindable var state: PresentationActivityHostedState

    var body: some View {
        TronPresentationSurface(id: "hosted.root") {
            Color.clear
                .tronManagedSheet(
                    isPresented: $state.sheetPresented,
                    identity: "hosted.sheet"
                ) {
                    Text("Hosted sheet")
                }
                .tronManagedSystemPresentation(
                    isPresented: $state.systemPresented,
                    identity: "hosted.system"
                )
        }
    }
}

private enum PresentationActivityHostedError: Error {
    case presentationTimedOut
    case timedOut(expected: Int, actual: Int)
    case probeTimedOut(expected: Int, actual: Int)
}
