import Foundation
import SwiftUI

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
    }

    private var stateStore: PresentationStateStore { sceneStateStore ?? localStateStore }
    private var statePath: String { PresentationStateStore.path(parent: parentStateScope, identity: "\(identity)@\(site)") }

    func body(content: Content) -> some View {
        var environment = nativeEnvironment
        environment.scenePhase = nativeScenePhase
        environment.tronPresentationDependencyRead = nativeDependencyRead
        let source: NativeSheetSource? = isPresented || nativeHost.isInstalled ? NativeSheetSource(
            owner: nativeHost,
            content: AnyView(Color.clear.accessibilityHidden(true).sheet(isPresented: $isPresented, onDismiss: didDismiss) {
                TronPresentationSurface(token: lease.contentToken(identity: identity), parent: parent) {
                    sheetContent().environment(\.chatOwnsStatusBar, false)
                }
                .environment(\.tronPresentationStateScope, stateStore.scope(path: statePath))
            }),
            environment: environment,
            onRemoval: sourceDidDisappear
        ) : nil
        return content
            .transformPreference(NativeSheetSources.self) { sources in
                if let source { sources.append(source) }
            }
            // Only a live false → true change plays: a sheet already presented
            // when its presenter mounts (launch, reconnect, rebuild) is silent.
            .onChange(of: isPresented, initial: true) { wasPresented, presented in
                #if HOSTED_TEST
                HostedPresentationProbe.record?("binding", "\(identity) \(wasPresented)→\(presented) parent=\(parentStateScope?.path ?? "nil")")
                #endif
                if presented {
                    registerIfPossible(playHaptic: !wasPresented)
                } else {
                    lease.beginDismissal()
                }
            }
            .onPresentationRetire(fileID: "native-source:\(identity)@\(site)", line: 0, perform: sourceDidDisappear)
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

    private func registerIfPossible(playHaptic: Bool) {
        if let token = lease.register(identity: identity) {
            coordinator?.register(token, parent: parent, dependencies: dependencies)
            if playHaptic, let haptic { TronHaptics.shared.play(haptic) }
        }
    }

    private func didDismiss() {
        #if HOSTED_TEST
        HostedPresentationProbe.record?("native-dismiss", "\(identity) presented=\(isPresented) source-attached=\(nativeHost.isAttached)")
        #endif
        if lease.dismissingToken == nil, !isPresented { lease.beginDismissal() }
        let transition = lease.completeDismissal(nextIdentity: isPresented ? identity : nil)
        apply(transition)
        if transition.registered != nil, let haptic { TronHaptics.shared.play(haptic) }
        // Only an actual dismissal ends the presentation's state.
        if !isPresented { stateStore.retire(path: statePath) }
        if !isPresented, transition.retired != nil { onDismiss?() }
    }

    private func apply(_ transition: PresentationDismissalLease.Transition) {
        if let retired = transition.retired { coordinator?.retire(retired) }
        if let registered = transition.registered {
            coordinator?.register(registered, parent: parent, dependencies: dependencies)
        }
    }

    private func retireAllTokens() {
        for token in lease.retireAll() { coordinator?.retire(token) }
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
        let source: NativeSheetSource? = item != nil || nativeHost.isInstalled ? NativeSheetSource(
            owner: nativeHost,
            content: AnyView(Color.clear.accessibilityHidden(true).sheet(item: $item, onDismiss: didDismiss) { value in
                TronPresentationSurface(token: lease.contentToken(identity: identity(value)), parent: parent) {
                    sheetContent(value).environment(\.chatOwnsStatusBar, false)
                }
                .environment(\.tronPresentationStateScope, stateStore.scope(path: statePath(value)))
            }),
            environment: environment,
            onRemoval: sourceDidDisappear
        ) : nil
        return content
            .transformPreference(NativeSheetSources.self) { sources in
                if let source { sources.append(source) }
            }
            .onChange(of: item.map(identity), initial: true) { previous, current in
                itemChanged()
                // Replacing a presented item is not a new presentation.
                if previous == nil, current != nil, lease.dismissingToken == nil,
                   let haptic { TronHaptics.shared.play(haptic) }
            }
            .onPresentationRetire(fileID: "native-source:\(site)", line: 0, perform: sourceDidDisappear)
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

    private func itemChanged() {
        guard let item else {
            lease.beginDismissal()
            return
        }
        // A different item replaces the presentation: the old one's state ends.
        let path = statePath(item)
        if let presentedStatePath, presentedStatePath != path { stateStore.retire(path: presentedStatePath) }
        presentedStatePath = path
        let itemIdentity = identity(item)
        if lease.registeredToken == nil {
            if let token = lease.register(identity: itemIdentity) {
                coordinator?.register(token, parent: parent, dependencies: dependencies?(item))
            }
        } else {
            apply(lease.replace(identity: itemIdentity))
        }
    }

    private func didDismiss() {
        #if HOSTED_TEST
        HostedPresentationProbe.record?("native-dismiss", "\(item.map(identity) ?? "nil") source-attached=\(nativeHost.isAttached)")
        #endif
        if lease.dismissingToken == nil, item == nil { lease.beginDismissal() }
        let transition = lease.completeDismissal(nextIdentity: item.map(identity))
        apply(transition)
        if transition.registered != nil, let haptic { TronHaptics.shared.play(haptic) }
        if item == nil, let presentedStatePath {
            stateStore.retire(path: presentedStatePath)
            self.presentedStatePath = nil
        }
        if item == nil, transition.retired != nil { onDismiss?() }
    }

    private func apply(_ transition: PresentationDismissalLease.Transition) {
        if let retired = transition.retired { coordinator?.retire(retired) }
        if let registered = transition.registered {
            coordinator?.register(registered, parent: parent, dependencies: item.flatMap { dependencies?($0) })
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
    func tronManagedSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
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
            site: "\(fileID):\(line)",
            onDismiss: onDismiss,
            haptic: presentationHaptic,
            sheetContent: content
        ))
    }

    func tronManagedSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>,
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
            site: "\(fileID):\(line)",
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
