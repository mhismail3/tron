import Combine
import Observation
import SwiftUI

// Dynamic values of the experimental single-file SwiftUI runtime (#889).

/// Immutable local coordinates only; the native proxy never enters the interpreter.
/// Derived size/rect/point values stay read-only rather than becoming inconsistent
/// mutable records (for example a rect whose width disagrees with size.width).
enum SwiftAppGeometryValue: Equatable {
    case proxy(Double, Double), size(Double, Double), rect(Double, Double), origin

    init(size: CGSize) {
        func bounded(_ value: CGFloat) -> Double { value.isFinite ? min(10_000, max(0, Double(value))) : 0 }
        self = .proxy(bounded(size.width), bounded(size.height))
    }

    var name: String {
        switch self {
        case .proxy: "GeometryProxy"
        case .size: "CGSize"
        case .rect: "CGRect"
        case .origin: "CGPoint"
        }
    }

    var description: String {
        switch self {
        case .proxy(let width, let height), .size(let width, let height), .rect(let width, let height):
            "\(name)(\(width), \(height))"
        case .origin: "CGPoint(0, 0)"
        }
    }

    @MainActor func member(_ name: String) -> SwiftAppValue? {
        if name == "description" { return .string(description) }
        switch (self, name) {
        case (.proxy(let width, let height), "size"), (.rect(let width, let height), "size"):
            return .geometry(.size(width, height))
        case (.size(let width, _), "width"), (.rect(let width, _), "width"), (.rect(let width, _), "maxX"):
            return .double(width)
        case (.size(_, let height), "height"), (.rect(_, let height), "height"), (.rect(_, let height), "maxY"):
            return .double(height)
        case (.rect, "origin"): return .geometry(.origin)
        case (.rect, "minX"), (.rect, "minY"), (.origin, "x"), (.origin, "y"): return .double(0)
        case (.rect(let width, _), "midX"): return .double(width / 2)
        case (.rect(_, let height), "midY"): return .double(height / 2)
        default: return nil
        }
    }
}

struct SwiftAppTimer {
    let interval: TimeInterval
    let autoconnected: Bool

    init(interval: TimeInterval, autoconnected: Bool = false) {
        self.interval = max(0.1, interval.isFinite ? interval : 0.1)
        self.autoconnected = autoconnected
    }

    func autoconnect() -> SwiftAppTimer { SwiftAppTimer(interval: interval, autoconnected: true) }
}

/// Stable native lifecycle identity owned by the SwiftUI modifier, not by the
/// interpreted publisher value which may be reconstructed during body updates.
@MainActor
final class SwiftAppTimerSubscription {
    let id = UUID()
    let publisher: Timer.TimerPublisher
    init(interval: TimeInterval) {
        publisher = Timer.publish(every: interval, on: .main, in: .common)
    }
    func connect() -> AnyCancellable { AnyCancellable(publisher.connect()) }
}

#if HOSTED_TEST
@MainActor @Observable
final class SwiftAppTimerTestProbe {
    static let shared = SwiftAppTimerTestProbe()
    var activeSubscriptions = 0
}

/// URLs the hosted fixture's `OpenURLAction` received from running programs.
@MainActor @Observable
final class SwiftAppLinkTestProbe {
    static let shared = SwiftAppLinkTestProbe()
    var opened: [String] = []
}
#endif

struct SwiftAppRuntimeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    init(_ message: String) { self.message = message }
}

struct SwiftAppLabeledValue {
    let label: String?
    let value: SwiftAppValue
}

/// Owned case identity and immutable payloads, distinct from native SwiftUI symbols.
struct SwiftAppEnumValue {
    let typeName: String
    let name: String
    let arguments: [SwiftAppLabeledValue]
    /// Construction validates retained value depth once, including containers.
    let depth: Int
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

/// Only immutable scalar keys enter native hashing. The tags preserve dynamic
/// key identity (in particular Bool and Int); values retain Swift copy-on-write.
enum SwiftAppDictionaryKey: Hashable {
    case string(String), int(Int), bool(Bool), enumeration(String, String)

