import SwiftUI

/// The bounded standard library of the experimental SwiftUI runtime (#889).
@MainActor
enum SwiftAppBuiltins {
    static let mutatingMethods: Set<String> = [
        "append", "insert", "remove", "removeAll", "removeLast", "removeFirst", "popLast", "toggle", "shuffle",
        "sort", "reverse", "move",
    ]

    static func canMutate(_ value: SwiftAppValue) -> Bool {
        switch value {
        case .array, .bool: true
        default: false
        }
    }

    private static func positional(_ arguments: [SwiftAppLabeledValue]) -> [SwiftAppValue] {
        arguments.filter { $0.label == nil }.map(\.value)
    }

    private static func argument(_ arguments: [SwiftAppLabeledValue], _ label: String?, at index: Int = 0) throws -> SwiftAppValue {
        if let label, let value = arguments.first(where: { $0.label == label })?.value { return value }
        let values = positional(arguments)
        if label == nil || values.count > index, values.indices.contains(index) { return values[index] }
        throw SwiftAppRuntimeError("Missing argument\(label.map { " '\($0):'" } ?? "")")
    }

    private static func invoke(_ function: SwiftAppValue, _ values: [SwiftAppValue], runtime: SwiftAppRuntime) throws -> SwiftAppValue {
        try runtime.apply(function, values.map { SwiftAppLabeledValue(label: nil, value: $0) })
    }

    private static func predicate(_ function: SwiftAppValue, _ value: SwiftAppValue, runtime: SwiftAppRuntime) throws -> Bool {
        try invoke(function, [value], runtime: runtime).asBool()
    }

    // MARK: Mutation

    static func mutate(
        _ value: SwiftAppValue,
        _ name: String,
        _ arguments: [SwiftAppLabeledValue],
        runtime: SwiftAppRuntime
    ) throws -> (SwiftAppValue, SwiftAppValue) {
        switch (value, name) {
        case (.bool(let flag), "toggle"):
            return (.bool(!flag), .void)
        case (.array(var values), _):
            switch name {
            case "append":
                if let contents = arguments.first(where: { $0.label == "contentsOf" }) {
                    values += try contents.value.resolved.asArray()
                } else {
                    values.append(try argument(arguments, nil).resolved)
                }
                return (.array(values), .void)
            case "insert":
                let index = try argument(arguments, "at").asInt()
                guard index >= 0, index <= values.count else { throw SwiftAppRuntimeError("Insert index \(index) is out of range") }
                values.insert(try argument(arguments, nil).resolved, at: index)
                return (.array(values), .void)
            case "remove":
                if let offsets = arguments.first(where: { $0.label == "atOffsets" }) {
                    for index in try offsets.value.asArray().map({ try $0.asInt() }).sorted(by: >) where values.indices.contains(index) {
                        values.remove(at: index)
                    }
                    return (.array(values), .void)
                }
                let index = try argument(arguments, "at").asInt()
                guard values.indices.contains(index) else { throw SwiftAppRuntimeError("Index \(index) is out of range") }
                let removed = values.remove(at: index)
                return (.array(values), removed)
            case "removeAll":
                if let condition = arguments.first(where: { $0.label == "where" })?.value ?? positional(arguments).first {
                    values = try values.filter { try !predicate(condition, $0, runtime: runtime) }
                } else {
                    values.removeAll()
                }
                return (.array(values), .void)
            case "removeLast", "popLast":
                guard let removed = values.popLast() else {
                    if name == "popLast" { return (value, .nilValue) }
                    throw SwiftAppRuntimeError("removeLast() on an empty array")
                }
                return (.array(values), removed)
            case "removeFirst":
                guard !values.isEmpty else { throw SwiftAppRuntimeError("removeFirst() on an empty array") }
                return (.array(Array(values.dropFirst())), values[0])
            case "shuffle":
                return (.array(values.shuffled()), .void)
            case "reverse":
                return (.array(values.reversed()), .void)
            case "sort":
                return (try sorted(values, arguments, runtime: runtime), .void)
            case "move":
                let source = try argument(arguments, "fromOffsets").asArray().map { try $0.asInt() }
                let destination = try argument(arguments, "toOffset").asInt()
                let moving = source.sorted().compactMap { values.indices.contains($0) ? values[$0] : nil }
                let before = source.filter { $0 < destination }.count
                for index in source.sorted(by: >) where values.indices.contains(index) { values.remove(at: index) }
                values.insert(contentsOf: moving, at: max(0, min(values.count, destination - before)))
                return (.array(values), .void)
            default: break
            }
        default: break
        }
        throw SwiftAppRuntimeError("Unsupported mutating method '\(name)' on \(value.debugDisplay)")
    }

