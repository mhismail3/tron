import Foundation

/// The checked `printf` subset behind `String(format:)` and interpolation
/// `specifier:` (#889). Foundation's formatter reads C varargs by the types the
/// format names, so a format chosen by the program must never reach it with a
/// mismatched argument: `%s` or `%@` against a number reads arbitrary memory.
/// Each conversion is parsed here, paired with one argument of the right
/// dynamic type, and only a single well-formed numeric conversion is handed to
/// Foundation. Strings are padded here. `*` widths, positional arguments and
/// `%n` are rejected.
@MainActor
enum SwiftAppFormat {
    /// Largest width or precision; bigger values only allocate.
    static let maximumField = 64

    static func format(_ pattern: String, _ values: [SwiftAppValue]) throws -> String {
        var output = ""
        var arguments = values[...]
        let characters = Array(pattern)
        var index = 0
        func fail(_ reason: String) -> SwiftAppRuntimeError {
            SwiftAppRuntimeError("Unsupported format \"\(pattern)\": \(reason)")
        }
        while index < characters.count {
            guard characters[index] == "%" else {
                output.append(characters[index])
                index += 1
                continue
            }
            index += 1
            var flags = ""
            while index < characters.count, "-+ 0#".contains(characters[index]) {
                flags.append(characters[index])
                index += 1
            }
            func number() throws -> Int? {
                var digits = ""
                while index < characters.count, characters[index].isASCII, characters[index].isNumber {
                    digits.append(characters[index])
                    index += 1
                }
                guard !digits.isEmpty else { return nil }
                guard digits.count <= 2, let value = Int(digits), value <= maximumField else {
                    throw fail("widths and precisions are limited to \(maximumField)")
                }
                return value
            }
            let width = try number()
            var precision: Int?
            if index < characters.count, characters[index] == "." {
                index += 1
                precision = try number() ?? 0
            }
            // Length modifiers do not change Swift's 64-bit Int or Double.
            while index < characters.count, "lhqzjt".contains(characters[index]) { index += 1 }
            guard index < characters.count else { throw fail("incomplete conversion") }
            let conversion = characters[index]
            index += 1
            if conversion == "%" {
                guard flags.isEmpty, width == nil, precision == nil else { throw fail("malformed '%%'") }
                output.append("%")
                continue
            }
            guard let value = arguments.popFirst()?.resolved else {
                throw fail("more conversions than arguments")
            }
            let spec = "%" + flags + (width.map(String.init) ?? "") + (precision.map { ".\($0)" } ?? "")
            switch conversion {
            case "d", "i", "u", "x", "X", "o":
                output += String(format: spec + "l" + String(conversion), try value.asInt())
            case "f", "F", "e", "E", "g", "G":
                output += String(format: spec + String(conversion), try value.asDouble())
            case "s", "@":
                var text = value.display
                if let precision { text = String(text.prefix(precision)) }
                let padding = String(repeating: " ", count: max(0, (width ?? 0) - text.count))
                output += flags.contains("-") ? text + padding : padding + text
            default:
                throw fail("'%\(conversion)' is not supported")
            }
        }
        return output
    }
}
