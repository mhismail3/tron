import SwiftUI

// Name resolution, members, assignment and construction for SwiftAppRuntime.
extension SwiftAppRuntime {
    private static let stateWrappers: Set<String> = ["State", "StateObject", "ObservedObject", "Published"]

    func lookup(_ name: String, in scope: SwiftAppScope) throws -> SwiftAppValue {
        if let box = scope.local(name) { return box.value }
        if let box = scope.local("$" + name) { return box.value.resolved }
        if let receiver = scope.selfReference, let value = try member(of: receiver, name) { return value }
        if let box = globals.local(name) { return box.value }
        if let function = program.functions[name] { return .function(function, nil) }
        if program.types[name] != nil { return .typeReference(name) }
        if SwiftAppRenderer.viewNames.contains(name) || Self.builtinTypes.contains(name) { return .typeReference(name) }
        if Self.builtinFunctions.contains(name) { return .builtin(name, nil) }
        throw SwiftAppRuntimeError("Unknown name '\(name)'")
    }

    /// A member visible through `self`, or nil when the type has none.
    func member(of receiver: SwiftAppSelf, _ name: String) throws -> SwiftAppValue? {
        let declaration = receiver.declaration
        switch receiver {
        case .view(let instance):
            if let property = declaration.stored.first(where: { $0.name == name && !$0.isStatic }) {
                switch property.wrapper {
                case let wrapper? where Self.stateWrappers.contains(wrapper):
                    return instance.state.values[name] ?? .nilValue
                case "Binding":
                    return (instance.properties[name] ?? .nilValue).resolved
                case "EnvironmentObject":
                    guard let object = instance.environmentObjects[property.typeName ?? ""] else {
                        throw SwiftAppRuntimeError("No environmentObject of type \(property.typeName ?? "?") for '\(name)'")
                    }
                    return object
                case "Environment":
                    return .dismiss(instance.dismiss)
                default:
                    return instance.properties[name] ?? .nilValue
                }
            }
        case .record(_, let box):
            if case .record(let record) = box.value, let field = record.fields[name] { return field }
        case .object(_, let object):
            if let field = object.fields[name] { return field }
        case .enumCase(_, let value):
            if name == "rawValue", case .member(let caseName, _) = value {
                return try rawValue(of: caseName, in: declaration)
            }
        case .type:
            if declaration.cases.contains(name) { return .member(name, nil) }
        }
        if let value = staticStorage["\(declaration.name).\(name)"] { return value }
        if let body = declaration.computed[name] {
            // A computed property is a call: `var x: Int { x }` must hit the depth limit.
            try enterCall()
            defer { leaveCall() }
            return try run(body, in: SwiftAppScope(parent: globals, selfReference: receiver))
        }
        if let function = declaration.functions[name] { return .function(function, receiver) }
        return nil
    }

    private func rawValue(of caseName: String, in declaration: SwiftAppTypeDeclaration) throws -> SwiftAppValue {
        if let raw = declaration.rawValues[caseName] { return try evaluate(raw, in: globals) }
        if declaration.conformances.contains("Int"), let index = declaration.cases.firstIndex(of: caseName) { return .int(index) }
        return .string(caseName)
    }

    private func enumDeclaration(containing caseName: String) -> SwiftAppTypeDeclaration? {
        program.typeOrder.lazy.compactMap { self.program.types[$0] }.first { $0.kind == .enumeration && $0.cases.contains(caseName) }
    }

