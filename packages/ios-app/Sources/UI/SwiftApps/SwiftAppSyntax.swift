import Foundation

// Experimental single-file SwiftUI interpreter (#889). This file owns the
// lexer and AST; `SwiftAppParser` builds the AST and `SwiftAppRuntime`
// evaluates it. The language is a bounded SwiftUI subset documented in
// docs/swift-apps.md; anything outside it is a readable diagnostic, never a
// crash and never native code execution.

struct SwiftAppSyntaxError: Error, CustomStringConvertible {
    let message: String
    let line: Int
    var description: String { "Line \(line): \(message)" }
}

/// A refused parse, never a runnable partial program.
struct SwiftAppUnsupportedSyntax: Error, CustomStringConvertible {
    let diagnostics: [SwiftAppSyntaxError]
    let reachedLimit: Bool
    var description: String {
        diagnostics.sorted { $0.line < $1.line }.map(\.description).joined(separator: "\n")
            + (reachedLimit ? "\nStopped after 10 unsupported constructs; more may remain." : "")
    }
}

enum SwiftAppStringPart {
    case text(String)
    /// Raw source of one `\( … )` segment, parsed as an argument list so
    /// `\(value, specifier: "%.1f")` works.
    case interpolation(String, line: Int)
}

enum SwiftAppTokenKind {
    case identifier(String)
    case integer(Int)
    case double(Double)
    case string([SwiftAppStringPart])
    case symbol(String)
    case end
}

struct SwiftAppToken {
    let kind: SwiftAppTokenKind
    let line: Int
    let newlineBefore: Bool
    let spaceBefore: Bool

    var identifier: String? { if case .identifier(let v) = kind { v } else { nil } }
    var symbol: String? { if case .symbol(let v) = kind { v } else { nil } }
    func isSymbol(_ value: String) -> Bool { symbol == value }
    func isIdentifier(_ value: String) -> Bool { identifier == value }
}

enum SwiftAppLexer {
    private static let symbols = [
        "...", "..<", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "->", "??",
        "{", "}", "(", ")", "[", "]", ",", ":", ".", ";", "@", "=", "<", ">", "+", "-", "*", "/",
        "%", "!", "?", "\\", "&", "|", "#", "_",
    ]

