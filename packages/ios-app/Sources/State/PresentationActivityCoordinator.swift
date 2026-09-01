import Foundation
import Observation
import SwiftUI

/// Rendering activity is intentionally independent from Gateway/session
/// authority. The topmost surface owns animation and viewport work; its
/// mounted ancestors continue publishing the bounded state consumed by that
/// visible descendant. Unrelated covered branches suppress presentation work.
struct PresentationSurfaceActivity: Equatable, Sendable {
    /// Bounded parent data needed by the visible surface, such as the exact
    /// tool payload selected by a descendant detail sheet.
    let allowsDataPublication: Bool
    /// Surface-owned loads, polls, and automatic presentation effects.
    let allowsPresentationPublication: Bool
    let allowsContinuousAnimation: Bool
    let allowsViewportObservation: Bool

    static let active = Self(
        allowsDataPublication: true,
        allowsPresentationPublication: true,
        allowsContinuousAnimation: true,
        allowsViewportObservation: true
    )

    static let presentingDescendant = Self(
        allowsDataPublication: true,
        allowsPresentationPublication: false,
        allowsContinuousAnimation: false,
        allowsViewportObservation: false
    )

    static let covered = Self(
        allowsDataPublication: false,
        allowsPresentationPublication: false,
        allowsContinuousAnimation: false,
        allowsViewportObservation: false
    )
}

struct PresentationSurfaceToken: Hashable, Sendable {
    let id: String
    let generation: UUID
}

/// Restarts one disposable view task when its surface changes activity without
/// coupling the task's domain-specific source identity to presentation state.
struct PresentationActivityTaskID<Source: Hashable>: Hashable {
    let source: Source
    let presentationActive: Bool
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

/// Owns only the mounted presentation topology. Session authority, transport,
/// mutations, persistence, and synchronization must never depend on this owner.
@MainActor
@Observable
final class PresentationActivityCoordinator {
    private struct Surface {
        let parent: PresentationSurfaceToken?
    }

    private static let retiredTokenLimit = 512

    private var surfaces: [PresentationSurfaceToken: Surface] = [:]
    private var order: [PresentationSurfaceToken] = []
    /// A dismissal can retire binding intent before delayed SwiftUI content
    /// appears. Keep an exact, bounded tombstone ledger so that late content—or
    /// a late child of that content—cannot escape as a new independent branch.
    private var retiredTokens: Set<PresentationSurfaceToken> = []
    private var retiredTokenOrder: [PresentationSurfaceToken] = []

    /// Registration is idempotent so binding intent and mounted content can
    /// both establish the same generation without creating duplicate leases.
    func register(_ token: PresentationSurfaceToken, parent: PresentationSurfaceToken?) {
        guard surfaces[token] == nil,
              !retiredTokens.contains(token),
              parent.map({ !retiredTokens.contains($0) }) ?? true else { return }
        surfaces[token] = Surface(parent: parent)
        order.append(token)
    }

    /// Retires one exact generation and every mounted descendant. A delayed
    /// callback from an earlier route cannot affect its replacement.
    func retire(_ token: PresentationSurfaceToken) {
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
        if isDescendant(topmostToken, of: token) { return .presentingDescendant }
        return .covered
    }

    var mountedSurfaceCount: Int { order.count }

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

/// Registers a navigation/root surface for exactly the lifetime of its mounted
/// content and resolves activity for all descendants.
struct TronPresentationSurface<Content: View>: View {
    private let id: String
    private let suppliedToken: PresentationSurfaceToken?
    private let registersLifecycle: Bool
    private let onMount: ((PresentationSurfaceToken) -> Void)?
    private let onRetire: ((PresentationSurfaceToken) -> Void)?
    @ViewBuilder private let content: () -> Content
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var inheritedParent
    private let explicitParent: PresentationSurfaceToken?
    @State private var generation = UUID()