    private static func sorted(_ values: [SwiftAppValue], _ arguments: [SwiftAppLabeledValue], runtime: SwiftAppRuntime) throws -> SwiftAppValue {
        let order = arguments.first(where: { $0.label == "by" })?.value ?? positional(arguments).first
        var failure: Error?
        let result = values.sorted { a, b in
            do {
                if let order { return try invoke(order, [a, b], runtime: runtime).asBool() }
                return try SwiftAppValue.compare(a, b)
            } catch {
                failure = error
                return false
            }
        }
        if let failure { throw failure }
        return .array(result)
    }

    // MARK: Construction

    static func construct(_ typeName: String, _ arguments: [SwiftAppLabeledValue], runtime: SwiftAppRuntime) throws -> SwiftAppValue {
        let first = positional(arguments).first?.resolved
        switch typeName {
        case "String":
            if let format = arguments.first(where: { $0.label == "format" })?.value, case .string(let pattern) = format.resolved {
                return .string(try SwiftAppFormat.format(pattern, positional(arguments)))
            }
            return .string(first?.display ?? "")
        case "Int":
            switch first {
            case .string(let text)?: return Int(text.trimmingCharacters(in: .whitespaces)).map { .int($0) } ?? .nilValue
            case .double(let number)?: return .int(try SwiftAppValue.double(number).asInt())
            case .int?: return first!
            default: return .int(0)
            }
        case "Double", "Float", "CGFloat":
            switch first {
            case .string(let text)?: return Double(text.trimmingCharacters(in: .whitespaces)).map { .double($0) } ?? .nilValue
            case let value?: return .double(try value.asDouble())
            default: return .double(0)
            }
        case "Bool":
            if case .string(let text)? = first { return text == "true" ? .bool(true) : text == "false" ? .bool(false) : .nilValue }
            return first ?? .bool(false)
        case "Array", "Set":
            return .array(try first?.asArray() ?? [])
        case "UUID":
            return .string(UUID().uuidString)
        case "IndexSet":
            return .array(try first.map { try $0.asArray() } ?? [])
        case "Color":
            if let red = arguments.first(where: { $0.label == "red" })?.value {
                return .color(Color(
                    red: try red.asDouble(),
                    green: try argument(arguments, "green").asDouble(),
                    blue: try argument(arguments, "blue").asDouble(),
                    opacity: try arguments.first(where: { $0.label == "opacity" })?.value.asDouble() ?? 1
                ))
            }
            if let white = arguments.first(where: { $0.label == "white" })?.value {
                return .color(Color(white: try white.asDouble()))
            }
            if let hue = arguments.first(where: { $0.label == "hue" })?.value {
                return .color(Color(
                    hue: try hue.asDouble(),
                    saturation: try argument(arguments, "saturation").asDouble(),
                    brightness: try argument(arguments, "brightness").asDouble()
                ))
            }
            throw SwiftAppRuntimeError("Color supports red:green:blue:, white: or hue:saturation:brightness:")
        default:
            throw SwiftAppRuntimeError("\(typeName) is not supported")
        }
    }

    // MARK: Functions and methods

