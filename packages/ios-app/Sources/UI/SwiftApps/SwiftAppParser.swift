import Foundation

/// Recursive-descent parser for the experimental SwiftUI subset (#889).
/// Type annotations are read and discarded: the runtime is dynamically typed.
struct SwiftAppParser {
    private var tokens: [SwiftAppToken]
    private var position = 0
    /// `if`/`for`/`while`/`switch` heads cannot take trailing closures, as in Swift.
    private var forbidTrailingClosure = false
    /// Syntax nesting so far. It bounds the AST depth, which bounds the
    /// evaluator's recursion and the recursive release of the tree; the stack
    /// guard bounds the parser's own recursion.
    private var nesting = 0
    private var unsupported: [SwiftAppSyntaxError] = []
    static let maximumNesting = 256

    init(tokens: [SwiftAppToken], nesting: Int = 0) {
        self.tokens = tokens
        self.nesting = nesting
    }

    static func parse(_ source: String) throws -> SwiftAppProgramSyntax {
        var parser = SwiftAppParser(tokens: try SwiftAppLexer.tokenize(source))
        do { return try parser.parseProgram() }
        catch let error as SwiftAppSyntaxError {
            // A fatal syntax error ends recovery, but must not erase the
            // independent unsupported constructs already found before it.
            guard !parser.unsupported.isEmpty else { throw error }
            throw SwiftAppUnsupportedSyntax(diagnostics: parser.unsupported + [error], reachedLimit: false)
        }
    }

    static func parseArguments(_ source: String, line: Int, nesting: Int) throws -> [SwiftAppArgument] {
        var parser = SwiftAppParser(tokens: try SwiftAppLexer.tokenize(source).map {
            SwiftAppToken(kind: $0.kind, line: line, newlineBefore: $0.newlineBefore, spaceBefore: $0.spaceBefore)
        }, nesting: nesting)
        var arguments: [SwiftAppArgument] = []
        while !parser.atEnd {
            arguments.append(try parser.parseArgument())
            if !parser.consumeSymbol(",") { break }
        }
        guard parser.atEnd else { throw parser.error("Unsupported interpolation") }
        try parser.requireSupportedSyntax()
        return arguments
    }

    // MARK: Token helpers

    private var current: SwiftAppToken { tokens[position] }
    private var atEnd: Bool { if case .end = current.kind { true } else { false } }
    private func peek(_ offset: Int) -> SwiftAppToken { tokens[min(position + offset, tokens.count - 1)] }
    private mutating func advance() { if position < tokens.count - 1 { position += 1 } }
    private func error(_ message: String) -> SwiftAppSyntaxError {
        SwiftAppSyntaxError(message: message, line: current.line)
    }
    /// Enters one nesting level; callers pair it with `nesting -= 1`.
    private mutating func nest() throws {
        guard nesting < Self.maximumNesting, SwiftAppStackGuard.hasHeadroom() else {
            throw error("Code is nested too deeply")
        }
        nesting += 1
    }
    private mutating func consumeSymbol(_ value: String) -> Bool {
        if current.isSymbol(value) { advance(); return true }
        return false
    }
    private mutating func consumeIdentifier(_ value: String) -> Bool {
        if current.isIdentifier(value) { advance(); return true }
        return false
    }
    private mutating func expectSymbol(_ value: String) throws {
        guard consumeSymbol(value) else { throw error("Expected '\(value)'\(describeCurrent)") }
    }
    private mutating func expectIdentifier() throws -> String {
        guard let name = current.identifier else { throw error("Expected a name\(describeCurrent)") }
        advance()
        return name
    }
    private var describeCurrent: String {
        switch current.kind {
        case .identifier(let v): " but found '\(v)'"
        case .symbol(let v): " but found '\(v)'"
        case .end: " at end of file"
        default: ""
        }
    }

    /// Recovery is grammar-owned: callers consume a known complete construct.
    /// Malformed input, lexer errors and nesting exhaustion still fail closed.
    private mutating func recordUnsupported(_ message: String, line: Int) throws {
        unsupported.append(SwiftAppSyntaxError(message: message, line: line))
        if unsupported.count == 10 {
            throw SwiftAppUnsupportedSyntax(diagnostics: unsupported, reachedLimit: true)
        }
    }

    private func requireSupportedSyntax() throws {
        if !unsupported.isEmpty {
            throw SwiftAppUnsupportedSyntax(diagnostics: unsupported, reachedLimit: false)
        }
    }

    private mutating func skipBalanced(open: String, close: String) throws {
        try expectSymbol(open)
        var depth = 1
        while depth > 0 {
            if atEnd { throw error("Unbalanced '\(open)'") }
            if current.isSymbol(open) { depth += 1 }
            if current.isSymbol(close) { depth -= 1 }
            advance()
        }
    }