    func property(of base: SwiftAppValue, _ name: String) throws -> SwiftAppValue {
        if case .binding(let binding) = base {
            if name == "wrappedValue" { return binding.get() }
            let current = binding.get()
            switch current {
            case .record, .object:
                // `$item.done` projects a binding to the field.
                return .binding(SwiftAppBinding(
                    get: { [weak self] in (try? self?.property(of: binding.get(), name)) ?? .nilValue },
                    set: { [weak self] newValue in
                        guard let self, let updated = try? self.setting(binding.get(), path: [.field(name)], to: newValue) else { return }
                        binding.set(updated)
                    }
                ))
            default:
                return try property(of: current, name)
            }
        }
        switch base {
        case .geometry(let geometry):
            if let value = geometry.member(name) { return value }
            if case .proxy = geometry, name == "frame" { return .builtin(name, base) }
            throw SwiftAppRuntimeError("\(geometry.name) has no member '\(name)'")
        case .typeReference(let typeName):
            if typeName == "Timer", name == "publish" { return .builtin("Timer.publish", nil) }
            if let declaration = program.types[typeName] {
                if typeName == declaration.name, name == "allCases" { return .array(declaration.cases.map { .member($0, nil) }) }
                if let value = try member(of: .type(declaration), name) { return value }
                throw SwiftAppRuntimeError("\(typeName) has no member '\(name)'")
            }
            if ["Int", "Double", "Bool", "Float", "CGFloat"].contains(typeName) {
                if name == "pi" { return .double(.pi) }
                return .builtin("\(typeName).\(name)", nil)
            }
            return .member(name, nil)
        case .record(let record):
            if let field = record.fields[name] { return field }
            if let declaration = program.types[record.typeName],
               let value = try member(of: .record(declaration, SwiftAppBox(base)), name) { return value }
        case .object(let object):
            if let field = object.fields[name] { return field }
            if let declaration = program.types[object.typeName],
               let value = try member(of: .object(declaration, object), name) { return value }
        case .member(let caseName, nil):
            if let declaration = enumDeclaration(containing: caseName),
               let value = try member(of: .enumCase(declaration, base), name) { return value }
        case .dictionary(let entries):
            switch name {
            case "count": return .int(entries.count)
            case "isEmpty": return .bool(entries.isEmpty)
            case "keys":
                try tick(entries.count)
                return .array(entries.keys.map(\.value))
            case "values":
                try tick(entries.count)
                return .array(Array(entries.values))
            case "description": return .string(base.display)
            default: break
            }
        case .array(let values):
            switch name {
            case "count": return .int(values.count)
            case "isEmpty": return .bool(values.isEmpty)
            case "first": return values.first ?? .nilValue
            case "last": return values.last ?? .nilValue
            case "indices": return .range(0, values.count)
            case "startIndex": return .int(0)
            case "endIndex": return .int(values.count)
            default: break
            }
        case .string(let text):
            switch name {
            case "count": return .int(text.count)
            case "isEmpty": return .bool(text.isEmpty)
            case "capitalized": return .string(text.capitalized)
            case "first": return text.first.map { .string(String($0)) } ?? .nilValue
            case "last": return text.last.map { .string(String($0)) } ?? .nilValue
            case "description": return base
            default: break
            }
        case .int(let value):
            if name == "description" { return .string(String(value)) }
            if name == "magnitude" { return .int(value.magnitude > UInt(Int.max) ? Int.max : Int(value.magnitude)) }
        case .double(let value):
            if name == "description" { return .string(String(value)) }
            if name == "magnitude" { return .double(value.magnitude) }
        case .bool(let value):
            if name == "description" { return .string(String(value)) }
        case .range(let lower, let upper):
            switch name {
            case "count": return .int(max(0, upper - lower))
            case "lowerBound": return .int(lower)
            case "upperBound": return .int(upper)
            case "isEmpty": return .bool(upper <= lower)
            default: break
            }
        case .tuple(let elements):
            if let element = elements.first(where: { $0.label == name }) { return element.value }
            if let index = Int(name), elements.indices.contains(index) { return elements[index].value }
        case .nilValue:
            // Optional.map/flatMap on nil is nil; any other member is
            // optional chaining, which reads through nil.
            return Self.optionalMethods.contains(name) ? .builtin(name, base) : .nilValue
        default:
            break
        }
        // Anything else is a method that must be called.
        return .builtin(name, base)
    }

    // MARK: Bindings and assignment