    static func tokenize(_ source: String) throws -> [SwiftAppToken] {
        let chars = Array(source)
        var index = 0
        var line = 1
        var tokens: [SwiftAppToken] = []
        var newlineBefore = true
        var spaceBefore = true

        func peek(_ offset: Int = 0) -> Character? {
            index + offset < chars.count ? chars[index + offset] : nil
        }
        func push(_ kind: SwiftAppTokenKind, line tokenLine: Int) {
            tokens.append(SwiftAppToken(kind: kind, line: tokenLine, newlineBefore: newlineBefore, spaceBefore: spaceBefore))
            newlineBefore = false
            spaceBefore = false
        }

        while index < chars.count {
            let c = chars[index]
            if c == "\n" { line += 1; index += 1; newlineBefore = true; spaceBefore = true; continue }
            if c.isWhitespace { index += 1; spaceBefore = true; continue }
            if c == "/", peek(1) == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if c == "/", peek(1) == "*" {
                index += 2
                while index < chars.count, !(chars[index] == "*" && peek(1) == "/") {
                    if chars[index] == "\n" { line += 1; newlineBefore = true }
                    index += 1
                }
                index += 2; spaceBefore = true
                continue
            }
            if c == "\"" {
                let start = line
                let multiline = peek(1) == "\"" && peek(2) == "\""
                index += multiline ? 3 : 1
                if multiline, peek() == "\n" { index += 1; line += 1 }
                var parts: [SwiftAppStringPart] = []
                var text = ""
                while true {
                    guard let ch = peek() else { throw SwiftAppSyntaxError(message: "Unterminated string", line: start) }
                    if multiline {
                        if ch == "\"", peek(1) == "\"", peek(2) == "\"" { index += 3; break }
                    } else if ch == "\"" { index += 1; break }
                    if ch == "\n" {
                        guard multiline else { throw SwiftAppSyntaxError(message: "Unterminated string", line: start) }
                        line += 1
                    }
                    if ch == "\\" {
                        guard let next = peek(1) else { throw SwiftAppSyntaxError(message: "Unterminated string", line: start) }
                        if next == "(" {
                            if !text.isEmpty { parts.append(.text(text)); text = "" }
                            index += 2
                            var depth = 1
                            var raw = ""
                            var inString = false
                            while let inner = peek() {
                                if inner == "\"" { inString.toggle() }
                                if !inString {
                                    if inner == "(" { depth += 1 }
                                    if inner == ")" { depth -= 1; if depth == 0 { break } }
                                }
                                raw.append(inner); index += 1
                            }
                            guard peek() == ")" else { throw SwiftAppSyntaxError(message: "Unterminated interpolation", line: line) }
                            index += 1
                            parts.append(.interpolation(raw, line: line))
                            continue
                        }
                        index += 2
                        switch next {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        case "0": text.append("\0")
                        default: text.append(next)
                        }
                        continue
                    }
                    text.append(ch); index += 1
                }
                if multiline, text.hasSuffix("\n") { text.removeLast() }
                if !text.isEmpty || parts.isEmpty { parts.append(.text(text)) }
                push(.string(parts), line: start)
                continue
            }
            if c.isNumber {
                var raw = ""
                var isDouble = false
                while let ch = peek(), ch.isNumber || ch == "_" || (ch == "." && !isDouble && (peek(1)?.isNumber ?? false)) {
                    if ch == "." { isDouble = true }
                    if ch != "_" { raw.append(ch) }
                    index += 1
                }
                if isDouble { push(.double(Double(raw) ?? 0), line: line) }
                else { push(.integer(Int(raw) ?? 0), line: line) }
                continue
            }
            if c.isLetter || c == "_" || c == "$" || c == "`" {
                var raw = ""
                if c == "$" { raw.append(c); index += 1 }
                if c == "`" { index += 1 }
                while let ch = peek(), ch.isLetter || ch.isNumber || ch == "_" { raw.append(ch); index += 1 }
                if c == "`", peek() == "`" { index += 1 }
                if raw == "_" { push(.symbol("_"), line: line) } else { push(.identifier(raw), line: line) }
                continue
            }
            guard let symbol = symbols.first(where: { candidate in
                let s = Array(candidate)
                return index + s.count <= chars.count && Array(chars[index..<index + s.count]) == s
            }) else {
                throw SwiftAppSyntaxError(message: "Unexpected character '\(c)'", line: line)
            }
            index += symbol.count
            push(.symbol(symbol), line: line)
        }
        tokens.append(SwiftAppToken(kind: .end, line: line, newlineBefore: true, spaceBefore: true))
        return tokens
    }
}

// MARK: - AST

struct SwiftAppArgument {
    let label: String?
    let value: SwiftAppExpr
}

indirect enum SwiftAppInterpolatedPart {
    case text(String)
    case value([SwiftAppArgument])
}

final class SwiftAppClosureLiteral {
    let parameters: [String]
    let body: [SwiftAppStmt]
    init(parameters: [String], body: [SwiftAppStmt]) {
        self.parameters = parameters
        self.body = body
    }
}