    /// Generic types are retained only as syntax documentation. Recursive
    /// parsing keeps malformed delimiters and nesting exhaustion fatal.
    private mutating func parseGenericType() throws {
        try nest()
        defer { nesting -= 1 }
        if consumeSymbol("[") {
            try parseGenericType()
            try expectSymbol("]")
            return
        }
        if consumeSymbol("(") {
            try parseGenericType()
            while consumeSymbol(",") { try parseGenericType() }
            try expectSymbol(")")
            return
        }
        _ = try expectIdentifier()
        while consumeSymbol(".") { _ = try expectIdentifier() }
        if consumeSymbol("<") {
            try parseGenericType()
            while consumeSymbol(",") { try parseGenericType() }
            try expectSymbol(">")
        }
    }

    private mutating func parseGenericTypeComposition() throws {
        try parseGenericType()
        while consumeSymbol("&") { try parseGenericType() }
    }

    /// Parses declaration parameters and explicit specializations while erasing
    /// their type metadata; malformed clauses remain fatal.
    private mutating func parseGenericParameterClause() throws {
        try nest()
        defer { nesting -= 1 }
        try expectSymbol("<")
        repeat {
            _ = try expectIdentifier()
            if consumeSymbol(":") { try parseGenericTypeComposition() }
            if !current.isSymbol(">"), !current.isSymbol(",") {
                throw error("Malformed generic parameter clause")
            }
        } while consumeSymbol(",")
        try expectSymbol(">")
    }

    private mutating func parseGenericArgumentClause() throws {
        try nest()
        defer { nesting -= 1 }
        try expectSymbol("<")
        try parseGenericType()
        while consumeSymbol(",") { try parseGenericType() }
        try expectSymbol(">")
    }

    private mutating func skipWhereConstraints(requiresBody: Bool = true) throws {
        try nest()
        defer { nesting -= 1 }
        repeat {
            try parseGenericType()
            if consumeSymbol(":") {
                try parseGenericTypeComposition()
            } else if consumeSymbol("==") {
                try parseGenericType()
            } else {
                throw error("Expected ':' or '==' in where constraint")
            }
        } while consumeSymbol(",")
        if requiresBody, !current.isSymbol("{") { throw error("Malformed where constraints") }
    }

    /// Reads and discards a type, returning its leading name.
    @discardableResult
    private mutating func skipType() throws -> String? {
        try nest()
        defer { nesting -= 1 }
        while let word = current.identifier, ["some", "any", "inout", "borrowing", "consuming"].contains(word) { advance() }
        var name: String?
        if current.isSymbol("[") {
            try skipBalanced(open: "[", close: "]")
        } else if current.isSymbol("(") {
            try skipBalanced(open: "(", close: ")")
        } else if let identifier = current.identifier {
            name = identifier
            advance()
            while current.isSymbol("."), peek(1).identifier != nil { advance(); name = current.identifier; advance() }
            if current.isSymbol("<"), !current.spaceBefore { try skipBalanced(open: "<", close: ">") }
        } else {
            throw error("Expected a type\(describeCurrent)")
        }
        while (current.isSymbol("?") || current.isSymbol("!")) && !current.spaceBefore { advance() }
        if current.isSymbol("&") { advance(); try skipType() }
        if current.isSymbol("->") { advance(); try skipType() }
        return name
    }

    private mutating func skipAttributeArguments() throws {
        if current.isSymbol("("), !current.spaceBefore { try skipBalanced(open: "(", close: ")") }
    }

    // MARK: Declarations

    private static let declarationModifiers: Set<String> = [
        "private", "fileprivate", "public", "internal", "open", "final", "nonisolated", "lazy",
        "weak", "override", "required", "convenience", "indirect", "dynamic",
    ]

    mutating func parseProgram() throws -> SwiftAppProgramSyntax {
        var program = SwiftAppProgramSyntax()
        while !atEnd {
            if consumeSymbol(";") { continue }
            if consumeIdentifier("import") {
                _ = try expectIdentifier()
                while current.isSymbol("."), !current.newlineBefore { advance(); _ = try expectIdentifier() }
                continue
            }
            if current.isSymbol("#") {
                // `#Preview { … }` and other macros are design-time only.
                advance(); _ = try expectIdentifier()
                if current.isSymbol("(") { try skipBalanced(open: "(", close: ")") }
                if current.isSymbol("{") { try skipBalanced(open: "{", close: "}") }
                continue
            }
            let attributes = try parseAttributes()
            var isStatic = false
            while let word = current.identifier, Self.declarationModifiers.contains(word) || word == "static" {
                if word == "static" { isStatic = true }
                advance()
            }
            guard let keyword = current.identifier else { throw error("Expected a declaration\(describeCurrent)") }
            switch keyword {
            case "struct", "class", "enum", "extension":
                try parseType(keyword: keyword, into: &program)
            case "protocol":
                try parseProtocol()
            case "func":
                let function = try parseFunction(isStatic: isStatic, isMutating: false)
                program.functions[function.name] = function
            case "let", "var":
                advance()
                let name = try expectIdentifier()
                if consumeSymbol(":") { try skipType() }
                try expectSymbol("=")
                program.globals.append((name, try parseExpression()))
            case "typealias":
                advance(); _ = try expectIdentifier(); try expectSymbol("="); try skipType()
            default:
                throw error("Unsupported top-level declaration '\(keyword)'")
            }
            _ = attributes
        }
        try requireSupportedSyntax()
        return program
    }

