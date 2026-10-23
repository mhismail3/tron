import Foundation
import OSLog
import SwiftUI

struct PresentationDismissalLease: Equatable {
    struct Transition: Equatable {
        let retired: PresentationSurfaceToken?
        let registered: PresentationSurfaceToken?
        /// The retired presentation was requested but its content never appeared.
        var neverAppeared: PresentationSurfaceToken? = nil
    }

    private(set) var generation = UUID()
    private(set) var registeredToken: PresentationSurfaceToken?
    private(set) var dismissingToken: PresentationSurfaceToken?
    /// A presentation a live request registered whose content has not appeared
    /// yet. The sheet haptic plays when that content appears, so a refused or
    /// deferred presentation is silent until it actually happens (#1695).
    private(set) var awaitingAppearance: PresentationSurfaceToken?

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
        let neverAppeared = endAppearance(of: retired.map { [$0] } ?? [])
        return Transition(retired: retired, registered: register(identity: identity), neverAppeared: neverAppeared)
    }

    /// A live request (not a restored or replaced presentation) opened `token`.
    mutating func expectAppearance(of token: PresentationSurfaceToken?) {
        if let token { awaitingAppearance = token }
    }

    /// True once, when the content of the presentation a live request opened appears.
    mutating func contentAppeared(_ token: PresentationSurfaceToken) -> Bool {
        guard awaitingAppearance == token else { return false }
        awaitingAppearance = nil
        return true
    }

    /// Ends the wait for `tokens`; returns the one whose content never appeared.
    private mutating func endAppearance(of tokens: [PresentationSurfaceToken]) -> PresentationSurfaceToken? {
        guard let awaiting = awaitingAppearance, tokens.contains(awaiting) else { return nil }
        awaitingAppearance = nil
        return awaiting
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
        let neverAppeared = endAppearance(of: [retired])
        let registered = nextIdentity.flatMap { register(identity: $0) }
        return Transition(retired: retired, registered: registered, neverAppeared: neverAppeared)
    }

    mutating func retireAll() -> (tokens: [PresentationSurfaceToken], neverAppeared: PresentationSurfaceToken?) {
        let tokens = [registeredToken, dismissingToken].compactMap { $0 }
        registeredToken = nil
        dismissingToken = nil
        generation = UUID()
        return (tokens, endAppearance(of: tokens))
    }
}

/// The live views that resolve to one presenter key in one presentation scope.
/// Presenter state is keyed by call site (plus the identity string and
/// `instance:`) so it survives a sheet content rebuild (#1073); a presenter
/// repeated in one scope without a distinct key shares that state, and only the
/// last-rendered sibling can present (#1652, #1656). Sharing is a programming
/// error reported the moment one of them starts presenting.
/// Faults a managed presenter reports: programming errors and presentations
/// that were requested but never shown (see State README Signals).
enum ManagedSheetPresentationSignal {
    private static let logger = Logger(subsystem: "com.tron.mobile", category: "ManagedSheetPresentation")

    /// A live request registered a presentation that retired before its content
    /// ever appeared: the user asked for a sheet and saw nothing (#1695).
    @MainActor static func neverAppeared(_ token: PresentationSurfaceToken?, site: String) {
        guard let token else { return }
        #if HOSTED_TEST
        HostedPresentationProbe.record?("never-appeared", "\(token.id)@\(site)")
        #endif
        logger.fault("managed-sheet.never-appeared identity=\(token.id, privacy: .public) site=\(site, privacy: .public)")
    }

    static func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
    }
}

@MainActor
final class ManagedSheetPresenterClaims {
    private var live: Set<UUID> = []

    func appear(_ claimant: UUID) { live.insert(claimant) }
    func disappear(_ claimant: UUID) { live.remove(claimant) }

    func willPresent(site: String) {
        guard live.count > 1 else { return }
        let message = "Managed sheet presenter \(site) is shared by \(live.count) live views; a repeated presenter needs a distinct identity or instance:"
        ManagedSheetPresentationSignal.fault(message)
        #if HOSTED_TEST
        preconditionFailure(message)
        #endif
    }
}

