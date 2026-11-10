import Observation
import SwiftUI

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

    fileprivate func onRetire(_ key: String, perform action: @escaping () -> Void) {
        guard !isRetired else { return }
        retirements[key] = action
    }

    fileprivate func retire() {
        #if HOSTED_TEST
        HostedPresentationProbe.record?("scope-retire", path)
        #endif
        guard !isRetired else { return }
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

@MainActor
final class PresentationStateStore {
    static let leakReportThreshold = 256

    private var scopes: [String: PresentationStateScope] = [:]
    private var order: [String] = []

    static func path(parent: PresentationStateScope?, identity: String) -> String {
        (parent?.path ?? "") + "/" + identity
    }

    func scope(path: String) -> PresentationStateScope {
        if let scope = scopes[path] { return scope }
        let scope = PresentationStateScope(path: path)
        scopes[path] = scope
        order.append(path)
        if order.count == Self.leakReportThreshold + 1 {
            ManagedSheetPresentationSignal.fault("presentation-state.scope-leak live=\(order.count) newest=\(path)")
        }
        return scope
    }

    func retireAll() {
        let live = Array(scopes.values)
        scopes.removeAll(); order.removeAll()
        for scope in live { scope.retire() }
    }

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

    var tronPresentationStateScope: PresentationStateScope? {
        get { self[PresentationStateScopeKey.self] }
        set { self[PresentationStateScopeKey.self] = newValue }
    }
}

@MainActor private final class PresentationStateLifetime {
    let store = PresentationStateStore()
    isolated deinit { store.retireAll() }
}

struct TronPresentationStateRoot: ViewModifier {
    @State private var lifetime = PresentationStateLifetime()

    func body(content: Content) -> some View {
        content.modifier(TronNativeSheetCanvas(role: .scene))
            .environment(\.tronPresentationStateStore, lifetime.store)
            .modifier(TronPadSheetSceneMode())
    }
}

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
    func onPresentationRetire(fileID: String = #fileID, line: Int = #line,
                              perform action: @escaping () -> Void) -> some View {
        modifier(PresentationRetireModifier(key: "\(fileID):\(line)", action: action))
    }
}