    init(
        id: String,
        onMount: ((PresentationSurfaceToken) -> Void)? = nil,
        onRetire: ((PresentationSurfaceToken) -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        suppliedToken = nil
        registersLifecycle = true
        self.onMount = onMount
        self.onRetire = onRetire
        explicitParent = nil
        self.content = content
    }

    fileprivate init(
        token: PresentationSurfaceToken,
        parent: PresentationSurfaceToken?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        id = token.id
        suppliedToken = token
        registersLifecycle = false
        onMount = nil
        onRetire = nil
        explicitParent = parent
        self.content = content
    }

    private var token: PresentationSurfaceToken {
        suppliedToken ?? PresentationSurfaceToken(id: id, generation: generation)
    }

    var body: some View {
        content()
            .environment(\.tronPresentationSurfaceToken, token)
            .environment(
                \.tronPresentationActivity,
                coordinator?.activity(for: token) ?? .active
            )
            .onAppear {
                coordinator?.register(token, parent: explicitParent ?? inheritedParent)
                if registersLifecycle { onMount?(token) }
            }
            .onDisappear {
                if registersLifecycle {
                    coordinator?.retire(token)
                    onRetire?(token)
                }
            }
    }
}

struct PresentationDismissalLease: Equatable {
    struct Transition: Equatable {
        let retired: PresentationSurfaceToken?
        let registered: PresentationSurfaceToken?
    }

    private(set) var generation = UUID()
    private(set) var registeredToken: PresentationSurfaceToken?
    private(set) var dismissingToken: PresentationSurfaceToken?

    func contentToken(identity: String) -> PresentationSurfaceToken {
        if let registeredToken, registeredToken.id == identity { return registeredToken }
        if let dismissingToken, dismissingToken.id == identity { return dismissingToken }
        return PresentationSurfaceToken(id: identity, generation: generation)
    }

    mutating func register(identity: String) -> PresentationSurfaceToken? {
        guard registeredToken == nil, dismissingToken == nil else { return nil }
        let token = PresentationSurfaceToken(id: identity, generation: generation)
        registeredToken = token
        return token
    }

    mutating func replace(identity: String) -> Transition {
        guard dismissingToken == nil else { return Transition(retired: nil, registered: nil) }
        guard registeredToken?.id != identity else {
            return Transition(retired: nil, registered: nil)
        }
        let retired = registeredToken
        registeredToken = nil
        generation = UUID()
        return Transition(retired: retired, registered: register(identity: identity))
    }

    mutating func beginDismissal() {
        guard dismissingToken == nil, let registeredToken else { return }
        dismissingToken = registeredToken
        self.registeredToken = nil
    }

    mutating func completeDismissal(nextIdentity: String?) -> Transition {
        guard let retired = dismissingToken else {
            return Transition(retired: nil, registered: nil)
        }
        dismissingToken = nil
        generation = UUID()
        let registered = nextIdentity.flatMap { register(identity: $0) }
        return Transition(retired: retired, registered: registered)
    }

    mutating func retireAll() -> [PresentationSurfaceToken] {
        let tokens = [registeredToken, dismissingToken].compactMap { $0 }
        registeredToken = nil
        dismissingToken = nil
        generation = UUID()
        return tokens
    }
}

private struct TronManagedSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let identity: String
    let onDismiss: (() -> Void)?
    @ViewBuilder let sheetContent: () -> SheetContent
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var parent
    @State private var lease = PresentationDismissalLease()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: didDismiss) {
                TronPresentationSurface(token: lease.contentToken(identity: identity), parent: parent) {
                    sheetContent()
                }
            }
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    registerIfPossible()
                } else {
                    lease.beginDismissal()
                }
            }
            .onDisappear { retireAllTokens() }
    }

    private func registerIfPossible() {
        if let token = lease.register(identity: identity) {
            coordinator?.register(token, parent: parent)
        }
    }

    private func didDismiss() {
        if lease.dismissingToken == nil, !isPresented { lease.beginDismissal() }
        let transition = lease.completeDismissal(nextIdentity: isPresented ? identity : nil)
        apply(transition)
        if !isPresented, transition.retired != nil { onDismiss?() }
    }

    private func apply(_ transition: PresentationDismissalLease.Transition) {
        if let retired = transition.retired { coordinator?.retire(retired) }
        if let registered = transition.registered {
            coordinator?.register(registered, parent: parent)
        }
    }

    private func retireAllTokens() {
        for token in lease.retireAll() { coordinator?.retire(token) }
    }
}