private struct TronManagedSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let identity: String
    let dependencies: Set<PresentationRefreshDependency>?
    /// The presenting call site: two presenters that share an identity string
    /// still keep separate presentation state.
    let site: String
    let onDismiss: (() -> Void)?
    let haptic: TronHaptic?
    @ViewBuilder let sheetContent: () -> SheetContent
    // Snapshot forwarding does not subscribe to these changing render inputs.
    @Environment(\.tronPresentationDependencyRead) private var nativeDependencyRead
    @Environment(\.scenePhase) private var nativeScenePhase
    @Environment(\.self) private var nativeEnvironment
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var parent
    @Environment(\.tronPresentationStateStore) private var sceneStateStore
    @Environment(\.tronPresentationStateScope) private var parentStateScope
    @PresentationState private var lease: PresentationDismissalLease
    @PresentationState private var nativeHost = RetainedNativeSheetHost()
    @PresentationState private var claims: ManagedSheetPresenterClaims
    @State private var claimant = UUID() // view-local: this view's claim on the shared key
    @State private var localStateStore = PresentationStateStore() // view-local: standalone fallback outside a scene store

    init(isPresented: Binding<Bool>, identity: String, dependencies: Set<PresentationRefreshDependency>?, site: String, onDismiss: (() -> Void)?,
         haptic: TronHaptic?, sheetContent: @escaping () -> SheetContent) {
        _isPresented = isPresented
        self.identity = identity
        self.dependencies = dependencies
        self.site = site
        self.onDismiss = onDismiss
        self.haptic = haptic
        self.sheetContent = sheetContent
        _lease = PresentationState(wrappedValue: PresentationDismissalLease(), key: "presenter:\(identity)@\(site)")
        _nativeHost = PresentationState(wrappedValue: RetainedNativeSheetHost(), key: "native:\(identity)@\(site)")
        _claims = PresentationState(wrappedValue: ManagedSheetPresenterClaims(), key: "claims:\(identity)@\(site)")
    }

    private var stateStore: PresentationStateStore { sceneStateStore ?? localStateStore }
    private var statePath: String { PresentationStateStore.path(parent: parentStateScope, identity: "\(identity)@\(site)") }

    func body(content: Content) -> some View {
        var environment = nativeEnvironment
        environment.scenePhase = nativeScenePhase
        environment.tronPresentationDependencyRead = nativeDependencyRead
        // Install the native node while idle: the first request must change
        // an existing sheet binding, not insert an already-presenting graph
        // into a surface whose own presentation may still be settling.
        let source = NativeSheetSource(
            owner: nativeHost,
            content: AnyView(Color.clear.accessibilityHidden(true).sheet(isPresented: $isPresented, onDismiss: didDismiss) {
                let token = lease.contentToken(identity: identity)
                TronPresentationSurface(token: token, parent: parent) {
                    sheetContent().environment(\.chatOwnsStatusBar, false)
                }
                .environment(\.tronPresentationStateScope, stateStore.scope(path: statePath))
                .onAppear { contentAppeared(token) }
            }),
            environment: environment,
            onRemoval: sourceDidDisappear
        )
        return content
            .transformPreference(NativeSheetSources.self) { sources in
                sources.append(source)
            }
            // Only a live false → true request plays, once its content appears: a
            // sheet already presented when its presenter mounts (launch, reconnect,
            // rebuild) is silent, and so is a request UIKit has not presented.
            .onChange(of: isPresented, initial: true) { wasPresented, presented in
                #if HOSTED_TEST
                HostedPresentationProbe.record?("binding", "\(identity) \(wasPresented)→\(presented) parent=\(parentStateScope?.path ?? "nil")")
                #endif
                if presented {
                    if !wasPresented { claims.willPresent(site: "\(identity)@\(site)") }
                    registerIfPossible(live: !wasPresented)
                } else {
                    lease.beginDismissal()
                }
            }
            .onPresentationRetire(fileID: "native-source:\(identity)@\(site)", line: 0, perform: sourceDidDisappear)
            .onAppear { claims.appear(claimant) }
            .onDisappear { claims.disappear(claimant) }
    }

    private func sourceDidDisappear() {
        if isPresented { isPresented = false }
        retireAllTokens()
        stateStore.retire(path: statePath)
        if nativeHost.isInstalled {
            nativeHost.presentationDidRetire()
            nativeHost = RetainedNativeSheetHost()
        }
    }

    private func registerIfPossible(live: Bool) {
        if let token = lease.register(identity: identity) {
            coordinator?.register(token, parent: parent, dependencies: dependencies)
            if live { lease.expectAppearance(of: token) }
        }
    }

    private func contentAppeared(_ token: PresentationSurfaceToken) {
        if lease.contentAppeared(token), let haptic { TronHaptics.shared.play(haptic) }
    }

    private func didDismiss() {
        #if HOSTED_TEST
        HostedPresentationProbe.record?("native-dismiss", "\(identity) presented=\(isPresented) source-attached=\(nativeHost.isAttached)")
        #endif
        if lease.dismissingToken == nil, !isPresented { lease.beginDismissal() }
        let transition = lease.completeDismissal(nextIdentity: isPresented ? identity : nil)
        apply(transition)
        // A request made while the previous sheet was leaving presents now.
        lease.expectAppearance(of: transition.registered)
        // Only an actual dismissal ends the presentation's state.
        if !isPresented { stateStore.retire(path: statePath) }
        if !isPresented, transition.retired != nil { onDismiss?() }
    }

    private func apply(_ transition: PresentationDismissalLease.Transition) {
        ManagedSheetPresentationSignal.neverAppeared(transition.neverAppeared, site: site)
        if let retired = transition.retired { coordinator?.retire(retired) }
        if let registered = transition.registered {
            coordinator?.register(registered, parent: parent, dependencies: dependencies)
        }
    }

    private func retireAllTokens() {
        let retired = lease.retireAll()
        ManagedSheetPresentationSignal.neverAppeared(retired.neverAppeared, site: site)
        for token in retired.tokens { coordinator?.retire(token) }
    }
}