    func binding(named name: String, in scope: SwiftAppScope) throws -> SwiftAppBinding {
        if let box = scope.local("$" + name), case .binding(let binding) = box.value { return binding }
        if let box = scope.local(name) {
            return SwiftAppBinding(get: { box.value }, set: { [weak self] in self?.set(box, to: $0) })
        }
        if case .view(let instance) = scope.selfReference,
           let property = instance.declaration.stored.first(where: { $0.name == name }) {
            if let wrapper = property.wrapper, Self.stateWrappers.contains(wrapper) {
                let state = instance.state
                return SwiftAppBinding(get: { state.values[name] ?? .nilValue }, set: { [weak self] in self?.set(state, name, to: $0) })
            }
            if property.wrapper == "Binding", case .binding(let binding)? = instance.properties[name] { return binding }
            if property.wrapper == "EnvironmentObject", let object = instance.environmentObjects[property.typeName ?? ""] {
                return SwiftAppBinding(get: { object }, set: { _ in })
            }
        }
        if let receiver = scope.selfReference, case .object(_, let object) = receiver, object.fields[name] != nil {
            return SwiftAppBinding(get: { object.fields[name] ?? .nilValue }, set: { [weak self] in self?.set(object, name, to: $0) })
        }
        throw SwiftAppRuntimeError("Cannot make a binding to '\(name)'; declare it with @State")
    }

    enum PathComponent {
        case field(String)
        case element(SwiftAppValue, fallback: (() throws -> SwiftAppValue)?)
    }

    /// Read and write the same location during compound assignment or mutation:
    /// side-effecting keys run once, missing defaults lazily at most once.
    typealias Location = (root: SwiftAppExpr, path: [PathComponent])

    func lazyDefault(_ expression: SwiftAppExpr?, in scope: SwiftAppScope) -> (() throws -> SwiftAppValue)? {
        guard let expression else { return nil }
        var cached: SwiftAppValue?
        return {
            if let cached { return cached }
            let value = try self.evaluate(expression, in: scope).resolved
            cached = value
            return value
        }
    }

    func read(_ location: Location, in scope: SwiftAppScope) throws -> SwiftAppValue {
        var value = try evaluate(location.root, in: scope)
        for component in location.path {
            switch component {
            case .field(let name): value = try property(of: value, name)
            case .element(let key, let fallback): value = try subscriptValue(value.resolved, key, fallback: fallback)
            }
        }
        return value
    }

    /// Splits an assignable expression into its root and access path.
    func lvalue(_ expression: SwiftAppExpr, in scope: SwiftAppScope) throws -> Location? {
        switch expression {
        case .identifier, .selfMember: return (expression, [])
        case .member(let base, let name):
            guard let inner = try lvalue(base, in: scope) else { return nil }
            return (inner.root, inner.path + [.field(name)])
        case .subscripted(let base, let index, let fallback):
            guard let inner = try lvalue(base, in: scope) else { return nil }
            let key = try evaluate(index, in: scope).resolved
            return (inner.root, inner.path + [.element(key, fallback: lazyDefault(fallback, in: scope))])
        default:
            return nil
        }
    }

    func assign(_ location: Location, _ value: SwiftAppValue, in scope: SwiftAppScope) throws {
        let (root, path) = location
        let newValue = value.resolved
        if path.isEmpty { return try assignRoot(root, newValue, in: scope) }
        let current = try evaluate(root, in: scope)
        if case .binding(let binding) = current {
            binding.set(try setting(binding.get(), path: path, to: newValue))
            return
        }
        let updated = try setting(current, path: path, to: newValue)
        // Objects are references: their fields already changed in place.
        if case .object = current { return }
        try assignRoot(root, updated, in: scope)
    }

    func setting(_ base: SwiftAppValue, path: [PathComponent], to value: SwiftAppValue) throws -> SwiftAppValue {
        try tick()
        guard let first = path.first else { return value }
        let rest = Array(path.dropFirst())
        switch (base.resolved, first) {
        case (.record(var record), .field(let name)):
            guard record.fields[name] != nil else { throw SwiftAppRuntimeError("\(record.typeName) has no stored property '\(name)'") }
            record.fields[name] = try setting(record.fields[name] ?? .nilValue, path: rest, to: value)
            return .record(record)
        case (.object(let object), .field(let name)):
            set(object, name, to: try setting(object.fields[name] ?? .nilValue, path: rest, to: value))
            return .object(object)
        case (.array(var values), .element(.int(let index), nil)):
            guard values.indices.contains(index) else { throw SwiftAppRuntimeError("Index \(index) is out of range") }
            try tick(values.count)
            values[index] = try setting(values[index], path: rest, to: value)
            return .array(values)
        case (.dictionary(var entries), .element(let index, let fallback)):
            let key = try dictionaryKey(index)
            // Only the optional subscript's direct nil assignment removes a key.
            // A nested nil field (or a default subscript storing nil) is a value.
            let removes = rest.isEmpty && fallback == nil && value.isNone
            if !removes && entries[key] == nil { try checkDictionaryCount(entries.count + 1) }
            try tick(entries.count + 1) // value-semantic writeback may copy all entries
            if removes { entries.removeValue(forKey: key) }
            else if rest.isEmpty { entries[key] = value }
            else {
                let previous = try entries[key] ?? fallback?() ?? .nilValue
                entries[key] = try setting(previous, path: rest, to: value)
            }
            return .dictionary(entries)
        default:
            throw SwiftAppRuntimeError("Cannot assign through \(base.debugDisplay)")
        }
    }

