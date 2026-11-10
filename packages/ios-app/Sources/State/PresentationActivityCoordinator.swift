import Foundation
import Observation
import SwiftUI

struct PresentationSurfaceActivity: Equatable, Sendable {
    let allowsDataPublication: Bool
    let allowsPresentationPublication: Bool
    let allowsContinuousAnimation: Bool
    let allowsViewportObservation: Bool

    static let active = Self(allowsDataPublication: true, allowsPresentationPublication: true,
                             allowsContinuousAnimation: true, allowsViewportObservation: true)

    static let presentingDescendant = Self(allowsDataPublication: true, allowsPresentationPublication: false,
                                           allowsContinuousAnimation: false, allowsViewportObservation: false)

    static let presentingViewportDescendant = Self(allowsDataPublication: true, allowsPresentationPublication: false,
                                                   allowsContinuousAnimation: false, allowsViewportObservation: true)

    static let covered = Self(allowsDataPublication: false, allowsPresentationPublication: false,
                              allowsContinuousAnimation: false, allowsViewportObservation: false)
}

struct PresentationSurfaceToken: Hashable, Sendable {
    let id: String
    let generation: UUID
}

struct PresentationActivityTaskID<Source: Hashable>: Hashable {
    let source: Source
    let presentationActive: Bool
}

@MainActor
enum PresentationPublicationPolicy {
    static func allows(
        ambient: PresentationSurfaceActivity,
        coordinator: PresentationActivityCoordinator?,
        token: PresentationSurfaceToken?
    ) -> Bool {
        guard let coordinator else { return ambient.allowsPresentationPublication }
        guard let token else { return false }
        return coordinator.activity(for: token).allowsPresentationPublication
    }
}

enum PresentationClockPolicy {
    static func runs(
        surfaceActive: Bool,
        sceneActive: Bool,
        viewportVisible: Bool = true
    ) -> Bool {
        surfaceActive && sceneActive && viewportVisible
    }
}

@MainActor
@Observable
final class PresentationActivityCoordinator {
    private struct Surface {
        let parent: PresentationSurfaceToken?
        let dependencies: Set<PresentationRefreshDependency>
        let keepsParentViewport: Bool
    }

    private static let retiredTokenLimit = 512
    private var surfaces: [PresentationSurfaceToken: Surface] = [:]
    private var order: [PresentationSurfaceToken] = []
    private var retiredTokens: Set<PresentationSurfaceToken> = []
    private var retiredTokenOrder: [PresentationSurfaceToken] = []

    func register(_ token: PresentationSurfaceToken, parent: PresentationSurfaceToken?,
                  dependencies: Set<PresentationRefreshDependency>? = nil, keepsParentViewport: Bool = false) {
        guard surfaces[token] == nil,
              !retiredTokens.contains(token),
              parent.map({ !retiredTokens.contains($0) }) ?? true else { return }
        #if HOSTED_TEST
        HostedPresentationProbe.record?("register", "\(token.id)#\(token.generation) parent=\(parent?.id ?? "root")")
        #endif
        surfaces[token] = Surface(parent: parent, dependencies: dependencies
            ?? refreshDependencies(for: parent).filter { $0 != .sessionCatalog },
            keepsParentViewport: keepsParentViewport)
        order.append(token)
    }

    func retire(_ token: PresentationSurfaceToken) {
        #if HOSTED_TEST
        HostedPresentationProbe.record?("retire", "\(token.id)#\(token.generation)")
        #endif
        let descendants = order.filter { candidate in
            candidate == token || isDescendant(candidate, of: token)
        }
        let retired = Set(descendants).union([token])
        for retiredToken in retired {
            surfaces.removeValue(forKey: retiredToken)
            rememberRetired(retiredToken)
        }
        order.removeAll { retired.contains($0) }
    }

    func activity(for token: PresentationSurfaceToken?) -> PresentationSurfaceActivity {
        guard let token else { return .active }
        guard surfaces[token] != nil, let topmostToken else { return .covered }
        if topmostToken == token { return .active }
        if let topmost = surfaces[topmostToken], topmost.parent == token, topmost.keepsParentViewport {
            return .presentingViewportDescendant
        }
        if isDescendant(topmostToken, of: token) { return .presentingDescendant }
        return .covered
    }

    func hasMountedDescendant(id: String, of parent: PresentationSurfaceToken?) -> Bool {
        guard let parent, surfaces[parent] != nil else { return false }
        return order.contains { $0.id == id && isDescendant($0, of: parent) }
    }

    func refreshDependencies(for token: PresentationSurfaceToken?) -> Set<PresentationRefreshDependency> {
        token.flatMap { surfaces[$0]?.dependencies } ?? []
    }

    func requiresSessionRefresh(_ sessionID: String) -> Bool {
        guard let topmostToken else { return true }
        return refreshDependencies(for: topmostToken).contains { $0.requiresSession(sessionID) }
    }

    func requiresSessionCatalogRefresh() -> Bool {
        guard let topmostToken else { return true }
        return refreshDependencies(for: topmostToken).contains(.sessionCatalog)
    }

    private func rememberRetired(_ token: PresentationSurfaceToken) {
        guard retiredTokens.insert(token).inserted else { return }
        retiredTokenOrder.append(token)
        let excess = retiredTokenOrder.count - Self.retiredTokenLimit
        guard excess > 0 else { return }
        for expired in retiredTokenOrder.prefix(excess) { retiredTokens.remove(expired) }
        retiredTokenOrder.removeFirst(excess)
    }

    private var topmostToken: PresentationSurfaceToken? {
        order.reversed().first { candidate in
            !order.contains { $0 != candidate && isDescendant($0, of: candidate) }
        }
    }

