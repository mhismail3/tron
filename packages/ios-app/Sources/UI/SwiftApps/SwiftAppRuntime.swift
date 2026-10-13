import SwiftUI

/// Tree-walking evaluator for one parsed single-file SwiftUI program (#889).
/// It has no file, network, process or native-call surface: programs can only
/// build interpreted views and mutate their own interpreted state. A step and
/// depth budget turns runaway loops and recursion into diagnostics.
@MainActor @Observable
final class SwiftAppRuntime {
    enum Flow {
        case normal
        case returned(SwiftAppValue)
        case broke
        case continued
    }

    final class Collector {
        var views: [SwiftAppViewNode] = []
        var lastValue: SwiftAppValue = .void
    }

    static let stepBudget = 2_000_000
    static let depthBudget = 160

    @ObservationIgnored let program: SwiftAppProgramSyntax
    @ObservationIgnored let globals: SwiftAppScope
    @ObservationIgnored var staticStorage: [String: SwiftAppValue] = [:]
    @ObservationIgnored private var steps = 0
    @ObservationIgnored private var depth = 0
    /// The latest action failure, shown over the running app.
    var actionError: String?

    init(source: String) throws {
        program = try SwiftAppParser.parse(source)
        globals = SwiftAppScope(parent: nil)
        guard rootDeclaration != nil else {
            throw SwiftAppRuntimeError("The file needs a struct conforming to View or App")
        }
        beginWork()
        for (name, expression) in program.globals {
            globals.declare(name, try evaluate(expression, in: globals))
        }
        for name in program.typeOrder {
            guard let declaration = program.types[name] else { continue }
            for property in declaration.stored where property.isStatic {
                staticStorage["\(name).\(property.name)"] = try property.initialValue.map { try evaluate($0, in: globals) } ?? .nilValue
            }
        }
    }

    /// The `@main` App when present, else `ContentView`, else the first View.
    var rootDeclaration: SwiftAppTypeDeclaration? {
        let ordered = program.typeOrder.compactMap { program.types[$0] }
        return ordered.first(where: \.isApp)
            ?? program.types["ContentView"].flatMap { $0.isView ? $0 : nil }
            ?? ordered.first(where: \.isView)
    }

    func beginWork() {
        steps = 0
        depth = 0
    }

    private func tick() throws {
        steps += 1
        if steps > Self.stepBudget { throw SwiftAppRuntimeError("Stopped: the program ran too long (possible infinite loop)") }
    }

    /// Runs a user action (button, toggle side effect, gesture) and reports
    /// failures over the app instead of terminating it.
    func perform(_ callable: SwiftAppValue, _ arguments: [SwiftAppValue] = []) {
        beginWork()
        do {
            _ = try apply(callable, arguments.map { SwiftAppLabeledValue(label: nil, value: $0) })
            actionError = nil
        } catch {
            actionError = String(describing: error)
        }
    }

    // MARK: Calls

    func call(_ closure: SwiftAppClosure, _ arguments: [SwiftAppValue]) throws -> SwiftAppValue {
        depth += 1
        defer { depth -= 1 }
        if depth > Self.depthBudget { throw SwiftAppRuntimeError("Stopped: recursion is too deep") }
        let scope = SwiftAppScope(parent: closure.scope)
        let parameters = closure.literal.parameters
        if parameters.isEmpty {
            for (index, argument) in arguments.enumerated() { scope.declare("$\(index)", argument) }
        } else if parameters.count == 1, arguments.count > 1 {
            scope.declare(parameters[0], .tuple(arguments.map { SwiftAppLabeledValue(label: nil, value: $0) }))
        } else {
            for (index, name) in parameters.enumerated() where name != "_" {
                scope.declare(name, index < arguments.count ? arguments[index] : .nilValue)
            }
        }
        return try run(closure.literal.body, in: scope)
    }