    private mutating func parseAttributes() throws -> [String] {
        var attributes: [String] = []
        while consumeSymbol("@") {
            attributes.append(try expectIdentifier())
            try skipAttributeArguments()
        }
        return attributes
    }

    private mutating func parseType(keyword: String, into program: inout SwiftAppProgramSyntax) throws {
        let line = current.line
        advance()
        let name = try expectIdentifier()
        if current.isSymbol("<") {
            if keyword == "struct" {
                try parseGenericParameterClause()
            } else {
                try recordUnsupported("Generic \(keyword) declarations are not supported", line: current.line)
                try parseGenericParameterClause()
            }
        }
        let declaration: SwiftAppTypeDeclaration
        if keyword == "extension" {
            guard let existing = program.types[name] else {
                // Never silently erase default implementations or forward extensions.
                try recordUnsupported("Extensions require a previously declared concrete type ('\(name)')", line: line)
                while !current.isSymbol("{"), !atEnd { advance() }
                try skipBalanced(open: "{", close: "}")
                return
            }
            declaration = existing
        } else {
            let kind: SwiftAppTypeDeclaration.Kind = keyword == "struct" ? .structure : keyword == "class" ? .classType : .enumeration
            declaration = SwiftAppTypeDeclaration(name: name, kind: kind)
            program.types[name] = declaration
            program.typeOrder.append(name)
        }
        if consumeSymbol(":") {
            repeat { if let type = try skipType() { declaration.conformances.append(type) } } while consumeSymbol(",")
        }
        if consumeIdentifier("where") {
            if keyword != "struct" { try recordUnsupported("Where constraints are only supported on structs and functions", line: current.line) }
            try skipWhereConstraints()
        }
        try expectSymbol("{")
        while !consumeSymbol("}") {
            if atEnd { throw error("Unterminated declaration of \(name)") }
            if consumeSymbol(";") { continue }
            if current.isSymbol("#") {
                advance(); _ = try expectIdentifier()
                if current.isSymbol("(") { try skipBalanced(open: "(", close: ")") }
                continue
            }
            let attributes = try parseAttributes()
            var isStatic = false
            var isMutating = false
            while let word = current.identifier,
                  Self.declarationModifiers.contains(word) || word == "static" || word == "mutating" || word == "class" && peek(1).identifier != nil && ["func", "var", "let"].contains(peek(1).identifier!) {
                if word == "static" || word == "class" { isStatic = true }
                if word == "mutating" { isMutating = true }
                if word == "convenience" { try recordUnsupported("Convenience initializers are not supported", line: current.line) }
                advance()
            }
            guard let word = current.identifier else { throw error("Unexpected '\(current.symbol ?? "token")' in \(name)") }
            switch word {
            case "struct", "class", "enum", "extension":
                try parseType(keyword: word, into: &program)
            case "case":
                advance()
                repeat {
                    let caseName = try expectIdentifier()
                    guard !declaration.cases.contains(caseName) else { throw error("Duplicate enum case '\(caseName)'") }
                    var labels: [String?] = []
                    if consumeSymbol("(") {
                        repeat {
                            var label: String?
                            if peek(1).isSymbol(":"), let name = current.identifier ?? current.symbol {
                                label = name == "_" ? nil : name
                                advance(); advance()
                            }
                            try skipType()
                            labels.append(label)
                        } while consumeSymbol(",")
                        try expectSymbol(")")
                        guard declaration.rawValues.isEmpty,
                              declaration.conformances.allSatisfy({ !["Int", "String", "Double", "Float"].contains($0) }) else {
                            throw error("Raw-value enums cannot have payloads")
                        }
                    }
                    declaration.payloads[caseName] = labels
                    if consumeSymbol("=") {
                        guard declaration.payloads.values.allSatisfy(\.isEmpty) else { throw error("Payload cases cannot have raw values") }
                        declaration.rawValues[caseName] = try parsePrimary()
                    }
                    declaration.cases.append(caseName)
                } while consumeSymbol(",")
            case "func":
                let function = try parseFunction(isStatic: isStatic, isMutating: isMutating)
                declaration.functions[function.name] = function
            case "init" where !declaration.isView && !declaration.isApp && declaration.kind != .enumeration
                && !peek(1).isSymbol("?") && !peek(1).isSymbol("!"):
                guard declaration.initializer == nil else { throw error("Initializer overloads are not supported") }
                let signature = try parseFunctionSignature(requiresBody: true, initializer: true)
                guard Set(signature.parameters.map(\.name)).count == signature.parameters.count else {
                    throw error("Duplicate initializer parameter")
                }
                declaration.initializer = SwiftAppFunction(name: "init", parameters: signature.parameters,
                    body: try parseBlock(), isMutating: true, isStatic: false)
            case "init", "deinit":
                try recordUnsupported("Custom initializers/deinitializers are not supported (\(word)); use property defaults", line: current.line)
                advance()
                // The signature and body have explicit delimiters. Do not
                // guess a new declaration boundary after malformed syntax.
                _ = consumeSymbol("?") || consumeSymbol("!")
                if current.isSymbol("(") { try skipBalanced(open: "(", close: ")") }
                while current.isIdentifier("throws") || current.isIdentifier("async") { advance() }
                try skipBalanced(open: "{", close: "}")
            case "typealias":
                advance(); _ = try expectIdentifier(); try expectSymbol("="); try skipType()
            case "var", "let":
                let isVariable = word == "var"
                advance()
                let propertyName = try expectIdentifier()
                var typeName: String?
                var isOptional = false
                if consumeSymbol(":") { typeName = try skipType(); isOptional = tokens[position - 1].isSymbol("?") }
                var initial: SwiftAppExpr?
                if consumeSymbol("=") { initial = try parseExpression() }
                if current.isSymbol("{") {
                    if initial != nil {
                        // didSet/willSet observers are outside the subset.
                        try skipBalanced(open: "{", close: "}")
                    } else {
                        declaration.computed[propertyName] = try parseComputedBody()
                        continue
                    }
                }
                declaration.stored.append(SwiftAppStoredProperty(
                    name: propertyName,
                    wrapper: attributes.last,
                    typeName: typeName,
                    initialValue: initial,
                    isStatic: isStatic,
                    isImplicitNil: isVariable && isOptional && initial == nil
                ))
            default:
                throw error("Unsupported member '\(word)' in \(name)")
            }
        }
    }