    private func isDescendant(
        _ candidate: PresentationSurfaceToken,
        of ancestor: PresentationSurfaceToken
    ) -> Bool {
        var current = surfaces[candidate]?.parent
        var visited = Set<PresentationSurfaceToken>()
        while let parent = current, visited.insert(parent).inserted {
            if parent == ancestor { return true }
            current = surfaces[parent]?.parent
        }
        return false
    }
}

private struct PresentationSurfaceTokenKey: EnvironmentKey {
    static let defaultValue: PresentationSurfaceToken? = nil
}

private struct PresentationActivityCoordinatorKey: EnvironmentKey {
    static let defaultValue: PresentationActivityCoordinator? = nil
}

private struct PresentationSurfaceActivityKey: EnvironmentKey {
    static let defaultValue = PresentationSurfaceActivity.active
}

extension EnvironmentValues {
    var tronPresentationActivityCoordinator: PresentationActivityCoordinator? {
        get { self[PresentationActivityCoordinatorKey.self] }
        set { self[PresentationActivityCoordinatorKey.self] = newValue }
    }

    var tronPresentationSurfaceToken: PresentationSurfaceToken? {
        get { self[PresentationSurfaceTokenKey.self] }
        set { self[PresentationSurfaceTokenKey.self] = newValue }
    }

    var tronPresentationActivity: PresentationSurfaceActivity {
        get { self[PresentationSurfaceActivityKey.self] }
        set { self[PresentationSurfaceActivityKey.self] = newValue }
    }
}

struct TronPresentationActivityReader<Content: View>: View {
    @Environment(\.tronPresentationActivity) private var activity
    @ViewBuilder let content: (PresentationSurfaceActivity) -> Content

    var body: some View { content(activity) }
}

struct TronPresentationSurface<Content: View>: View {
    private let id: String
    private let suppliedToken: PresentationSurfaceToken?
    private let registersLifecycle: Bool
    private let dependencies: Set<PresentationRefreshDependency>?
    private let onMount: ((PresentationSurfaceToken) -> Void)?
    private let onRetire: ((PresentationSurfaceToken) -> Void)?
    @ViewBuilder private let content: () -> Content
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var inheritedParent
    @Environment(\.tronPresentationStateStore) private var stateStore
    @Environment(\.tronPresentationStateScope) private var inheritedStateScope
    @Environment(\.tronPresentationDependencyRead) private var dependencyRead
    @Environment(\.scenePhase) private var scenePhase
    private let explicitParent: PresentationSurfaceToken?
    private let keepsParentViewport: Bool
    @State private var generation = UUID()

    init(
        id: String,
        dependencies: Set<PresentationRefreshDependency>? = nil,
        onMount: ((PresentationSurfaceToken) -> Void)? = nil,
        onRetire: ((PresentationSurfaceToken) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.dependencies = dependencies
        suppliedToken = nil
        registersLifecycle = true
        self.onMount = onMount
        self.onRetire = onRetire
        explicitParent = nil
        keepsParentViewport = false
        self.content = content
    }

    init(
        token: PresentationSurfaceToken,
        parent: PresentationSurfaceToken?,
        keepsParentViewport: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        id = token.id
        dependencies = nil
        suppliedToken = token
        registersLifecycle = false
        onMount = nil
        onRetire = nil
        explicitParent = parent
        self.keepsParentViewport = keepsParentViewport
        self.content = content
    }

    private var token: PresentationSurfaceToken {
        suppliedToken ?? PresentationSurfaceToken(id: id, generation: generation)
    }

    private var statePath: String {
        PresentationStateStore.path(parent: inheritedStateScope, identity: "surface:\(id)#\(generation)")
    }

    private var stateScope: PresentationStateScope? {
        guard registersLifecycle, let stateStore else { return inheritedStateScope }
        return stateStore.scope(path: statePath)
    }

    var body: some View {
        #if HOSTED_TEST
        let _ = HostedPresentationProbe.record?("body", "\(token.id)#\(token.generation)")
        #endif
        content()
            .environment(\.tronSettingsSectionCount, nil)
            .modifier(TronSheetLoadingHostModifier())
            .modifier(TronNativeSheetCanvas(role: registersLifecycle ? .route : .sheet))
            #if HOSTED_TEST
            .background { HostedPresentationProbe.nativeView?(token.id) }
            .transaction { transaction in
                if ProcessInfo.processInfo.environment["TRON_UI_LOCK_RENDERING"] == "1" {
                    transaction.disablesAnimations = true
                }
            }
            #endif
            .environment(\.tronPresentationStateScope, stateScope)
            .environment(\.tronPresentationSurfaceToken, token)
            .environment(
                \.tronPresentationActivity,
                scenePhase == .active ? (coordinator?.activity(for: token) ?? .active) : .covered
            )
            .task(id: PresentationActivityTaskID(source: dependencyRead?.id,
                presentationActive: coordinator?.activity(for: token).allowsPresentationPublication == true && scenePhase == .active)) {
                guard scenePhase == .active, coordinator?.activity(for: token).allowsPresentationPublication == true else { return }
                await dependencyRead?.perform()
            }
            .onAppear {
                #if HOSTED_TEST
                HostedPresentationProbe.record?("appear", "\(token.id)#\(token.generation)")
                #endif
                coordinator?.register(token, parent: explicitParent ?? inheritedParent, dependencies: dependencies,
                                      keepsParentViewport: keepsParentViewport)
                if registersLifecycle { onMount?(token) }
            }
            .onDisappear {
                #if HOSTED_TEST
                HostedPresentationProbe.record?("disappear", "\(token.id)#\(token.generation)")
                #endif
                if registersLifecycle {
                    coordinator?.retire(token)
                    stateStore?.retire(path: statePath)
                    onRetire?(token)
                }
            }
    }
}