private struct TronManagedItemSheetModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let identity: (Item) -> String
    let onDismiss: (() -> Void)?
    @ViewBuilder let sheetContent: (Item) -> SheetContent
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var parent
    @State private var lease = PresentationDismissalLease()

    func body(content: Content) -> some View {
        content
            .sheet(item: $item, onDismiss: didDismiss) { value in
                TronPresentationSurface(token: lease.contentToken(identity: identity(value)), parent: parent) {
                    sheetContent(value)
                }
            }
            .onChange(of: item?.id, initial: true) { _, _ in itemChanged() }
            .onDisappear { retireAllTokens() }
    }

    private func itemChanged() {
        guard let item else {
            lease.beginDismissal()
            return
        }
        let itemIdentity = identity(item)
        if lease.registeredToken == nil {
            if let token = lease.register(identity: itemIdentity) {
                coordinator?.register(token, parent: parent)
            }
        } else {
            apply(lease.replace(identity: itemIdentity))
        }
    }

    private func didDismiss() {
        if lease.dismissingToken == nil, item == nil { lease.beginDismissal() }
        let transition = lease.completeDismissal(nextIdentity: item.map(identity))
        apply(transition)
        if item == nil, transition.retired != nil { onDismiss?() }
    }

    private func apply(_ transition: PresentationDismissalLease.Transition) {
        if let retired = transition.retired { coordinator?.retire(retired) }
        if let registered = transition.registered {
            coordinator?.register(registered, parent: parent)
        }
    }

    private func retireAllTokens() {
        for token in lease.retireAll() { coordinator?.retire(token) }
    }
}

/// Registers system-owned presentations whose content cannot be wrapped, such
/// as photo and document pickers. Their bindings become false after dismissal.
private struct TronManagedSystemPresentationModifier: ViewModifier {
    @Binding var isPresented: Bool
    let identity: String
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var parent
    @State private var generation = UUID()
    @State private var registered = false

    private var token: PresentationSurfaceToken {
        PresentationSurfaceToken(id: identity, generation: generation)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    coordinator?.register(token, parent: parent)
                    registered = true
                } else if registered {
                    coordinator?.retire(token)
                    registered = false
                    generation = UUID()
                }
            }
            .onDisappear {
                if registered { coordinator?.retire(token) }
                registered = false
            }
    }
}

extension View {
    func tronManagedSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        identity: String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(TronManagedSheetModifier(
            isPresented: isPresented,
            identity: identity,
            onDismiss: onDismiss,
            sheetContent: content
        ))
    }

    func tronManagedSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        identity: @escaping (Item) -> String,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(TronManagedItemSheetModifier(
            item: item,
            identity: identity,
            onDismiss: onDismiss,
            sheetContent: content
        ))
    }

    func tronManagedSystemPresentation(
        isPresented: Binding<Bool>,
        identity: String
    ) -> some View {
        modifier(TronManagedSystemPresentationModifier(
            isPresented: isPresented,
            identity: identity
        ))
    }

    func tronPresentationSurface(
        id: String,
        onMount: ((PresentationSurfaceToken) -> Void)? = nil,
        onRetire: ((PresentationSurfaceToken) -> Void)? = nil
    ) -> some View {
        TronPresentationSurface(id: id, onMount: onMount, onRetire: onRetire) { self }
    }
}