    private mutating func parseComputedBody() throws -> [SwiftAppStmt] {
        try expectSymbol("{")
        if current.isIdentifier("get"), peek(1).isSymbol("{") {
            advance()
            let body = try parseBlock()
            while !consumeSymbol("}") {
                if atEnd { throw error("Unterminated accessor") }
                advance()
            }
            return body
        }
        position -= 1
        return try parseBlock()
    }

    /// Requirements are syntax-only metadata. Parse their structure rather than
    /// skipping a body, so executable/default implementations cannot disappear.
    private mutating func parseProtocol() throws {
        try nest()
        defer { nesting -= 1 }
        advance() // protocol
        _ = try expectIdentifier()
        if current.isSymbol("<") { try parseGenericParameterClause() }
        if consumeSymbol(":") { repeat { try skipType() } while consumeSymbol(",") }
        if consumeIdentifier("where") { try skipWhereConstraints() }
        try expectSymbol("{")
        while !consumeSymbol("}") {
            if consumeSymbol(";") { continue }
            _ = try parseAttributes()
            while let word = current.identifier,
                  Self.declarationModifiers.contains(word) || ["static", "mutating", "nonmutating"].contains(word) { advance() }
            switch current.identifier {
            case "var":
                advance(); _ = try expectIdentifier()
                try expectSymbol(":"); try skipType(); try expectSymbol("{")
                guard consumeIdentifier("get") else { throw error("Protocol accessors must be get or get set") }
                _ = consumeIdentifier("set")
                guard consumeSymbol("}") else { throw error("Protocol accessors must be get or get set") }
            case "func":
                _ = try parseFunctionSignature(requiresBody: false)
                if current.isSymbol("{") { throw error("Protocol requirements cannot contain implementations") }
            case "associatedtype":
                advance(); _ = try expectIdentifier()
                if consumeSymbol(":") { try skipType() }
                if consumeSymbol("=") { try skipType() }
                if consumeIdentifier("where") { try skipWhereConstraints(requiresBody: false) }
            default:
                throw error("Unsupported protocol requirement\(describeCurrent)")
            }
        }
    }

    private mutating func parseFunction(isStatic: Bool, isMutating: Bool) throws -> SwiftAppFunction {
        let signature = try parseFunctionSignature(requiresBody: true)
        let body = try parseBlock()
        return SwiftAppFunction(name: signature.name, parameters: signature.parameters, body: body, isMutating: isMutating, isStatic: isStatic)
    }