indirect enum SwiftAppExpr {
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case string([SwiftAppInterpolatedPart])
    case nilLiteral
    case identifier(String, line: Int)
    case selfValue
    case selfMember(String)
    case binding(String)
    case implicitMember(String)
    case member(SwiftAppExpr, String)
    case optional(SwiftAppExpr)
    case force(SwiftAppExpr)
    /// Ends only this postfix chain; parentheses naturally nest another boundary.
    case chain(SwiftAppExpr)
    case call(SwiftAppExpr, [SwiftAppArgument], line: Int)
    case subscripted(SwiftAppExpr, SwiftAppExpr, defaultValue: SwiftAppExpr?)
    case unary(String, SwiftAppExpr)
    case binary(String, SwiftAppExpr, SwiftAppExpr)
    case ternary(SwiftAppExpr, SwiftAppExpr, SwiftAppExpr)
    case array([SwiftAppExpr])
    case dictionary([(SwiftAppExpr, SwiftAppExpr)])
    case closure(SwiftAppClosureLiteral)
    case keyPath([String])
    case tuple([SwiftAppArgument])
    case operatorReference(String)
}

enum SwiftAppCondition {
    case expression(SwiftAppExpr)
    case optionalBinding(String, SwiftAppExpr)
}

indirect enum SwiftAppPattern {
    case value(SwiftAppExpr), binding(String), wildcard
    /// nil omits payload matching; [] is an explicit empty argument list.
    case enumeration(String?, String, [SwiftAppPatternArgument]?)
}

struct SwiftAppPatternArgument {
    let label: String?
    let pattern: SwiftAppPattern
}

struct SwiftAppSwitchCase {
    /// `nil` is `default`.
    let patterns: [SwiftAppPattern]?
    let body: [SwiftAppStmt]
}

indirect enum SwiftAppStmt {
    case declaration(String, SwiftAppExpr?)
    case expression(SwiftAppExpr, line: Int)
    case assignment(SwiftAppExpr, String, SwiftAppExpr, line: Int)
    case conditional([(conditions: [SwiftAppCondition], body: [SwiftAppStmt])], otherwise: [SwiftAppStmt]?)
    case guardStatement([SwiftAppCondition], [SwiftAppStmt])
    case forIn(String, [String]?, SwiftAppExpr, filter: SwiftAppExpr?, [SwiftAppStmt])
    case whileLoop([SwiftAppCondition], [SwiftAppStmt])
    case switchStatement(SwiftAppExpr, [SwiftAppSwitchCase])
    case returnStatement(SwiftAppExpr?)
    case breakStatement
    case continueStatement
}

struct SwiftAppParameter {
    let label: String?
    let name: String
    let defaultValue: SwiftAppExpr?
}

final class SwiftAppFunction {
    let name: String
    let parameters: [SwiftAppParameter]
    let body: [SwiftAppStmt]
    let isMutating: Bool
    let isStatic: Bool
    init(name: String, parameters: [SwiftAppParameter], body: [SwiftAppStmt], isMutating: Bool, isStatic: Bool) {
        self.name = name
        self.parameters = parameters
        self.body = body
        self.isMutating = isMutating
        self.isStatic = isStatic
    }
}

struct SwiftAppStoredProperty {
    let name: String
    /// Property wrapper name without `@`, such as `State` or `Binding`.
    let wrapper: String?
    let typeName: String?
    let initialValue: SwiftAppExpr?
    let isStatic: Bool
}

final class SwiftAppTypeDeclaration {
    enum Kind { case structure, classType, enumeration }
    let name: String
    let kind: Kind
    var conformances: [String] = []
    var stored: [SwiftAppStoredProperty] = []
    var computed: [String: [SwiftAppStmt]] = [:]
    var functions: [String: SwiftAppFunction] = [:]
    var initializer: SwiftAppFunction?
    var cases: [String] = []
    /// Labels only: payload types are erased like other annotations.
    var payloads: [String: [String?]] = [:]
    var rawValues: [String: SwiftAppExpr] = [:]
    init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    var isView: Bool { conformances.contains("View") }
    var isApp: Bool { conformances.contains("App") }
}

struct SwiftAppProgramSyntax {
    var types: [String: SwiftAppTypeDeclaration] = [:]
    var typeOrder: [String] = []
    var functions: [String: SwiftAppFunction] = [:]
    var globals: [(String, SwiftAppExpr)] = []
}