    func call(_ function: SwiftAppFunction, receiver: SwiftAppSelf?, _ arguments: [SwiftAppLabeledValue]) throws -> SwiftAppValue {
        depth += 1
        defer { depth -= 1 }
        if depth > Self.depthBudget { throw SwiftAppRuntimeError("Stopped: recursion is too deep") }
        let scope = SwiftAppScope(parent: globals, selfReference: receiver)
        var remaining = arguments
        for parameter in function.parameters {
            if let index = remaining.firstIndex(where: { $0.label == parameter.label }) {
                scope.declare(parameter.name, remaining.remove(at: index).value)
            } else if let defaultValue = parameter.defaultValue {
                scope.declare(parameter.name, try evaluate(defaultValue, in: globals))
            } else if parameter.label != nil, let index = remaining.firstIndex(where: {
                if case .closure = $0.value { true } else { false }
            }) {
                // A trailing closure fills the last closure parameter.
                scope.declare(parameter.name, remaining.remove(at: index).value)
            } else {
                throw SwiftAppRuntimeError("Missing argument '\(parameter.label ?? parameter.name)' for \(function.name)")
            }
        }
        return try run(function.body, in: scope)
    }

    /// A body's value: an explicit `return`, the views a builder produced, or
    /// the value of a single-expression body.
    func run(_ body: [SwiftAppStmt], in scope: SwiftAppScope) throws -> SwiftAppValue {
        let collector = Collector()
        if case .returned(let value) = try execute(body, in: scope, collector: collector) { return value }
        if !collector.views.isEmpty {
            return .view(collector.views.count == 1
                ? collector.views[0]
                : SwiftAppViewNode(name: SwiftAppRenderer.builderGroup, arguments: [], children: collector.views))
        }
        if body.count == 1, case .expression = body[0] { return collector.lastValue }
        return .void
    }

    // MARK: Statements

    func execute(_ statements: [SwiftAppStmt], in scope: SwiftAppScope, collector: Collector?) throws -> Flow {
        for statement in statements {
            try tick()
            switch statement {
            case .declaration(let name, let expression):
                scope.declare(name, try expression.map { try evaluate($0, in: scope) } ?? .nilValue)
            case .expression(let expression, let line):
                let value: SwiftAppValue
                do { value = try evaluate(expression, in: scope) }
                catch let error as SwiftAppRuntimeError where !error.message.hasPrefix("Line ") {
                    throw SwiftAppRuntimeError("Line \(line): \(error.message)")
                }
                if let collector {
                    if let node = Self.viewNode(from: value) { collector.views.append(node) }
                    collector.lastValue = value
                }
            case .assignment(let target, let op, let expression, let line):
                do {
                    var value = try evaluate(expression, in: scope)
                    if op != "=" {
                        value = try binary(String(op.dropLast()), try evaluate(target, in: scope), value)
                    }
                    try assign(target, value, in: scope)
                } catch let error as SwiftAppRuntimeError where !error.message.hasPrefix("Line ") {
                    throw SwiftAppRuntimeError("Line \(line): \(error.message)")
                }
            case .conditional(let branches, let otherwise):
                var handled = false
                for branch in branches {
                    let branchScope = SwiftAppScope(parent: scope)
                    if try holds(branch.conditions, in: branchScope) {
                        let flow = try execute(branch.body, in: branchScope, collector: collector)
                        if case .normal = flow {} else { return flow }
                        handled = true
                        break
                    }
                }
                if !handled, let otherwise {
                    let flow = try execute(otherwise, in: SwiftAppScope(parent: scope), collector: collector)
                    if case .normal = flow {} else { return flow }
                }
            case .guardStatement(let conditions, let body):
                if try !holds(conditions, in: scope) {
                    let flow = try execute(body, in: SwiftAppScope(parent: scope), collector: collector)
                    if case .normal = flow { throw SwiftAppRuntimeError("guard body must not fall through") }
                    return flow
                }
            case .forIn(let name, let sequence, let filter, let body):
                for element in try evaluate(sequence, in: scope).resolved.asArray() {
                    try tick()
                    let iteration = SwiftAppScope(parent: scope)
                    iteration.declare(name, element)
                    if let filter, try !evaluate(filter, in: iteration).asBool() { continue }
                    let flow = try execute(body, in: iteration, collector: collector)
                    if case .broke = flow { break }
                    if case .returned = flow { return flow }
                }
            case .whileLoop(let conditions, let body):
                while true {
                    try tick()
                    let iteration = SwiftAppScope(parent: scope)
                    guard try holds(conditions, in: iteration) else { break }
                    let flow = try execute(body, in: iteration, collector: collector)
                    if case .broke = flow { break }
                    if case .returned = flow { return flow }
                }
            case .switchStatement(let subjectExpression, let cases):
                let subject = try evaluate(subjectExpression, in: scope).resolved
                for switchCase in cases {
                    if try matches(switchCase.patterns, subject, in: scope) {
                        let flow = try execute(switchCase.body, in: SwiftAppScope(parent: scope), collector: collector)
                        if case .broke = flow { break }
                        if case .normal = flow { break }
                        return flow
                    }
                }
            case .returnStatement(let expression):
                return .returned(try expression.map { try evaluate($0, in: scope) } ?? .void)
            case .breakStatement:
                return .broke
            case .continueStatement:
                return .continued
            }
        }
        return .normal
    }