    private func assignRoot(_ root: SwiftAppExpr, _ value: SwiftAppValue, in scope: SwiftAppScope) throws {
        let name: String
        switch root {
        case .identifier(let identifier, _):
            if let box = scope.local(identifier) {
                if case .binding(let binding) = box.value { binding.set(value) } else { set(box, to: value) }
                return
            }
            if let box = scope.local("$" + identifier), case .binding(let binding) = box.value { binding.set(value); return }
            name = identifier
        case .selfMember(let identifier):
            name = identifier
        default:
            throw SwiftAppRuntimeError("Cannot assign to this expression")
        }
        if let receiver = scope.selfReference, try assignMember(of: receiver, name, value) { return }
        if let box = globals.local(name) { set(box, to: value); return }
        throw SwiftAppRuntimeError("Cannot assign to '\(name)'")
    }

    private func assignMember(of receiver: SwiftAppSelf, _ name: String, _ value: SwiftAppValue) throws -> Bool {
        let declaration = receiver.declaration
        let key = "\(declaration.name).\(name)"
        if staticStorage[key] != nil { setStatic(key, to: value); return true }
        switch receiver {
        case .view(let instance):
            guard let property = declaration.stored.first(where: { $0.name == name }) else { return false }
            switch property.wrapper {
            case let wrapper? where Self.stateWrappers.contains(wrapper):
                set(instance.state, name, to: value)
            case "Binding":
                guard case .binding(let binding)? = instance.properties[name] else { return false }
                binding.set(value)
            default:
                throw SwiftAppRuntimeError("'\(name)' is not @State; views cannot change plain properties")
            }
            return true
        case .record(_, let box):
            guard case .record(var record) = box.value, record.fields[name] != nil else { return false }
            record.fields[name] = value
            set(box, to: .record(record))
            return true
        case .object(_, let object):
            guard object.fields[name] != nil else { return false }
            set(object, name, to: value)
            return true
        case .enumCase, .type:
            return false
        }
    }

    // MARK: Calls

    func evaluateCall(_ callee: SwiftAppExpr, _ argumentExpressions: [SwiftAppArgument], in scope: SwiftAppScope) throws -> SwiftAppValue {
        let arguments = try argumentExpressions.map { argument in
            SwiftAppLabeledValue(label: argument.label, value: try evaluate(argument.value, in: scope))
        }
        // `first`/`last` are properties on arrays, but `first(where:)` and
        // `first { … }` are calls to the method of the same name.
        if case .member(let base, let name) = callee, !arguments.isEmpty, ["first", "last"].contains(name) {
            let receiver = try evaluate(base, in: scope).resolved
            switch receiver {
            case .array, .range: return try apply(.builtin(name, receiver), arguments)
            default: break
            }
        }
        if case .member(let base, let name) = callee, let target = try lvalue(base, in: scope) {
            let receiver = try read(target, in: scope)
            let resolved = receiver.resolved
            let isMutatingRecordFunction: Bool = {
                guard case .record(let record) = resolved, let function = program.types[record.typeName]?.functions[name] else { return false }
                return function.isMutating
            }()
            if isMutatingRecordFunction || (SwiftAppBuiltins.mutatingMethods.contains(name) && SwiftAppBuiltins.canMutate(resolved)) {
                let (updated, result) = try mutate(resolved, name, arguments)
                if case .object = resolved { return result }
                if case .binding(let binding) = receiver { binding.set(updated); return result }
                try assign(target, updated, in: scope)
                return result
            }
            return try applyNamed(try property(of: receiver, name), arguments, callee: callee)
        }
        return try applyNamed(try evaluate(callee, in: scope), arguments, callee: callee)
    }