    static func call(
        _ name: String,
        receiver: SwiftAppValue?,
        _ arguments: [SwiftAppLabeledValue],
        runtime: SwiftAppRuntime
    ) throws -> SwiftAppValue {
        guard let receiver else { return try callFree(name, arguments, runtime: runtime) }
        switch receiver.resolved {
        case .view(var node):
            node.modifiers.append((name, arguments))
            return .view(node)
        case .array(let values):
            return try callArray(values, name, arguments, runtime: runtime)
        case .range:
            return try callArray(receiver.resolved.asArray(), name, arguments, runtime: runtime)
        case .string(let text):
            return try callString(text, name, arguments)
        case .int, .double:
            let number = try receiver.resolved.asDouble()
            switch name {
            case "formatted":
                if case .int(let integer) = receiver.resolved { return .string(integer.formatted()) }
                return .string(number.formatted())
            case "rounded": return .double(number.rounded())
            case "isMultiple": return .bool(try receiver.resolved.asInt().isMultiple(of: argument(arguments, "of").asInt()))
            default: break
            }
        case .color(let color):
            if name == "opacity" { return .color(color.opacity(try argument(arguments, nil).asDouble())) }
            return receiver
        case .member(let memberName, _):
            if name == "opacity", let color = SwiftAppRenderer.color(.member(memberName, nil)) {
                return .color(color.opacity(try argument(arguments, nil).asDouble()))
            }
            // Font and animation refinements (`.title.bold()`, `.spring().delay(1)`) keep the base.
            return receiver
        case .nilValue:
            return .nilValue
        default: break
        }
        throw SwiftAppRuntimeError("Unsupported method '\(name)' on \(receiver.resolved.debugDisplay)")
    }

    private static func callFree(_ name: String, _ arguments: [SwiftAppLabeledValue], runtime: SwiftAppRuntime) throws -> SwiftAppValue {
        let values = positional(arguments).map(\.resolved)
        if name.hasPrefix("operator"), values.count == 2 {
            return try runtime.binary(String(name.dropFirst("operator".count)), values[0], values[1])
        }
        switch name {
        case "min", "max":
            guard var best = values.first else { throw SwiftAppRuntimeError("\(name) needs arguments") }
            for value in values.dropFirst() where try SwiftAppValue.compare(value, best) == (name == "min") { best = value }
            return best
        case "abs":
            if case .int(let number)? = values.first {
                guard number != .min else { throw SwiftAppRuntimeError("Integer overflow") }
                return .int(abs(number))
            }
            return .double(abs(try argument(arguments, nil).asDouble()))
        case "round": return .double((try argument(arguments, nil).asDouble()).rounded())
        case "floor": return .double(Foundation.floor(try argument(arguments, nil).asDouble()))
        case "ceil": return .double(Foundation.ceil(try argument(arguments, nil).asDouble()))
        case "sqrt": return .double((try argument(arguments, nil).asDouble()).squareRoot())
        case "pow": return .double(Foundation.pow(try argument(arguments, nil, at: 0).asDouble(), try argument(arguments, nil, at: 1).asDouble()))
        case "print", "dismiss": return .void
        case "stride":
            let from = try argument(arguments, "from").asDouble()
            let step = try argument(arguments, "by").asDouble()
            guard step != 0 else { throw SwiftAppRuntimeError("stride step cannot be zero") }
            let isInt = arguments.allSatisfy { $0.value.resolved.isInt }
            let through = arguments.first(where: { $0.label == "through" })
            let end = try (through ?? arguments.first(where: { $0.label == "to" }))?.value.asDouble() ?? from
            // Bound the length before materializing anything.
            guard from.isFinite, end.isFinite, step.isFinite,
                  (end - from) / step <= Double(SwiftAppRuntime.maximumCollectionCount) else {
                throw SwiftAppRuntimeError("stride is too long")
            }
            let sequence: [Double] = through != nil ? Array(Swift.stride(from: from, through: end, by: step)) : Array(Swift.stride(from: from, to: end, by: step))
            return .array(try sequence.map { isInt ? .int(try SwiftAppValue.double($0).asInt()) : .double($0) })
        case "zip":
            guard values.count == 2 else { throw SwiftAppRuntimeError("zip needs two sequences") }
            return .array(zip(try values[0].asArray(), try values[1].asArray()).map {
                .tuple([SwiftAppLabeledValue(label: nil, value: $0), SwiftAppLabeledValue(label: nil, value: $1)])
            })
        case "withAnimation":
            guard let body = arguments.last?.value else { return .void }
            var result: SwiftAppValue = .void
            var failure: Error?
            withAnimation(SwiftAppRenderer.animation(values.count > 1 ? values.first : nil)) {
                do { result = try invoke(body, [], runtime: runtime) } catch { failure = error }
            }
            if let failure { throw failure }
            return result
        case "Int.random", "Double.random", "Float.random", "CGFloat.random":
            let range = try argument(arguments, "in").resolved
            switch range {
            case .range(let lower, let upper) where upper > lower:
                return name == "Int.random" ? .int(Int.random(in: lower..<upper)) : .double(Double.random(in: Double(lower)...Double(upper - 1)))
            case .doubleRange(let lower, let upper) where upper >= lower && lower.isFinite && upper.isFinite:
                guard name == "Int.random" else { return .double(Double.random(in: lower...upper)) }
                return .int(Int.random(in: try SwiftAppValue.double(lower).asInt()...SwiftAppValue.double(upper).asInt()))
            default:
                throw SwiftAppRuntimeError("random(in:) needs a non-empty range")
            }
        case "Bool.random":
            return .bool(Bool.random())
        default:
            throw SwiftAppRuntimeError("Unsupported function '\(name)'")
        }
    }