    private func holds(_ conditions: [SwiftAppCondition], in scope: SwiftAppScope) throws -> Bool {
        for condition in conditions {
            switch condition {
            case .expression(let expression):
                if try !evaluate(expression, in: scope).asBool() { return false }
            case .optionalBinding(let name, let expression):
                let value = try evaluate(expression, in: scope).resolved
                if value.isNone { return false }
                scope.declare(name, value)
            }
        }
        return true
    }

    private func matches(_ patterns: [SwiftAppExpr]?, _ subject: SwiftAppValue, in scope: SwiftAppScope) throws -> Bool {
        guard let patterns else { return true }
        for pattern in patterns {
            let value = try evaluate(pattern, in: scope)
            switch value {
            case .range(let lower, let upper):
                if case .int(let number) = subject, number >= lower, number < upper { return true }
            case .doubleRange(let lower, let upper):
                if let number = try? subject.asDouble(), number >= lower, number <= upper { return true }
            default:
                if SwiftAppValue.equal(value, subject) { return true }
            }
        }
        return false
    }

    static func viewNode(from value: SwiftAppValue) -> SwiftAppViewNode? {
        switch value {
        case .view(let node): node
        case .color: SwiftAppViewNode(name: "Color", arguments: [SwiftAppLabeledValue(label: nil, value: value)])
        case .member(let name, nil) where SwiftAppRenderer.colorNames[name] != nil:
            SwiftAppViewNode(name: "Color", arguments: [SwiftAppLabeledValue(label: nil, value: value)])
        default: nil
        }
    }

    // MARK: Expressions

    func evaluate(_ expression: SwiftAppExpr, in scope: SwiftAppScope) throws -> SwiftAppValue {
        try tick()
        switch expression {
        case .integer(let value): return .int(value)
        case .double(let value): return .double(value)
        case .bool(let value): return .bool(value)
        case .nilLiteral: return .nilValue
        case .string(let parts):
            var text = ""
            for part in parts {
                switch part {
                case .text(let value): text += value
                case .value(let arguments): text += try interpolate(arguments, in: scope)
                }
            }
            return .string(text)
        case .identifier(let name, _):
            return try lookup(name, in: scope)
        case .selfValue:
            switch scope.selfReference {
            case .record(_, let box): return box.value
            case .object(_, let object): return .object(object)
            case .enumCase(_, let value): return value
            default: throw SwiftAppRuntimeError("'self' is only available in models and enums")
            }
        case .selfMember(let name):
            guard let receiver = scope.selfReference, let value = try member(of: receiver, name) else {
                throw SwiftAppRuntimeError("Unknown member 'self.\(name)'")
            }
            return value
        case .binding(let name):
            return .binding(try binding(named: name, in: scope))
        case .implicitMember(let name):
            return .member(name, nil)
        case .member(let base, let name):
            return try property(of: try evaluate(base, in: scope), name)
        case .call(let callee, let arguments, let line):
            do { return try evaluateCall(callee, arguments, in: scope) }
            catch let error as SwiftAppRuntimeError where !error.message.hasPrefix("Line ") {
                throw SwiftAppRuntimeError("Line \(line): \(error.message)")
            }
        case .subscripted(let base, let index):
            return try subscriptValue(try evaluate(base, in: scope).resolved, try evaluate(index, in: scope).resolved)
        case .unary(let op, let operand):
            let value = try evaluate(operand, in: scope).resolved
            switch (op, value) {
            case ("!", _): return .bool(!(try value.asBool()))
            case ("-", .int(let v)): return .int(-v)
            case ("-", .double(let v)): return .double(-v)
            case ("+", _): return value
            default: throw SwiftAppRuntimeError("Cannot apply '\(op)' to \(value.debugDisplay)")
            }
        case .binary(let op, let left, let right):
            switch op {
            case "&&": return .bool(try evaluate(left, in: scope).asBool() && evaluate(right, in: scope).asBool())
            case "||": return .bool(try evaluate(left, in: scope).asBool() || evaluate(right, in: scope).asBool())
            case "??":
                let value = try evaluate(left, in: scope).resolved
                return value.isNone ? try evaluate(right, in: scope) : value
            default:
                return try binary(op, try evaluate(left, in: scope), try evaluate(right, in: scope))
            }
        case .ternary(let condition, let whenTrue, let whenFalse):
            return try evaluate(try evaluate(condition, in: scope).asBool() ? whenTrue : whenFalse, in: scope)
        case .array(let elements):
            return .array(try elements.map { try evaluate($0, in: scope).resolved })
        case .closure(let literal):
            return .closure(SwiftAppClosure(literal: literal, scope: scope))
        case .keyPath(let path):
            return .keyPath(path)
        case .tuple(let elements):
            return .tuple(try elements.map { SwiftAppLabeledValue(label: $0.label, value: try evaluate($0.value, in: scope).resolved) })
        case .operatorReference(let op):
            return .builtin("operator\(op)", nil)
        }
    }