    private mutating func parseFunctionSignature(requiresBody: Bool, initializer: Bool = false) throws -> (name: String, parameters: [SwiftAppParameter]) {
        advance() // func or init
        let name = initializer ? "init" : try expectIdentifier()
        if current.isSymbol("<") { try parseGenericParameterClause() }
        try expectSymbol("(")
        var parameters: [SwiftAppParameter] = []
        while !consumeSymbol(")") {
            var first: String?
            if consumeSymbol("_") { first = "_" } else { first = try expectIdentifier() }
            var second: String?
            if let identifier = current.identifier { second = identifier; advance() }
            try expectSymbol(":")
            _ = try parseAttributes()
            try skipType()
            var defaultValue: SwiftAppExpr?
            if consumeSymbol("=") { defaultValue = try parseExpression() }
            let label = first == "_" ? nil : first
            parameters.append(SwiftAppParameter(label: label, name: second ?? first ?? "_", defaultValue: defaultValue))
            if !consumeSymbol(",") { try expectSymbol(")"); break }
        }
        while let word = current.identifier, ["throws", "async", "rethrows"].contains(word) {
            if word == "async" { try recordUnsupported("async functions are not supported", line: current.line) }
            if initializer && word != "async" { try recordUnsupported("Throwing initializers are not supported", line: current.line) }
            advance()
        }
        if consumeSymbol("->") { try skipType() }
        if consumeIdentifier("where") { try skipWhereConstraints(requiresBody: requiresBody) }
        return (name, parameters)
    }

    // MARK: Statements

    private mutating func parseBlock() throws -> [SwiftAppStmt] {
        try expectSymbol("{")
        return try parseBlockBody()
    }

    /// Statements up to and including the closing brace of an opened block.
    private mutating func parseBlockBody() throws -> [SwiftAppStmt] {
        try nest()
        defer { nesting -= 1 }
        let saved = forbidTrailingClosure
        forbidTrailingClosure = false
        defer { forbidTrailingClosure = saved }
        var statements: [SwiftAppStmt] = []
        while !consumeSymbol("}") {
            if atEnd { throw error("Unterminated block") }
            if consumeSymbol(";") { continue }
            statements.append(try parseStatement())
        }
        return statements
    }

    private mutating func parseConditions() throws -> [SwiftAppCondition] {
        let saved = forbidTrailingClosure
        forbidTrailingClosure = true
        defer { forbidTrailingClosure = saved }
        var conditions: [SwiftAppCondition] = []
        repeat {
            if current.isIdentifier("let") || current.isIdentifier("var") {
                advance()
                let name = try expectIdentifier()
                if consumeSymbol(":") { try skipType() }
                if consumeSymbol("=") {
                    conditions.append(.optionalBinding(name, try parseExpression()))
                } else {
                    conditions.append(.optionalBinding(name, .identifier(name, line: current.line)))
                }
            } else {
                conditions.append(.expression(try parseExpression()))
            }
        } while consumeSymbol(",")
        return conditions
    }

    private mutating func parseStatement() throws -> SwiftAppStmt {
        let line = current.line
        _ = try parseAttributes()
        guard let word = current.identifier else { return try parseExpressionStatement(line: line) }
        switch word {
        case "let", "var":
            advance()
            if consumeSymbol("_") {
                try expectSymbol("=")
                return .expression(try parseExpression(), line: line)
            }
            let name = try expectIdentifier()
            if consumeSymbol(":") { try skipType() }
            return .declaration(name, consumeSymbol("=") ? try parseExpression() : nil)
        case "if":
            var branches: [(conditions: [SwiftAppCondition], body: [SwiftAppStmt])] = []
            var otherwise: [SwiftAppStmt]?
            advance()
            branches.append((try parseConditions(), try parseBlock()))
            while consumeIdentifier("else") {
                if consumeIdentifier("if") {
                    branches.append((try parseConditions(), try parseBlock()))
                } else {
                    otherwise = try parseBlock()
                    break
                }
            }
            return .conditional(branches, otherwise: otherwise)
        case "guard":
            advance()
            let conditions = try parseConditions()
            guard consumeIdentifier("else") else { throw error("Expected 'else' after guard") }
            return .guardStatement(conditions, try parseBlock())
        case "for":
            advance()
            var name = "_"
            var tupleNames: [String]?
            if !consumeSymbol("_") {
                if consumeSymbol("(") {
                    var names: [String] = []
                    repeat { names.append(consumeSymbol("_") ? "_" : try expectIdentifier()) } while consumeSymbol(",")
                    try expectSymbol(")")
                    tupleNames = names
                } else { name = try expectIdentifier() }
            }
            guard consumeIdentifier("in") else { throw error("Expected 'in'") }
            let saved = forbidTrailingClosure
            forbidTrailingClosure = true
            let sequence = try parseExpression()
            let filter = consumeIdentifier("where") ? try parseExpression() : nil
            forbidTrailingClosure = saved
            return .forIn(name, tupleNames, sequence, filter: filter, try parseBlock())
        case "while":
            advance()
            return .whileLoop(try parseConditions(), try parseBlock())
        case "switch":
            advance()
            let saved = forbidTrailingClosure
            forbidTrailingClosure = true
            let subject = try parseExpression()
            forbidTrailingClosure = saved
            try expectSymbol("{")
            var cases: [SwiftAppSwitchCase] = []
            while !consumeSymbol("}") {
                var patterns: [SwiftAppPattern]?
                if consumeIdentifier("default") {
                    patterns = nil
                } else {
                    guard consumeIdentifier("case") else { throw error("Expected 'case' in switch") }
                    var list: [SwiftAppPattern] = []
                    repeat { list.append(try parseSwitchPattern()) } while consumeSymbol(",")
                    patterns = list
                }
                try expectSymbol(":")
                var body: [SwiftAppStmt] = []
                while !current.isIdentifier("case"), !current.isIdentifier("default"), !current.isSymbol("}") {
                    if atEnd { throw error("Unterminated switch") }
                    if consumeSymbol(";") { continue }
                    body.append(try parseStatement())
                }
                cases.append(SwiftAppSwitchCase(patterns: patterns, body: body))
            }
            return .switchStatement(subject, cases)
        case "return":
            advance()
            if current.isSymbol("}") || current.newlineBefore || current.isSymbol(";") { return .returnStatement(nil) }
            return .returnStatement(try parseExpression())
        case "break": advance(); return .breakStatement
        case "continue": advance(); return .continueStatement
        default:
            return try parseExpressionStatement(line: line)
        }
    }