    private static func callArray(
        _ values: [SwiftAppValue],
        _ name: String,
        _ arguments: [SwiftAppLabeledValue],
        runtime: SwiftAppRuntime
    ) throws -> SwiftAppValue {
        let function = arguments.last?.value
        switch name {
        case "contains":
            if let condition = arguments.first(where: { $0.label == "where" })?.value {
                return .bool(try values.contains { try predicate(condition, $0, runtime: runtime) })
            }
            let needle = try argument(arguments, nil)
            if case .closure = needle { return .bool(try values.contains { try predicate(needle, $0, runtime: runtime) }) }
            return .bool(try values.contains { try runtime.equal($0, needle) })
        case "filter":
            guard let function else { break }
            return .array(try values.filter { try predicate(function, $0, runtime: runtime) })
        case "map", "compactMap":
            guard let function else { break }
            let mapped = try values.map { try invoke(function, [$0], runtime: runtime).resolved }
            return .array(name == "map" ? mapped : mapped.filter { !$0.isNone })
        case "forEach":
            guard let function else { break }
            for value in values { _ = try invoke(function, [value], runtime: runtime) }
            return .void
        case "reduce":
            guard let function else { break }
            return try values.reduce(try argument(arguments, nil, at: 0)) { try invoke(function, [$0, $1], runtime: runtime) }
        case "allSatisfy":
            guard let function else { break }
            return .bool(try values.allSatisfy { try predicate(function, $0, runtime: runtime) })
        case "first", "last":
            guard let condition = arguments.first(where: { $0.label == "where" })?.value ?? function else { break }
            let ordered = name == "first" ? values : values.reversed()
            return try ordered.first { try predicate(condition, $0, runtime: runtime) } ?? .nilValue
        case "firstIndex", "lastIndex":
            let indices = name == "firstIndex" ? Array(values.indices) : values.indices.reversed()
            if let needle = arguments.first(where: { $0.label == "of" })?.value {
                return try indices.first { try runtime.equal(values[$0], needle) }.map { .int($0) } ?? .nilValue
            }
            guard let condition = arguments.first(where: { $0.label == "where" })?.value ?? function else { break }
            return try indices.first { try predicate(condition, values[$0], runtime: runtime) }.map { .int($0) } ?? .nilValue
        case "count":
            guard let condition = arguments.first(where: { $0.label == "where" })?.value else { break }
            return .int(try values.filter { try predicate(condition, $0, runtime: runtime) }.count)
        case "sorted": return try sorted(values, arguments, runtime: runtime)
        case "reversed": return .array(values.reversed())
        case "shuffled": return .array(values.shuffled())
        case "randomElement": return values.randomElement() ?? .nilValue
        case "enumerated":
            return .array(values.enumerated().map {
                .tuple([SwiftAppLabeledValue(label: "offset", value: .int($0.offset)), SwiftAppLabeledValue(label: "element", value: $0.element)])
            })
        case "prefix": return .array(Array(values.prefix(max(0, try argument(arguments, nil).asInt()))))
        case "suffix": return .array(Array(values.suffix(max(0, try argument(arguments, nil).asInt()))))
        case "dropFirst": return .array(Array(values.dropFirst(max(0, (try? argument(arguments, nil).asInt()) ?? 1))))
        case "dropLast": return .array(Array(values.dropLast(max(0, (try? argument(arguments, nil).asInt()) ?? 1))))
        case "joined":
            let separator = (try? argument(arguments, "separator"))?.display ?? ""
            var text = ""
            for (index, value) in values.enumerated() {
                if index > 0 { text += separator }
                text += value.display
                // Stop as soon as the result is too large rather than after building it.
                guard text.utf8.count <= SwiftAppRuntime.maximumStringBytes else { return try runtime.admit(.string(text)) }
            }
            return .string(text)
        case "min", "max":
            guard var best = values.first else { return .nilValue }
            for value in values.dropFirst() where try SwiftAppValue.compare(value, best) == (name == "min") { best = value }
            return best
        default: break
        }
        throw SwiftAppRuntimeError("Unsupported array method '\(name)'")
    }

