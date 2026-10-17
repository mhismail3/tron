import Observation
import SwiftUI

// Presentation-scoped state (#1073).
//
// On iOS 26.4 and later SwiftUI rebuilds the content of a presented sheet when
// the app returns from the background, with fresh `@State`, while the sheet
// itself stays on screen (#932, #1073). Anything a sheet's content keeps in
// `@State` - a typed draft, a terminal's connection and emulator, a nested
// sheet's presentation flag - is silently reset, and `onDisappear`/`task`
// hooks on that content run as if the sheet had closed and reopened.
//
// The owner of a presentation's lifetime is therefore the managed sheet
// modifier, not its content: `tronManagedSheet` gives every presentation one
// `PresentationStateScope`, kept in the scene's `PresentationStateStore` under
// the presentation's identity path, and retires it only when the sheet is
// actually dismissed. Content declares the state that must outlive a rebuild
// with `@PresentationState` instead of `@State`, and puts teardown that must run
// only on dismissal in `PresentationScopedResource.presentationDidRetire()`
// instead of `onDisappear`.

/// A value a presentation scope tears down when its sheet is dismissed (a
/// shell connection, a terminal attachment), never when SwiftUI merely
/// rebuilds the sheet's content.
@MainActor
protocol PresentationScopedResource: AnyObject {
    func presentationDidRetire()
}

@MainActor
@Observable
final class PresentationStateBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// The state of one presentation (one presented sheet) and of everything its
/// content declared with `@PresentationState`.
@MainActor
final class PresentationStateScope {
    let path: String
    private var boxes: [String: AnyObject] = [:]
    private var retirements: [String: () -> Void] = [:]
    private(set) var isRetired = false

    init(path: String) { self.path = path }

    func box<Value>(_ key: String, initial: () -> Value) -> PresentationStateBox<Value> {
        if let box = boxes[key] as? PresentationStateBox<Value> { return box }
        let box = PresentationStateBox(initial())
        boxes[key] = box
        return box
    }

    /// The latest teardown a view at `key` registered; it runs once, when the
    /// sheet is dismissed.
    fileprivate func onRetire(_ key: String, perform action: @escaping () -> Void) {
        guard !isRetired else { return }
        retirements[key] = action
    }

    fileprivate func retire() {
        guard !isRetired else { return }
        // Teardown reads the presentation's state, so it runs before the state goes.
        let actions = retirements.values
        retirements.removeAll()
        for action in actions { action() }
        isRetired = true
        let values = boxes.values
        boxes.removeAll()
        for box in values {
            ((box as? any PresentationStateBoxValue)?.anyValue as? PresentationScopedResource)?.presentationDidRetire()
        }
    }
}

@MainActor private protocol PresentationStateBoxValue { var anyValue: Any { get } }
extension PresentationStateBox: PresentationStateBoxValue { var anyValue: Any { value } }

/// The scene-wide owner of presentation scopes. It outlives every sheet's
/// content, so a rebuilt sheet finds its scope again by identity path.
@MainActor
final class PresentationStateStore {
    /// A bound on scopes whose sheet never reported a dismissal (its presenter
    /// was removed while presented). Oldest first out; a live scope is
    /// re-created empty only after this many newer presentations.
    static let scopeLimit = 256

    private var scopes: [String: PresentationStateScope] = [:]
    private var order: [String] = []

    /// A presentation's place in the stack of presentations: its presenter's
    /// scope path (empty at a scene root) and its own identity.
    static func path(parent: PresentationStateScope?, identity: String) -> String {
        (parent?.path ?? "") + "/" + identity
    }

    /// The scope for a presentation that is (still) presented: a rebuilt
    /// sheet's content adopts the same one.
    func scope(path: String) -> PresentationStateScope {
        if let scope = scopes[path] { return scope }
        let scope = PresentationStateScope(path: path)
        scopes[path] = scope
        order.append(path)
        if order.count > Self.scopeLimit {
            let expired = order.removeFirst()
            scopes.removeValue(forKey: expired)?.retire()
        }
        return scope
    }

