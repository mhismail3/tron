import Observation
import SwiftUI

// Dynamic values of the experimental single-file SwiftUI runtime (#889).

struct SwiftAppRuntimeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

struct SwiftAppLabeledValue {
    let label: String?
    let value: SwiftAppValue
}

/// A value-typed struct instance. Field order follows the declaration.
struct SwiftAppRecord {
    let typeName: String
    var keys: [String]
    var fields: [String: SwiftAppValue]
}

/// A class instance. Observation makes mutations re-render every reader,
/// which is how `ObservableObject` stores and `@Published` behave in the subset.
@MainActor @Observable
final class SwiftAppObject {
    let typeName: String
    var fields: [String: SwiftAppValue]
    init(typeName: String, fields: [String: SwiftAppValue]) {
        self.typeName = typeName
        self.fields = fields
    }
}

@MainActor
final class SwiftAppBox {
    var value: SwiftAppValue
    init(_ value: SwiftAppValue) { self.value = value }
}

@MainActor
struct SwiftAppBinding {
    let get: @MainActor () -> SwiftAppValue
    let set: @MainActor (SwiftAppValue) -> Void
}

@MainActor
final class SwiftAppClosure {
    let literal: SwiftAppClosureLiteral
    let scope: SwiftAppScope
    init(literal: SwiftAppClosureLiteral, scope: SwiftAppScope) {
        self.literal = literal
        self.scope = scope
    }
}

@MainActor
struct SwiftAppViewNode {
    let name: String
    var arguments: [SwiftAppLabeledValue]
    var modifiers: [(name: String, arguments: [SwiftAppLabeledValue])] = []
    /// Eagerly built children, used for groups produced by view builders.
    var children: [SwiftAppViewNode]? = nil
    /// The user type for custom views.
    var declaration: SwiftAppTypeDeclaration? = nil

    func argument(_ label: String) -> SwiftAppValue? {
        arguments.first(where: { $0.label == label })?.value
    }
    var unlabeled: [SwiftAppValue] { arguments.filter { $0.label == nil }.map(\.value) }
    var closures: [(label: String?, closure: SwiftAppClosure)] {
        arguments.compactMap { argument in
            if case .closure(let closure) = argument.value { (argument.label, closure) } else { nil }
        }
    }
}