    private func applyNamed(_ value: SwiftAppValue, _ arguments: [SwiftAppLabeledValue], callee: SwiftAppExpr) throws -> SwiftAppValue {
        switch value.resolved {
        case .typeReference, .closure, .function, .builtin, .dismiss, .member(_, nil):
            return try apply(value, arguments)
        default:
            switch callee {
            case .member(_, let name), .selfMember(let name):
                throw SwiftAppRuntimeError("'\(name)' is a property, not a method")
            case .identifier(let name, _):
                throw SwiftAppRuntimeError("'\(name)' is not callable")
            default:
                throw SwiftAppRuntimeError("This expression is not callable")
            }
        }
    }

    /// Builder content is explicit at the SwiftUI boundary, never inherited by
    /// a value helper or an action merely because it was declared in a body.
    func renderContent(_ value: SwiftAppValue, arguments: [SwiftAppValue] = []) throws -> SwiftAppValue {
        try entered {
            switch value.resolved {
            case .closure(let closure): return try call(closure, arguments, viewBuilder: true)
            case .function(let function, let receiver):
                return try call(function, receiver: receiver, arguments.map { SwiftAppLabeledValue(label: nil, value: $0) }, viewBuilder: true)
            default: return value
            }
        }
    }

    private func mutate(_ value: SwiftAppValue, _ name: String, _ arguments: [SwiftAppLabeledValue]) throws -> (SwiftAppValue, SwiftAppValue) {
        if case .record(let record) = value, let declaration = program.types[record.typeName],
           let function = declaration.functions[name] {
            let box = SwiftAppBox(value)
            let result = try call(function, receiver: .record(declaration, box), arguments)
            return (box.value, result)
        }
        let (updated, result) = try SwiftAppBuiltins.mutate(value, name, arguments, runtime: self)
        return (try admit(updated), result)
    }

    func apply(_ callee: SwiftAppValue, _ arguments: [SwiftAppLabeledValue]) throws -> SwiftAppValue {
        try entered { try applyEntered(callee, arguments) }
    }

    private func applyEntered(_ callee: SwiftAppValue, _ arguments: [SwiftAppLabeledValue]) throws -> SwiftAppValue {
        switch callee {
        case .typeReference(let name):
            if let declaration = program.types[name] { return try construct(declaration, arguments) }
            if SwiftAppRenderer.viewNames.contains(name) { return .view(SwiftAppViewNode(name: name, arguments: arguments)) }
            return try SwiftAppBuiltins.construct(name, arguments, runtime: self)
        case .closure(let closure):
            return try call(closure, arguments.map(\.value))
        case .function(let function, let receiver):
            return try call(function, receiver: receiver, arguments)
        case .builtin(let name, let receiver):
            return try SwiftAppBuiltins.call(name, receiver: receiver, arguments, runtime: self)
        case .dismiss(let action):
            dismissAfterCommit(action)
            return .void
        case .member(let name, nil):
            return .member(name, arguments)
        case .binding(let binding):
            return try applyEntered(binding.get(), arguments)
        default:
            throw SwiftAppRuntimeError("\(callee.debugDisplay) is not callable")
        }
    }