    private func interpolate(_ arguments: [SwiftAppArgument], in scope: SwiftAppScope) throws -> String {
        guard let first = arguments.first else { return "" }
        let value = try evaluate(first.value, in: scope).resolved
        if let specifier = arguments.first(where: { $0.label == "specifier" }) {
            guard case .string(let format) = try evaluate(specifier.value, in: scope) else { return value.display }
            if case .int(let number) = value, format.contains("d") { return String(format: format, number) }
            return String(format: format, try value.asDouble())
        }
        return value.display
    }

    func binary(_ op: String, _ leftValue: SwiftAppValue, _ rightValue: SwiftAppValue) throws -> SwiftAppValue {
        let left = leftValue.resolved
        let right = rightValue.resolved
        switch op {
        case "==": return .bool(SwiftAppValue.equal(left, right))
        case "!=": return .bool(!SwiftAppValue.equal(left, right))
        case "<": return .bool(try SwiftAppValue.compare(left, right))
        case ">": return .bool(try SwiftAppValue.compare(right, left))
        case "<=": return .bool(try !SwiftAppValue.compare(right, left))
        case ">=": return .bool(try !SwiftAppValue.compare(left, right))
        case "..<":
            if case .int(let a) = left, case .int(let b) = right { return .range(a, b) }
            return .doubleRange(try left.asDouble(), try right.asDouble())
        case "...":
            if case .int(let a) = left, case .int(let b) = right { return .range(a, b + 1) }
            return .doubleRange(try left.asDouble(), try right.asDouble())
        default: break
        }
        switch (op, left, right) {
        case ("+", .string(let a), _): return .string(a + right.display)
        case ("+", .array(let a), .array(let b)): return .array(a + b)
        case (_, .int(let a), .int(let b)):
            switch op {
            case "+": return .int(a &+ b)
            case "-": return .int(a &- b)
            case "*": return .int(a &* b)
            case "/":
                guard b != 0 else { throw SwiftAppRuntimeError("Division by zero") }
                return .int(a / b)
            case "%":
                guard b != 0 else { throw SwiftAppRuntimeError("Division by zero") }
                return .int(a % b)
            default: break
            }
        default:
            let a = try left.asDouble()
            let b = try right.asDouble()
            switch op {
            case "+": return .double(a + b)
            case "-": return .double(a - b)
            case "*": return .double(a * b)
            case "/": return .double(a / b)
            case "%": return .double(a.truncatingRemainder(dividingBy: b))
            default: break
            }
        }
        throw SwiftAppRuntimeError("Unsupported operator '\(op)'")
    }

    private func subscriptValue(_ base: SwiftAppValue, _ index: SwiftAppValue) throws -> SwiftAppValue {
        switch (base, index) {
        case (.array(let values), .int(let i)):
            guard values.indices.contains(i) else { throw SwiftAppRuntimeError("Index \(i) is out of range (count \(values.count))") }
            return values[i]
        case (.array(let values), .range(let lower, let upper)):
            guard lower >= 0, upper <= values.count, lower <= upper else { throw SwiftAppRuntimeError("Range is out of bounds") }
            return .array(Array(values[lower..<upper]))
        default:
            throw SwiftAppRuntimeError("Cannot subscript \(base.debugDisplay)")
        }
    }
}