private struct TronManagedItemSheetModifier<Item: Identifiable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let dependencies: ((Item) -> Set<PresentationRefreshDependency>)?
    let identity: (Item) -> String
    let site: String
    let onDismiss: (() -> Void)?
    let haptic: TronHaptic?
    @ViewBuilder let sheetContent: (Item) -> SheetContent
    // Observe activation/freshness even when the source's other inputs stay equal.
    @Environment(\.tronPresentationDependencyRead) private var nativeDependencyRead
    @Environment(\.scenePhase) private var nativeScenePhase
    @Environment(\.self) private var nativeEnvironment
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var parent
    @Environment(\.tronPresentationStateStore) private var sceneStateStore
    @Environment(\.tronPresentationStateScope) private var parentStateScope
    @PresentationState private var lease: PresentationDismissalLease
    @PresentationState private var nativeHost = RetainedNativeSheetHost()
    @PresentationState private var claims: ManagedSheetPresenterClaims
    @State private var claimant = UUID() // view-local: this view's claim on the shared key
    @State private var localStateStore = PresentationStateStore() // view-local: standalone fallback outside a scene store
    /// The identity whose state scope this presenter last showed, so a
    /// replacement or dismissal retires exactly that scope.
    @PresentationState private var presentedStatePath: String?

    init(item: Binding<Item?>, identity: @escaping (Item) -> String, dependencies: ((Item) -> Set<PresentationRefreshDependency>)?, site: String,
         onDismiss: (() -> Void)?, haptic: TronHaptic?, sheetContent: @escaping (Item) -> SheetContent) {
        _item = item
        self.identity = identity
        self.dependencies = dependencies
        self.site = site
        self.onDismiss = onDismiss
        self.haptic = haptic
        self.sheetContent = sheetContent
        _lease = PresentationState(wrappedValue: PresentationDismissalLease(), key: "presenter@\(site)")
        _nativeHost = PresentationState(wrappedValue: RetainedNativeSheetHost(), key: "native@\(site)")
        _presentedStatePath = PresentationState(wrappedValue: nil, key: "presented-path@\(site)")
        _claims = PresentationState(wrappedValue: ManagedSheetPresenterClaims(), key: "claims@\(site)")
    }

    private var stateStore: PresentationStateStore { sceneStateStore ?? localStateStore }
    /// The item's own identity is part of the path: a presenter whose identity
    /// string is constant still gives a different item a fresh state.
    private func statePath(_ value: Item) -> String {
        PresentationStateStore.path(parent: parentStateScope, identity: "\(identity(value))#\(value.id)@\(site)")
    }

    func body(content: Content) -> some View {
        var environment = nativeEnvironment
        environment.scenePhase = nativeScenePhase
        environment.tronPresentationDependencyRead = nativeDependencyRead
        // Keep the native item node installed before its first request too.
        let source = NativeSheetSource(
            owner: nativeHost,
            content: AnyView(Color.clear.accessibilityHidden(true).sheet(item: $item, onDismiss: didDismiss) { value in
                let token = lease.contentToken(identity: identity(value))
                TronPresentationSurface(token: token, parent: parent) {
                    sheetContent(value).environment(\.chatOwnsStatusBar, false)
                }
                .environment(\.tronPresentationStateScope, stateStore.scope(path: statePath(value)))
                .onAppear { if lease.contentAppeared(token), let haptic { TronHaptics.shared.play(haptic) } }
            }),
            environment: environment,
            onRemoval: sourceDidDisappear
        )
        return content
            .transformPreference(NativeSheetSources.self) { sources in
                sources.append(source)
            }
            // Only a live nil → item request plays, once its content appears; replacing
            // a presented item is not a new presentation.
            .onChange(of: item.map(identity), initial: true) { previous, current in
                if previous == nil, current != nil { claims.willPresent(site: site) }
                let registered = itemChanged()
                if previous == nil, current != nil { lease.expectAppearance(of: registered) }
            }
            .onPresentationRetire(fileID: "native-source:\(site)", line: 0, perform: sourceDidDisappear)
            .onAppear { claims.appear(claimant) }
            .onDisappear { claims.disappear(claimant) }
    }

    private func sourceDidDisappear() {
        if item != nil { item = nil }
        retireAllTokens()
        if let presentedStatePath { stateStore.retire(path: presentedStatePath) }
        presentedStatePath = nil
        if nativeHost.isInstalled {
            nativeHost.presentationDidRetire()
            nativeHost = RetainedNativeSheetHost()
        }
    }

    /// Returns the presentation a new item registered, if any.
    private func itemChanged() -> PresentationSurfaceToken? {
        guard let item else {
            lease.beginDismissal()
            return nil
        }
        // A different item replaces the presentation: the old one's state ends.
        let path = statePath(item)
        if let presentedStatePath, presentedStatePath != path { stateStore.retire(path: presentedStatePath) }
        presentedStatePath = path
        let itemIdentity = identity(item)
        if lease.registeredToken == nil {
            guard let token = lease.register(identity: itemIdentity) else { return nil }
            coordinator?.register(token, parent: parent, dependencies: dependencies?(item))
            return token
        }
        let transition = lease.replace(identity: itemIdentity)
        apply(transition)
        // Replacing a request that never appeared is still the first presentation.
        if transition.neverAppeared != nil { lease.expectAppearance(of: transition.registered) }
        return transition.registered
    }

    private func didDismiss() {
        #if HOSTED_TEST
        HostedPresentationProbe.record?("native-dismiss", "\(item.map(identity) ?? "nil") source-attached=\(nativeHost.isAttached)")
        #endif
        if lease.dismissingToken == nil, item == nil { lease.beginDismissal() }
        let transition = lease.completeDismissal(nextIdentity: item.map(identity))
        apply(transition)
        // A request made while the previous sheet was leaving presents now.
        lease.expectAppearance(of: transition.registered)
        if item == nil, let presentedStatePath {
            stateStore.retire(path: presentedStatePath)
            self.presentedStatePath = nil
        }
        if item == nil, transition.retired != nil { onDismiss?() }
    }

    private func apply(_ transition: PresentationDismissalLease.Transition) {
        ManagedSheetPresentationSignal.neverAppeared(transition.neverAppeared, site: site)
        if let retired = transition.retired { coordinator?.retire(retired) }
        if let registered = transition.registered {
            coordinator?.register(registered, parent: parent, dependencies: item.flatMap { dependencies?($0) })
        }
    }

    private func retireAllTokens() {
        let retired = lease.retireAll()
        ManagedSheetPresentationSignal.neverAppeared(retired.neverAppeared, site: site)
        for token in retired.tokens { coordinator?.retire(token) }
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
            .onChange(of: isPresented, initial: true) { wasPresented, presented in
                if presented {
                    coordinator?.register(token, parent: parent)
                    registered = true
                    if !wasPresented { TronHaptics.shared.play(.sheetPresented) }
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
    /// `instance` names a presenter that repeats inside one surface (a chip in
    /// a `ForEach`) when its `identity` does not; see `ManagedSheetPresenterClaims`.
    func tronManagedSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        instance: String? = nil,
        identity: String,
        dependencies: Set<PresentationRefreshDependency>? = nil,
        onDismiss: (() -> Void)? = nil,
        presentationHaptic: TronHaptic? = .sheetPresented,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(TronManagedSheetModifier(
            isPresented: isPresented,
            identity: identity,
            dependencies: dependencies,
            site: "\(fileID):\(line)" + (instance.map { "#\($0)" } ?? ""),
            onDismiss: onDismiss,
            haptic: presentationHaptic,
            sheetContent: content
        ))
    }

    /// `instance` names a presenter that repeats inside one surface (a chip in
    /// a `ForEach`); item presenter state is keyed by call site, not by the
    /// item's identity. See `ManagedSheetPresenterClaims`.
    func tronManagedSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
        instance: String? = nil,
        identity: @escaping (Item) -> String,
        dependencies: ((Item) -> Set<PresentationRefreshDependency>)? = nil,
        onDismiss: (() -> Void)? = nil,
        presentationHaptic: TronHaptic? = .sheetPresented,
        fileID: String = #fileID,
        line: Int = #line,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(TronManagedItemSheetModifier(
            item: item,
            identity: identity,
            dependencies: dependencies,
            site: "\(fileID):\(line)" + (instance.map { "#\($0)" } ?? ""),
            onDismiss: onDismiss,
            haptic: presentationHaptic,
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
        dependencies: Set<PresentationRefreshDependency>? = nil,
        onMount: ((PresentationSurfaceToken) -> Void)? = nil,
        onRetire: ((PresentationSurfaceToken) -> Void)? = nil
    ) -> some View {
        TronPresentationSurface(id: id, dependencies: dependencies, onMount: onMount, onRetire: onRetire) { self }
    }
}