    @MainActor var value: SwiftAppValue {
        switch self {
        case .string(let value): .string(value)
        case .int(let value): .int(value)
        case .bool(let value): .bool(value)
        case .enumeration(let type, let name): .enumeration(SwiftAppEnumValue(typeName: type, name: name, arguments: [], depth: 1))
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
    case dictionary([SwiftAppDictionaryKey: SwiftAppValue])
    case record(SwiftAppRecord)
    case object(SwiftAppObject)
    case enumeration(SwiftAppEnumValue)
    case enumConstructor(String, String)
    /// Native symbolic members (`.red`, `.title`) and calls (`.system(size: 20)`).
    case member(String, [SwiftAppLabeledValue]?)
    case view(SwiftAppViewNode)
    case closure(SwiftAppClosure)
    case function(SwiftAppFunction, SwiftAppSelf?)
    case builtin(String, SwiftAppValue?)
    /// `@Environment(\.dismiss)`: closes the presentation the program
    /// created around this view, or nothing (nil) in the program's root,
    /// so a program can never close the runner sheet itself.
    case dismiss(DismissAction?)
    case timer(SwiftAppTimer)
    case geometry(SwiftAppGeometryValue)
    case date(Date)
    case binding(SwiftAppBinding)
    case keyPath([String])
    case typeReference(String)
    case color(Color)
    case range(Int, Int)
    case doubleRange(Double, Double)
    case tuple([SwiftAppLabeledValue])

    var isNone: Bool { if case .nilValue = self { true } else { false } }

    /// Composite values (arrays, records, tuples) print at most this many
    /// characters, so describing a large or deeply shared value is bounded.
    static let compositeDisplayLimit = 10_000

    var display: String {
        switch self {
        case .string(let v): return v
        case .binding(let binding): return binding.get().display
        default:
            var text = ""
            var budget = Self.compositeDisplayLimit
            write(into: &text, budget: &budget, quoted: false)
            return text
        }
    }

    var debugDisplay: String {
        if case .string(let value) = self { return "\"\(value)\"" }
        return display
    }

    private func write(into text: inout String, budget: inout Int, quoted: Bool) {
        budget -= 1
        guard budget > 0 else {
            if !text.hasSuffix("…") { text += "…" }
            return
        }
        func append(_ piece: String) {
            let room = max(0, budget)
            if piece.utf8.count <= room { text += piece; budget -= piece.utf8.count }
            else { text += piece.prefix(room) + "…"; budget = 0 }
        }
        func list(_ open: String, _ close: String, _ items: [(label: String?, value: SwiftAppValue)]) {
            append(open)
            for (index, item) in items.enumerated() {
                guard budget > 0 else { break }
                if index > 0 { append(", ") }
                if let label = item.label { append("\(label): ") }
                item.value.write(into: &text, budget: &budget, quoted: true)
            }
            append(close)
        }
        switch self {
        case .void: append("()")
        case .nilValue: append("nil")
        case .int(let v): append(String(v))
        case .double(let v): append(String(v))
        case .bool(let v): append(String(v))
        case .string(let v): append(quoted ? "\"\(v)\"" : v)
        case .array(let values): list("[", "]", values.map { (nil, $0) })
        case .dictionary(let entries):
            // Stream into the shared description budget, without tuple allocation.
            if entries.isEmpty { append("[:]") }
            else {
                append("[")
                for (index, entry) in entries.enumerated() {
                    guard budget > 0 else { break }
                    if index > 0 { append(", ") }
                    entry.key.value.write(into: &text, budget: &budget, quoted: true)
                    append(": ")
                    entry.value.write(into: &text, budget: &budget, quoted: true)
                }
                append("]")
            }
        case .record(let record):
            list("\(record.typeName)(", ")", record.keys.map { ($0, record.fields[$0] ?? .nilValue) })
        case .object(let object): append(object.typeName)
        case .member(let name, _): append(name)
        case .enumeration(let value):
            if value.arguments.isEmpty { append(value.name) }
            else { list("\(value.name)(", ")", value.arguments.map { ($0.label, $0.value) }) }
        case .enumConstructor: append("(enum constructor)")
        case .view(let node): append(node.name)
        case .closure, .function, .builtin, .dismiss: append("(function)")
        case .timer: append("Timer.publish")
        case .geometry(let value): append(value.description)
        case .date(let value): append(value.formatted())
        case .binding(let binding): binding.get().write(into: &text, budget: &budget, quoted: quoted)
        case .keyPath(let path): append("\\." + path.joined(separator: "."))
        case .typeReference(let name): append(name)
        case .color: append("Color")
        case .range(let a, let b): append("\(a)..<\(b)")
        case .doubleRange(let a, let b): append("\(a)...\(b)")
        case .tuple(let values): list("(", ")", values.map { (nil, $0.value) })
        }
    }

    func asInt() throws -> Int {
        switch self {
        case .int(let v): return v
        case .double(let v):
            guard let integer = Int(exactly: v.rounded(.towardZero)) else { throw SwiftAppRuntimeError("\(v) does not fit in an Int") }
            return integer
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
        case .range(let a, let b):
            guard a < b else { return [] }
            let (count, overflow) = b.subtractingReportingOverflow(a)
            guard !overflow, count <= SwiftAppRuntime.maximumCollectionCount else {
                throw SwiftAppRuntimeError("Stopped: the range \(a)..<\(b) is larger than \(SwiftAppRuntime.maximumCollectionCount) elements")
            }
            return (a..<b).map { .int($0) }
        case .string(let s):
            guard s.utf8.count <= SwiftAppRuntime.maximumCollectionCount else {
                throw SwiftAppRuntimeError("Stopped: the string is longer than \(SwiftAppRuntime.maximumCollectionCount) characters")
            }
            return s.map { .string(String($0)) }
        case .binding(let b): return try b.get().asArray()
        default: throw SwiftAppRuntimeError("Expected a collection but found \(debugDisplay)")
        }
    }

    /// The value as seen by a reader: bindings read through.
    var resolved: SwiftAppValue {
        if case .binding(let binding) = self { return binding.get().resolved }
        return self
    }

    /// A native SwiftUI argument as seen by a reader. Without contextual types,
    /// `.title` beside `enum Field { case title }` resolves to the owned case;
    /// SwiftUI parameters still read a payload-free case as its symbol.
    var symbol: SwiftAppValue {
        if case .enumeration(let value) = resolved, value.arguments.isEmpty { return .member(value.name, nil) }
        return resolved
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
        if case .enumeration(let value) = self { return "\(value.typeName).\(debugDisplay)" }
        return debugDisplay
    }

    /// Equality of non-composite values; `SwiftAppRuntime.equal` owns
    /// arrays and records so their traversal is budgeted.
    static func equalScalars(_ a: SwiftAppValue, _ b: SwiftAppValue) -> Bool {
        switch (a, b) {
        case (.nilValue, .nilValue): true
        case (.void, .void): true
        case (.int(let x), .int(let y)): x == y
        case (.int(let x), .double(let y)): Double(x) == y
        case (.double(let x), .int(let y)): x == Double(y)
        case (.double(let x), .double(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.member(let x, _), .member(let y, _)): x == y
        case (.object(let x), .object(let y)): x === y
        case (.geometry(let x), .geometry(let y)): x == y
        case (.range(let a, let b), .range(let c, let d)): a == c && b == d
        default: false
        }
    }

    static func compare(_ a: SwiftAppValue, _ b: SwiftAppValue) throws -> Bool {
        switch (a.resolved, b.resolved) {
        case (.string(let x), .string(let y)): return x < y
        case (.member(let x, _), .member(let y, _)): return x < y
        case (.enumeration(let x), .enumeration(let y)) where x.typeName == y.typeName:
            guard x.arguments.isEmpty && y.arguments.isEmpty else { throw SwiftAppRuntimeError("Payload enum ordering is not supported") }
            return x.name < y.name
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
    let dismiss: DismissAction?
    init(
        declaration: SwiftAppTypeDeclaration,
        properties: [String: SwiftAppValue],
        state: SwiftAppStateStore,
        environmentObjects: [String: SwiftAppValue],
        dismiss: DismissAction? = nil
    ) {
        self.declaration = declaration
        self.properties = properties
        self.state = state
        self.environmentObjects = environmentObjects
        self.dismiss = dismiss
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
