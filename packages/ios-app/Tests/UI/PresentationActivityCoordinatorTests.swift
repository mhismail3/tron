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
        state.sheetPresented = false
        await Task.yield()
        controller.presentedViewController?.dismiss(animated: false)
        try await waitForSurfaceCount(1, coordinator: coordinator)

        state.systemPresented = true
        try await waitForSurfaceCount(2, coordinator: coordinator)
        state.systemPresented = false
        try await waitForSurfaceCount(1, coordinator: coordinator)
    }

    @Test("only the topmost registered surface is active")
    func topmostSurfaceWins() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "dashboard", generation: UUID())
        let child = PresentationSurfaceToken(id: "settings", generation: UUID())
        coordinator.register(root, parent: nil)
        coordinator.register(child, parent: root)
        #expect(coordinator.activity(for: root) == .covered)
        #expect(coordinator.activity(for: child) == .active)
    }

    @Test("a child remains active when binding intent registers before its parent appears")
    func topologyWinsOverCallbackOrder() {
        let coordinator = PresentationActivityCoordinator()
        let root = PresentationSurfaceToken(id: "root", generation: UUID())
        let child = PresentationSurfaceToken(id: "child", generation: UUID())
        coordinator.register(child, parent: root)
        coordinator.register(root, parent: nil)
        #expect(coordinator.activity(for: root) == .covered)
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

    @Test("continuous clocks require active surface, scene, and viewport")
    func continuousClockPolicy() {
        #expect(PresentationClockPolicy.runs(
            surfaceActive: true,
            sceneActive: true,
            viewportVisible: true
        ))
        #expect(!PresentationClockPolicy.runs(
            surfaceActive: false,
            sceneActive: true,
            viewportVisible: true
        ))
        #expect(!PresentationClockPolicy.runs(
            surfaceActive: true,
            sceneActive: false,
            viewportVisible: true
        ))
        #expect(!PresentationClockPolicy.runs(
            surfaceActive: true,
            sceneActive: true,
            viewportVisible: false
        ))
    }

    @Test("presentation activity participates in disposable task identity")
    func presentationTaskIdentityChangesAcrossCoverage() {
        let active = PresentationActivityTaskID(source: "load", presentationActive: true)
        let covered = PresentationActivityTaskID(source: "load", presentationActive: false)
        #expect(active != covered)
        #expect(active == PresentationActivityTaskID(source: "load", presentationActive: true))
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
    case timedOut(expected: Int, actual: Int)
}