    private mutating func parseSwitchPattern(bindings: Bool = false) throws -> SwiftAppPattern {
        try nest()
        defer { nesting -= 1 }
        let binds = consumeIdentifier("let") || consumeIdentifier("var") || bindings
        if consumeSymbol("_") { return .wildcard }
        let start = position
        var typeName: String?
        var caseName: String?
        if consumeSymbol(".") { caseName = try expectIdentifier() }
        else if current.identifier != nil, peek(1).isSymbol(".") {
            typeName = try expectIdentifier(); advance(); caseName = try expectIdentifier()
        } else if binds, current.identifier != nil { return .binding(try expectIdentifier()) }
        guard let caseName else { return .value(try parseExpression()) }
        var arguments: [SwiftAppPatternArgument]?
        if consumeSymbol("(") {
            arguments = []
            if !consumeSymbol(")") {
                repeat {
                    var label: String?
                    if current.identifier != nil, peek(1).isSymbol(":") {
                        label = try expectIdentifier(); advance()
                    }
                    arguments?.append(SwiftAppPatternArgument(label: label, pattern: try parseSwitchPattern(bindings: binds)))
                } while consumeSymbol(",")
                try expectSymbol(")")
            }
        }
        let pattern = SwiftAppPattern.enumeration(typeName, caseName, arguments)
        // `case self.target:` or `case Limits.max:` is a value. Only a qualified
        // case that binds or ignores a payload needs pattern semantics.
        if typeName != nil, !binds, !pattern.bindsOrIgnores {
            position = start
            return .value(try parseExpression())
        }
        return pattern
    }

    private mutating func parseExpressionStatement(line: Int) throws -> SwiftAppStmt {
        let expression = try parseExpression()
        if let op = current.symbol, ["=", "+=", "-=", "*=", "/="].contains(op) {
            advance()
            return .assignment(expression, op, try parseExpression(), line: line)
        }
        return .expression(expression, line: line)
    }

    // MARK: Expressions

    mutating func parseExpression() throws -> SwiftAppExpr {
        try nest()
        defer { nesting -= 1 }
        while let word = current.identifier, ["try", "await"].contains(word) {
            if word == "await" { try recordUnsupported("await is not supported", line: current.line) }
            advance()
            if current.isSymbol("?") || current.isSymbol("!") { advance() }
        }
        let condition = try parseNilCoalescing()
        if current.isSymbol("?"), current.spaceBefore {
            advance()
            let whenTrue = try parseExpression()
            try expectSymbol(":")
            return .ternary(condition, whenTrue, try parseExpression())
        }
        return condition
    }

    private mutating func parseNilCoalescing() throws -> SwiftAppExpr {
        var left = try parseBinary(level: 0)
        var chained = 0
        defer { nesting -= chained }
        while consumeSymbol("??") {
            try nest(); chained += 1
            left = .binary("??", left, try parseBinary(level: 0))
        }
        return left
    }

    private static let precedence: [[String]] = [
        ["||"], ["&&"], ["==", "!=", "<", ">", "<=", ">="], ["..<", "..."], ["+", "-"], ["*", "/", "%"],
    ]