@MainActor
indirect enum SwiftAppValue {
    case void
    case nilValue
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case array([SwiftAppValue])
    case record(SwiftAppRecord)
    case object(SwiftAppObject)
    /// Enum cases, implicit members (`.red`, `.title`) and member calls
    /// (`.system(size: 20)`). Rendering interprets them by context.
    case member(String, [SwiftAppLabeledValue]?)
    case view(SwiftAppViewNode)
    case closure(SwiftAppClosure)
    case function(SwiftAppFunction, SwiftAppSelf?)
    case builtin(String, SwiftAppValue?)
    case binding(SwiftAppBinding)
    case keyPath([String])
    case typeReference(String)
    case color(Color)
    case range(Int, Int)
    case doubleRange(Double, Double)
    case tuple([SwiftAppLabeledValue])

    var isNone: Bool { if case .nilValue = self { true } else { false } }

    var display: String {
        switch self {
        case .void: "()"
        case .nilValue: "nil"
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .bool(let v): String(v)
        case .string(let v): v
        case .array(let values): "[" + values.map(\.debugDisplay).joined(separator: ", ") + "]"
        case .record(let record):
            "\(record.typeName)(" + record.keys.map { "\($0): \(record.fields[$0]?.debugDisplay ?? "nil")" }.joined(separator: ", ") + ")"
        case .object(let object): object.typeName
        case .member(let name, _): name
        case .view(let node): node.name
        case .closure, .function, .builtin: "(function)"
        case .binding(let binding): binding.get().display
        case .keyPath(let path): "\\." + path.joined(separator: ".")
        case .typeReference(let name): name
        case .color: "Color"
        case .range(let a, let b): "\(a)..<\(b)"
        case .doubleRange(let a, let b): "\(a)...\(b)"
        case .tuple(let values): "(" + values.map(\.value.debugDisplay).joined(separator: ", ") + ")"
        }
    }

    var debugDisplay: String {
        if case .string(let value) = self { return "\"\(value)\"" }
        return display
    }

    func asInt() throws -> Int {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .binding(let b): return try b.get().asInt()
        default: throw SwiftAppRuntimeError("Expected an Int but found \(debugDisplay)")
        }
    }

    func asDouble() throws -> Double {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        case .binding(let b): return try b.get().asDouble()
        default: throw SwiftAppRuntimeError("Expected a number but found \(debugDisplay)")
        }
    }

    func asBool() throws -> Bool {
        switch self {
        case .bool(let v): return v
        case .binding(let b): return try b.get().asBool()
        default: throw SwiftAppRuntimeError("Expected a Bool but found \(debugDisplay)")
        }
    }

    func asArray() throws -> [SwiftAppValue] {
        switch self {
        case .array(let v): return v
        case .range(let a, let b): return a < b ? (a..<b).map { .int($0) } : []
        case .string(let s): return s.map { .string(String($0)) }
        case .binding(let b): return try b.get().asArray()
        default: throw SwiftAppRuntimeError("Expected a collection but found \(debugDisplay)")
        }
    }

    /// The value as seen by a reader: bindings read through.
    var resolved: SwiftAppValue {
        if case .binding(let binding) = self { return binding.get().resolved }
        return self
    }

    /// Stable identity for `ForEach` and `Identifiable` rows.
    func identity(keyPath: [String]?) -> String {
        if let keyPath, keyPath != ["self"] {
            var value = self
            for name in keyPath {
                switch value {
                case .record(let record): value = record.fields[name] ?? .nilValue
                case .object(let object): value = object.fields[name] ?? .nilValue
                case .tuple(let items):
                    value = items.first(where: { $0.label == name })?.value ?? .nilValue
                default: break
                }
            }
            return value.debugDisplay
        }
        if keyPath == nil {
            if case .record(let record) = self, let id = record.fields["id"] { return id.debugDisplay }
            if case .object(let object) = self, let id = object.fields["id"] { return id.debugDisplay }
        }
        return debugDisplay
    }

    static func equal(_ a: SwiftAppValue, _ b: SwiftAppValue) -> Bool {
        switch (a.resolved, b.resolved) {
        case (.nilValue, .nilValue): true
        case (.void, .void): true
        case (.int(let x), .int(let y)): x == y
        case (.int(let x), .double(let y)): Double(x) == y
        case (.double(let x), .int(let y)): x == Double(y)
        case (.double(let x), .double(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.member(let x, _), .member(let y, _)): x == y
        case (.array(let x), .array(let y)): x.count == y.count && zip(x, y).allSatisfy { equal($0, $1) }
        case (.record(let x), .record(let y)):
            x.typeName == y.typeName && x.keys.allSatisfy { key in equal(x.fields[key] ?? .nilValue, y.fields[key] ?? .nilValue) }
        case (.object(let x), .object(let y)): x === y
        case (.range(let a, let b), .range(let c, let d)): a == c && b == d
        default: false
        }
    }

    static func compare(_ a: SwiftAppValue, _ b: SwiftAppValue) throws -> Bool {
        switch (a.resolved, b.resolved) {
        case (.string(let x), .string(let y)): return x < y
        case (.member(let x, _), .member(let y, _)): return x < y
        case (let x, let y): return try x.asDouble() < y.asDouble()
        }
    }
}

/// Observable per-instance `@State` storage. SwiftUI owns the lifetime of the
/// hosting view, so interpreted state follows real SwiftUI identity.
@MainActor @Observable
final class SwiftAppStateStore {
    var values: [String: SwiftAppValue]
    init(values: [String: SwiftAppValue]) { self.values = values }
}

/// One custom view instance: the props its parent passed plus its own state.
@MainActor
final class SwiftAppViewInstance {
    let declaration: SwiftAppTypeDeclaration
    var properties: [String: SwiftAppValue]
    let state: SwiftAppStateStore
    let environmentObjects: [String: SwiftAppValue]
    init(
        declaration: SwiftAppTypeDeclaration,
        properties: [String: SwiftAppValue],
        state: SwiftAppStateStore,
        environmentObjects: [String: SwiftAppValue]
    ) {
        self.declaration = declaration
        self.properties = properties
        self.state = state
        self.environmentObjects = environmentObjects
    }
}

@MainActor
enum SwiftAppSelf {
    case view(SwiftAppViewInstance)
    case record(SwiftAppTypeDeclaration, SwiftAppBox)
    case object(SwiftAppTypeDeclaration, SwiftAppObject)
    case enumCase(SwiftAppTypeDeclaration, SwiftAppValue)
    case type(SwiftAppTypeDeclaration)

    var declaration: SwiftAppTypeDeclaration {
        switch self {
        case .view(let instance): instance.declaration
        case .record(let declaration, _), .object(let declaration, _), .enumCase(let declaration, _), .type(let declaration):
            declaration
        }
    }
}

@MainActor
final class SwiftAppScope {
    private var variables: [String: SwiftAppBox] = [:]
    let parent: SwiftAppScope?
    let selfReference: SwiftAppSelf?

    init(parent: SwiftAppScope?, selfReference: SwiftAppSelf? = nil) {
        self.parent = parent
        self.selfReference = selfReference ?? parent?.selfReference
    }

    func declare(_ name: String, _ value: SwiftAppValue) { variables[name] = SwiftAppBox(value) }

    func local(_ name: String) -> SwiftAppBox? {
        variables[name] ?? parent?.local(name)
    }
}