    private func construct(_ declaration: SwiftAppTypeDeclaration, _ arguments: [SwiftAppLabeledValue]) throws -> SwiftAppValue {
        switch declaration.kind {
        case .enumeration:
            guard let raw = arguments.first(where: { $0.label == "rawValue" })?.value else {
                throw SwiftAppRuntimeError("\(declaration.name) can only be created with rawValue:")
            }
            for caseName in declaration.cases where try equal(try rawValue(of: caseName, in: declaration), raw) {
                return .member(caseName, nil)
            }
            return .nilValue
        case .structure where declaration.isView || declaration.isApp:
            return .view(SwiftAppViewNode(name: declaration.name, arguments: arguments, declaration: declaration))
        case .structure, .classType:
            var keys: [String] = []
            var fields: [String: SwiftAppValue] = [:]
            var positional = arguments.filter { $0.label == nil }.map(\.value)
            for property in declaration.stored where !property.isStatic {
                keys.append(property.name)
                if let argument = arguments.first(where: { $0.label == property.name }) {
                    fields[property.name] = argument.value.resolved
                } else if let initial = property.initialValue {
                    fields[property.name] = try evaluate(initial, in: globals)
                } else if !positional.isEmpty {
                    fields[property.name] = positional.removeFirst().resolved
                } else {
                    throw SwiftAppRuntimeError("Missing argument '\(property.name)' for \(declaration.name)")
                }
            }
            if declaration.kind == .classType { return .object(SwiftAppObject(typeName: declaration.name, fields: fields)) }
            return .record(SwiftAppRecord(typeName: declaration.name, keys: keys, fields: fields))
        }
    }

    // MARK: View instances

    func initialState(for declaration: SwiftAppTypeDeclaration, arguments: [SwiftAppLabeledValue]) -> SwiftAppStateStore {
        entered { initialStateEntered(for: declaration, arguments: arguments) }
    }

    private func initialStateEntered(for declaration: SwiftAppTypeDeclaration, arguments: [SwiftAppLabeledValue]) -> SwiftAppStateStore {
        var values: [String: SwiftAppValue] = [:]
        for property in declaration.stored where !property.isStatic {
            guard let wrapper = property.wrapper, Self.stateWrappers.contains(wrapper) else { continue }
            if let argument = arguments.first(where: { $0.label == property.name }) {
                values[property.name] = argument.value.resolved
            } else if let initial = property.initialValue {
                values[property.name] = (try? evaluate(initial, in: globals)) ?? .nilValue
            } else {
                values[property.name] = SwiftAppValue.nilValue
            }
        }
        return SwiftAppStateStore(values: values)
    }

    func properties(for node: SwiftAppViewNode) throws -> [String: SwiftAppValue] {
        try entered { try propertiesEntered(for: node) }
    }

    private func propertiesEntered(for node: SwiftAppViewNode) throws -> [String: SwiftAppValue] {
        guard let declaration = node.declaration else { return [:] }
        var properties: [String: SwiftAppValue] = [:]
        var positional = node.arguments.filter { $0.label == nil }.map(\.value)
        for property in declaration.stored where !property.isStatic {
            if let wrapper = property.wrapper, Self.stateWrappers.contains(wrapper) || wrapper.hasPrefix("Environment") { continue }
            if let argument = node.argument(property.name) {
                properties[property.name] = property.wrapper == "Binding" ? argument : argument.resolved
            } else if let initial = property.initialValue {
                properties[property.name] = try evaluate(initial, in: globals)
            } else if !positional.isEmpty {
                properties[property.name] = positional.removeFirst()
            } else {
                throw SwiftAppRuntimeError("Missing argument '\(property.name)' for \(declaration.name)")
            }
        }
        return properties
    }

    func body(of instance: SwiftAppViewInstance) throws -> SwiftAppValue {
        guard let body = instance.declaration.computed["body"] else {
            throw SwiftAppRuntimeError("\(instance.declaration.name) has no body")
        }
        return try entered { try run(body, in: SwiftAppScope(parent: globals, selfReference: .view(instance)), viewBuilder: true) }
    }

    /// Optional's own methods. Values carry no Optional wrapper, so these
    /// apply to nil and to values that have no `map` of their own.
    static let optionalMethods: Set<String> = ["map", "flatMap"]

    private static let builtinTypes: Set<String> = [
        "String", "Int", "Double", "Float", "CGFloat", "Bool", "Array", "UUID", "Color", "Font", "Date", "Set",
        "Animation", "Angle", "Edge", "Alignment", "IndexSet", "Timer", "Dictionary",
    ]
    private static let builtinFunctions: Set<String> = [
        "min", "max", "abs", "print", "withAnimation", "round", "floor", "ceil", "sqrt", "pow", "stride", "zip",
        "dismiss",
    ]
}