    private mutating func parseBinary(level: Int) throws -> SwiftAppExpr {
        guard level < Self.precedence.count else { return try parseUnary() }
        var left = try parseBinary(level: level + 1)
        var chained = 0
        defer { nesting -= chained }
        while let op = current.symbol, Self.precedence[level].contains(op), !(op == "<" && !current.spaceBefore) {
            // Each operator in a chain deepens the left-nested tree.
            try nest(); chained += 1
            advance()
            left = .binary(op, left, try parseBinary(level: level + 1))
        }
        if level == 2, current.isIdentifier("is") {
            try recordUnsupported("'is' checks are not supported", line: current.line)
            advance()
            try skipType()
        }
        return left
    }

    private mutating func parseUnary() throws -> SwiftAppExpr {
        if let op = current.symbol, ["!", "-", "+"].contains(op) {
            try nest()
            defer { nesting -= 1 }
            advance()
            return .unary(op, try parseUnary())
        }
        return try parsePostfix(try parsePrimary())
    }

    private mutating func parsePostfix(_ base: SwiftAppExpr) throws -> SwiftAppExpr {
        var expression = base
        var optionalChain = false
        var chained = 0
        defer { nesting -= chained }
        while true {
            // Each member, call or subscript wraps the expression once more.
            try nest(); chained += 1
            if case .identifier(let name, _) = expression,
               current.isSymbol("<"), !current.spaceBefore,
               (name.first?.isUppercase == true || peek(1).identifier?.first?.isUppercase == true) {
                let start = position
                if (try? parseGenericArgumentClause()) != nil, current.isSymbol("("), !current.newlineBefore {
                    continue
                }
                position = start
                return expression
            } else if current.isSymbol("."), let name = peek(1).identifier {
                advance(); advance()
                expression = .member(expression, name)
            } else if current.isSymbol("."), case .integer(let index) = peek(1).kind {
                advance(); advance()
                expression = .member(expression, String(index))
            } else if current.isSymbol("("), !current.newlineBefore {
                let line = current.line
                advance()
                var arguments = try parseArgumentList(closing: ")")
                arguments += try parseTrailingClosures()
                expression = .call(expression, arguments, line: line)
            } else if current.isSymbol("["), !current.newlineBefore, !current.spaceBefore {
                advance()
                let index = try parseExpression()
                var fallback: SwiftAppExpr?
                if consumeSymbol(",") {
                    guard consumeIdentifier("default") else { throw error("Expected default: in subscript") }
                    try expectSymbol(":")
                    fallback = try parseExpression()
                }
                try expectSymbol("]")
                expression = .subscripted(expression, index, defaultValue: fallback)
            } else if current.isSymbol("{"), !forbidTrailingClosure, isCallable(expression) {
                let line = current.line
                expression = .call(expression, try parseTrailingClosures(), line: line)
            } else if current.isSymbol("?"), !current.spaceBefore,
                      peek(1).isSymbol(".") || peek(1).isSymbol("[") || peek(1).isSymbol("(") || peek(1).isSymbol("{") {
                advance()
                optionalChain = true
                expression = .optional(expression)
            } else if current.isSymbol("!"), !current.spaceBefore {
                advance()
                expression = .force(expression)
            } else {
                return optionalChain ? .chain(expression) : expression
            }
        }
    }

    private func isCallable(_ expression: SwiftAppExpr) -> Bool {
        switch expression {
        case .identifier, .member, .implicitMember, .call, .selfMember, .optional, .force: true
        default: false
        }
    }

    private mutating func parseTrailingClosures() throws -> [SwiftAppArgument] {
        guard current.isSymbol("{"), !forbidTrailingClosure else { return [] }
        var arguments = [SwiftAppArgument(label: nil, value: .closure(try parseClosure()))]
        while let label = current.identifier, peek(1).isSymbol(":"), peek(2).isSymbol("{") {
            advance(); advance()
            arguments.append(SwiftAppArgument(label: label, value: .closure(try parseClosure())))
        }
        return arguments
    }

    private mutating func parseArgumentList(closing: String) throws -> [SwiftAppArgument] {
        let saved = forbidTrailingClosure
        forbidTrailingClosure = false
        defer { forbidTrailingClosure = saved }
        var arguments: [SwiftAppArgument] = []
        while !consumeSymbol(closing) {
            arguments.append(try parseArgument())
            if !consumeSymbol(",") {
                try expectSymbol(closing)
                break
            }
        }
        return arguments
    }