    private static func callString(_ text: String, _ name: String, _ arguments: [SwiftAppLabeledValue]) throws -> SwiftAppValue {
        func string(_ label: String?) throws -> String { try argument(arguments, label).resolved.display }
        switch name {
        case "uppercased": return .string(text.uppercased())
        case "lowercased": return .string(text.lowercased())
        case "contains": return .bool(text.contains(try string(nil)))
        case "hasPrefix": return .bool(text.hasPrefix(try string(nil)))
        case "hasSuffix": return .bool(text.hasSuffix(try string(nil)))
        case "trimmingCharacters": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case "replacingOccurrences":
            let target = try string("of"), replacement = try string("with")
            // Reject a result past the string limit before building it.
            if !target.isEmpty, replacement.utf8.count > target.utf8.count {
                let occurrences = text.components(separatedBy: target).count - 1
                guard text.utf8.count + occurrences * (replacement.utf8.count - target.utf8.count) <= SwiftAppRuntime.maximumStringBytes else {
                    throw SwiftAppRuntimeError("Stopped: a string grew past \(SwiftAppRuntime.maximumStringBytes) bytes")
                }
            }
            return .string(text.replacingOccurrences(of: target, with: replacement))
        case "split", "components":
            let separator = try string(name == "split" ? "separator" : "separatedBy")
            return .array(text.components(separatedBy: separator).filter { name == "components" || !$0.isEmpty }.map { .string($0) })
        case "prefix": return .string(String(text.prefix(max(0, try argument(arguments, nil).asInt()))))
        case "suffix": return .string(String(text.suffix(max(0, try argument(arguments, nil).asInt()))))
        default: throw SwiftAppRuntimeError("Unsupported String method '\(name)'")
        }
    }
}

extension SwiftAppValue {
    var isInt: Bool { if case .int = self { true } else { false } }
}