    /// The sheet was dismissed, or a fresh presentation replaces a stale one:
    /// its scope and every scope presented from inside it are torn down.
    func retire(path: String) {
        let prefix = path + "/"
        let retired = order.filter { $0 == path || $0.hasPrefix(prefix) }
        guard !retired.isEmpty else { return }
        order.removeAll { $0 == path || $0.hasPrefix(prefix) }
        for key in retired { scopes.removeValue(forKey: key)?.retire() }
    }
}

private struct PresentationStateStoreKey: EnvironmentKey {
    static let defaultValue: PresentationStateStore? = nil
}

private struct PresentationStateScopeKey: EnvironmentKey {
    static let defaultValue: PresentationStateScope? = nil
}

extension EnvironmentValues {
    var tronPresentationStateStore: PresentationStateStore? {
        get { self[PresentationStateStoreKey.self] }
        set { self[PresentationStateStoreKey.self] = newValue }
    }

    /// The innermost presented sheet's scope; nil outside any managed sheet.
    var tronPresentationStateScope: PresentationStateScope? {
        get { self[PresentationStateScopeKey.self] }
        set { self[PresentationStateScopeKey.self] = newValue }
    }
}

/// Installs the scene's one presentation-state store. Scene roots apply it once.
struct TronPresentationStateRoot: ViewModifier {
    @State private var store = PresentationStateStore()

    func body(content: Content) -> some View {
        content.environment(\.tronPresentationStateStore, store)
    }
}

/// `@State` for a sheet's content that survives SwiftUI rebuilding that content
/// while the sheet stays presented (#1073). Inside a managed sheet the value
/// lives in the sheet's presentation scope, keyed by its declaration site (or
/// an explicit key for a view that appears more than once in one sheet), and
/// is discarded when the sheet is dismissed. Outside a managed sheet it is
/// ordinary view-local state.
@MainActor
@propertyWrapper
struct PresentationState<Value>: DynamicProperty {
    @Environment(\.tronPresentationStateScope) private var scope
    @State private var local = LocalBox()
    private let key: String
    private let initial: () -> Value

    init(wrappedValue: @autoclosure @escaping () -> Value, fileID: String = #fileID, line: Int = #line, column: Int = #column) {
        initial = wrappedValue
        key = "\(fileID):\(line):\(column)"
    }

    /// For a view that can appear more than once in one sheet: `key` names
    /// this instance (for example by the row's identity).
    init(wrappedValue: @autoclosure @escaping () -> Value, key: String,
         fileID: String = #fileID, line: Int = #line, column: Int = #column) {
        initial = wrappedValue
        self.key = "\(fileID):\(line):\(column):\(key)"
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let box = box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }

    private var box: PresentationStateBox<Value> {
        if let scope, !scope.isRetired { return scope.box(key, initial: initial) }
        if let box = local.box as? PresentationStateBox<Value> { return box }
        let box = PresentationStateBox(initial())
        local.box = box
        return box
    }

    /// View-local storage for use outside a managed sheet. Not observed itself:
    /// the box it holds is.
    @MainActor
    final class LocalBox {
        var box: AnyObject?
    }
}

private struct PresentationRetireModifier: ViewModifier {
    let key: String
    let action: () -> Void
    @Environment(\.tronPresentationStateScope) private var scope

    func body(content: Content) -> some View {
        if let scope {
            content.onAppear { scope.onRetire(key, perform: action) }
        } else {
            content.onDisappear(perform: action)
        }
    }
}

extension View {
    /// Teardown for state a sheet's content keeps in `@PresentationState`: it
    /// runs when the sheet is dismissed, never when SwiftUI merely rebuilds the
    /// content (#1073). Outside a managed sheet it is `onDisappear`.
    func onPresentationRetire(fileID: String = #fileID, line: Int = #line,
                              perform action: @escaping () -> Void) -> some View {
        modifier(PresentationRetireModifier(key: "\(fileID):\(line)", action: action))
    }
}