    private mutating func parseArgument() throws -> SwiftAppArgument {
        if let label = current.identifier, peek(1).isSymbol(":") {
            advance(); advance()
            return SwiftAppArgument(label: label, value: try parseExpression())
        }
        if let op = current.symbol, ["+", "-", "*", "/", "<", ">", "&&", "||"].contains(op),
           peek(1).isSymbol(",") || peek(1).isSymbol(")") {
            advance()
            return SwiftAppArgument(label: nil, value: .operatorReference(op))
        }
        return SwiftAppArgument(label: nil, value: try parseExpression())
    }

    private mutating func parseClosure() throws -> SwiftAppClosureLiteral {
        try expectSymbol("{")
        let start = position
        var parameters: [String] = []
        var hasSignature = false
        if current.isSymbol("[") {
            // Capture lists only matter for reference cycles, which this runtime does not have.
            try? skipBalanced(open: "[", close: "]")
        }
        if current.isIdentifier("in") {
            advance()
            return SwiftAppClosureLiteral(parameters: [], body: try parseBlockBody())
        }
        if current.isSymbol("(") {
            let open = position
            if (try? skipBalanced(open: "(", close: ")")) != nil {
                let close = position - 1
                if current.isSymbol("->") { advance(); _ = try? skipType() }
                if current.isIdentifier("in") {
                    let end = position
                    var expectName = true
                    var depth = 0
                    for token in tokens[(open + 1)..<close] {
                        if token.isSymbol("(") || token.isSymbol("[") || token.isSymbol("<") { depth += 1 }
                        if token.isSymbol(")") || token.isSymbol("]") || token.isSymbol(">") { depth -= 1 }
                        if depth == 0, token.isSymbol(",") { expectName = true; continue }
                        if expectName, let name = token.identifier ?? (token.isSymbol("_") ? "_" : nil) {
                            parameters.append(name)
                            expectName = false
                        }
                    }
                    position = end + 1
                    hasSignature = true
                }
            }
            if !hasSignature { position = open }
        } else {
            var names: [String] = []
            var probe = position
            while true {
                let token = tokens[probe]
                if let name = token.identifier, name != "in" { names.append(name) }
                else if token.isSymbol("_") { names.append("_") }
                else { break }
                probe += 1
                if tokens[probe].isSymbol(",") { probe += 1; continue }
                if tokens[probe].isIdentifier("in") {
                    parameters = names
                    position = probe + 1
                    hasSignature = true
                }
                break
            }
        }
        if !hasSignature { position = start }
        return SwiftAppClosureLiteral(parameters: parameters, body: try parseBlockBody())
    }

    private mutating func parsePrimary() throws -> SwiftAppExpr {
        let token = current
        switch token.kind {
        case .integer(let value): advance(); return .integer(value)
        case .double(let value): advance(); return .double(value)
        case .string(let parts):
            advance()
            return .string(try parts.map { part in
                switch part {
                case .text(let text): .text(text)
                case .interpolation(let raw, let line): .value(try Self.parseArguments(raw, line: line, nesting: nesting))
                }
            })
        case .identifier(let name):
            advance()
            switch name {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "nil": return .nilLiteral
            case "self":
                if current.isSymbol("."), let member = peek(1).identifier {
                    advance(); advance()
                    return .selfMember(member)
                }
                return .selfValue
            default:
                if name.hasPrefix("$"), name.count > 1, !(name.dropFirst().first?.isNumber ?? false) {
                    return .binding(String(name.dropFirst()))
                }
                return .identifier(name, line: token.line)
            }
        case .symbol(let symbol):
            switch symbol {
            case ".":
                advance()
                return .implicitMember(try expectIdentifier())
            case "(":
                advance()
                let elements = try parseArgumentList(closing: ")")
                if elements.count == 1, elements[0].label == nil { return elements[0].value }
                return .tuple(elements)
            case "[":
                advance()
                if consumeSymbol(":") { try expectSymbol("]"); return .dictionary([]) }
                var elements: [SwiftAppExpr] = []
                var entries: [(SwiftAppExpr, SwiftAppExpr)] = []
                var dictionary = false
                while !consumeSymbol("]") {
                    let key = try parseExpression()
                    if consumeSymbol(":") {
                        dictionary = true
                        entries.append((key, try parseExpression()))
                    } else {
                        elements.append(key)
                    }
                    if !consumeSymbol(",") { try expectSymbol("]"); break }
                }
                guard !dictionary || elements.isEmpty else { throw error("Cannot mix array elements and dictionary entries") }
                return dictionary ? .dictionary(entries) : .array(elements)
            case "{":
                return .closure(try parseClosure())
            case "\\":
                advance()
                var path: [String] = []
                if let root = current.identifier, root.first?.isUppercase == true { advance(); _ = root }
                while consumeSymbol(".") { path.append(try expectIdentifier()) }
                return .keyPath(path)
            default:
                throw error("Unexpected '\(symbol)'")
            }
        case .end:
            throw error("Unexpected end of file")
        }
    }
}
