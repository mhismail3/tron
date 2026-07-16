import Testing
import Foundation

extension SourceGuardTests {

    @Test("network-attempt ratchet scopes repeated bindings per function")
    func testNetworkAttemptRatchetScopesRepeatedBindingsPerFunction() {
        let safe = """
        @Test func inspectsClientWithoutAttempting() {
            let rpc = EngineClient(serverURL: url)
            _ = rpc.connectionState
        }
        @Test func handlesClientAttempts() async {
            let rpc = EngineClient(
                serverURL: url,
                sessionAttemptDirective: { _ in .handledFailure }
            )
            await rpc.connect()
            await rpc.manualRetry()
            await rpc.reconnect()
        }
        @Test func inspectsConnectionWithoutAttempting() {
            let ws = EngineConnection(serverURL: url)
            _ = ws.makeUpgradeRequest()
        }
        @Test func handlesConnectionAttempts() async {
            let ws = EngineConnection(
                serverURL: url,
                sessionAttemptDirective: { _ in .handledFailure }
            )
            await ws.connect()
            await ws.manualRetry()
        }
        """

        #expect(networkAttemptViolations(in: safe, path: "Tests/SyntheticSafe.swift").isEmpty)
    }

    @Test("network-attempt ratchet rejects an unsafe same-name binding in its function")
    func testNetworkAttemptRatchetRejectsUnsafeSameNameBindingInSeparateFunction() {
        let unsafe = """
        @Test func handledClientAttempt() async {
            let rpc = EngineClient(
                serverURL: url,
                sessionAttemptDirective: { _ in .handledFailure }
            )
            await rpc.connect()
        }
        @Test func unhandledClientAttempt() async {
            let rpc = EngineClient(serverURL: url)
            await rpc.connect()
        }
        """

        let violations = networkAttemptViolations(
            in: unsafe,
            path: "Tests/SyntheticViolation.swift"
        )
        #expect(
            violations.contains(where: {
                $0.contains("EngineClient connect missing handled session-attempt directive")
            })
        )
    }

    func networkAttemptViolations(in source: String, path: String) -> [String] {
        networkAttemptSegments(in: source).flatMap {
            networkAttemptViolations(inSegment: $0, path: path)
        }
    }

    private func networkAttemptSegments(in source: String) -> [String] {
        let codeMask = networkSourceCodeMask(source)
        let scopes = networkFunctionScopes(in: codeMask)
        guard !scopes.isEmpty else { return [source] }

        var segments: [String] = []
        var cursor = 0
        for scope in scopes {
            if cursor < scope.location {
                segments.append(networkSourceSlice(source, range: NSRange(
                    location: cursor,
                    length: scope.location - cursor
                )))
            }
            segments.append(networkSourceSlice(source, range: scope))
            cursor = NSMaxRange(scope)
        }
        let sourceLength = (source as NSString).length
        if cursor < sourceLength {
            segments.append(networkSourceSlice(source, range: NSRange(
                location: cursor,
                length: sourceLength - cursor
            )))
        }
        return segments
    }

    private func networkFunctionScopes(in codeMask: String) -> [NSRange] {
        let pattern = #"(?m)^[\t ]*(?:@[^\n]*[\t ]+)?(?:(?:public|internal|fileprivate|private|open|final|static|class|mutating|nonmutating|convenience|required|override|nonisolated|isolated|distributed|borrowing|consuming)[\t ]+)*(?:func\b|init[!?]?[\t ]*\()"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = codeMask as NSString
        let units = Array(codeMask.utf16)
        let declarations = expression.matches(
            in: codeMask,
            range: NSRange(location: 0, length: source.length)
        )

        var scopes: [NSRange] = []
        for (index, declaration) in declarations.enumerated() {
            let nextDeclaration = index + 1 < declarations.count
                ? declarations[index + 1].range.location
                : units.count
            var open = NSMaxRange(declaration.range)
            while open < nextDeclaration, units[open] != 123 { open += 1 }
            guard open < nextDeclaration else { continue }

            var depth = 0
            var close = open
            while close < units.count {
                if units[close] == 123 { depth += 1 }
                if units[close] == 125 { depth -= 1 }
                close += 1
                if depth == 0 { break }
            }
            guard depth == 0 else { continue }
            scopes.append(NSRange(
                location: declaration.range.location,
                length: close - declaration.range.location
            ))
        }

        var outermost: [NSRange] = []
        for scope in scopes.sorted(by: { $0.location < $1.location }) {
            let isNested = outermost.contains {
                $0.location <= scope.location && NSMaxRange(scope) <= NSMaxRange($0)
            }
            if !isNested { outermost.append(scope) }
        }
        return outermost
    }

    private func networkSourceSlice(_ source: String, range: NSRange) -> String {
        let start = String.Index(utf16Offset: range.location, in: source)
        let end = String.Index(utf16Offset: NSMaxRange(range), in: source)
        return String(source[start..<end])
    }

    private enum NetworkSourceLexicalState {
        case code
        case lineComment
        case blockComment
        case string
    }

    private func networkSourceCodeMask(_ source: String) -> String {
        let units = Array(source.utf16)
        var mask = units
        var state = NetworkSourceLexicalState.code
        var blockDepth = 0
        var stringHashCount = 0
        var stringIsMultiline = false
        var index = 0

        func blank(_ position: Int) {
            if units[position] != 10, units[position] != 13 {
                mask[position] = 32
            }
        }

        func blank(_ range: Range<Int>) {
            for position in range { blank(position) }
        }

        while index < units.count {
            switch state {
            case .code:
                if index + 1 < units.count, units[index] == 47, units[index + 1] == 47 {
                    blank(index..<(index + 2))
                    index += 2
                    state = .lineComment
                    continue
                }
                if index + 1 < units.count, units[index] == 47, units[index + 1] == 42 {
                    blank(index..<(index + 2))
                    index += 2
                    blockDepth = 1
                    state = .blockComment
                    continue
                }

                var quote = index
                while quote < units.count, units[quote] == 35 { quote += 1 }
                if quote < units.count, units[quote] == 34 {
                    stringHashCount = quote - index
                    stringIsMultiline = quote + 2 < units.count
                        && units[quote + 1] == 34
                        && units[quote + 2] == 34
                    let delimiterEnd = quote + (stringIsMultiline ? 3 : 1)
                    blank(index..<delimiterEnd)
                    index = delimiterEnd
                    state = .string
                    continue
                }
                index += 1

            case .lineComment:
                blank(index)
                if units[index] == 10 || units[index] == 13 {
                    state = .code
                }
                index += 1

            case .blockComment:
                if index + 1 < units.count, units[index] == 47, units[index + 1] == 42 {
                    blank(index..<(index + 2))
                    index += 2
                    blockDepth += 1
                    continue
                }
                if index + 1 < units.count, units[index] == 42, units[index + 1] == 47 {
                    blank(index..<(index + 2))
                    index += 2
                    blockDepth -= 1
                    if blockDepth == 0 { state = .code }
                    continue
                }
                blank(index)
                index += 1

            case .string:
                let quoteWidth = stringIsMultiline ? 3 : 1
                let quoteEnd = index + quoteWidth
                let delimiterEnd = quoteEnd + stringHashCount
                let hasQuotes = quoteEnd <= units.count
                    && units[index..<quoteEnd].allSatisfy { $0 == 34 }
                let hasHashes = delimiterEnd <= units.count
                    && units[quoteEnd..<delimiterEnd].allSatisfy { $0 == 35 }
                var backslashCount = 0
                var previous = index
                while previous > 0, units[previous - 1] == 92 {
                    previous -= 1
                    backslashCount += 1
                }
                let isEscaped = stringHashCount == 0 && backslashCount.isMultiple(of: 2) == false
                if hasQuotes, hasHashes, !isEscaped {
                    blank(index..<delimiterEnd)
                    index = delimiterEnd
                    state = .code
                    continue
                }
                blank(index)
                index += 1
            }
        }
        return String(decoding: mask, as: UTF16.self)
    }

    private func networkAttemptViolations(inSegment source: String, path: String) -> [String] {
        var safe = Set<String>()
        var unsafe = Set<String>()
        var connectionNames = Set<String>()
        var clientNames = Set<String>()
        var containerNames = Set<String>()
        var repositoryNames = Set<String>()

        for call in boundCalls(named: "EngineConnection", in: source) {
            connectionNames.insert(call.binding)
            if call.arguments.contains("sessionAttemptDirective:") {
                safe.insert(call.binding)
            } else {
                unsafe.insert(call.binding)
            }
        }
        for call in boundCalls(named: "EngineClient", in: source) {
            clientNames.insert(call.binding)
            if call.arguments.contains("sessionAttemptDirective:") {
                safe.insert(call.binding)
            } else {
                unsafe.insert(call.binding)
            }
        }
        for call in boundCalls(named: "DependencyContainer", in: source) {
            containerNames.insert(call.binding)
            unsafe.insert(call.binding)
        }
        for line in source.split(separator: "\n").map(String.init) {
            guard let binding = assignmentBinding(in: line) else { continue }
            if line.contains(".makeContainer(") {
                containerNames.insert(binding)
                safe.insert(binding)
            }
            if line.contains("DefaultAppConnectionRepository(") {
                repositoryNames.insert(binding)
                if let client = labeledIdentifier("client", in: line) {
                    if safe.contains(client) { safe.insert(binding) }
                    if unsafe.contains(client) { unsafe.insert(binding) }
                }
            }
            if let sourceName = simpleAssignedIdentifier(in: line) {
                if safe.contains(sourceName) { safe.insert(binding) }
                if unsafe.contains(sourceName) { unsafe.insert(binding) }
                if clientNames.contains(sourceName) { clientNames.insert(binding) }
                if connectionNames.contains(sourceName) { connectionNames.insert(binding) }
                if containerNames.contains(sourceName) { containerNames.insert(binding) }
                if repositoryNames.contains(sourceName) { repositoryNames.insert(binding) }
            }
        }

        var violations: [String] = []
        for call in memberCalls(in: source) {
            let root = call.receiver.split(separator: ".").first.map(String.init) ?? call.receiver
            guard unsafe.contains(root) else { continue }
            switch call.method {
            case "connect":
                if repositoryNames.contains(root) {
                    violations.append("\(path): repository attempt derives from live EngineClient")
                } else if containerNames.contains(root) {
                    violations.append("\(path): container connect derives from direct composition")
                } else if clientNames.contains(root) {
                    violations.append("\(path): EngineClient connect missing handled session-attempt directive")
                } else if connectionNames.contains(root) {
                    violations.append("\(path): EngineConnection connect missing session-attempt directive")
                }
            case "manualRetry":
                if containerNames.contains(root) {
                    violations.append("\(path): container retry derives from direct composition")
                } else if clientNames.contains(root) {
                    violations.append("\(path): EngineClient retry missing handled session-attempt directive")
                } else if connectionNames.contains(root) {
                    violations.append("\(path): EngineConnection retry missing session-attempt directive")
                }
            case "reconnect":
                if clientNames.contains(root) {
                    violations.append("\(path): EngineClient reconnect missing handled session-attempt directive")
                }
            case "selectPairedServer":
                if containerNames.contains(root), !call.arguments.contains("connectAfterSwitch: false") {
                    violations.append("\(path): server switch can connect from direct composition")
                }
            case "forgetPairedServer":
                if containerNames.contains(root) {
                    violations.append("\(path): forget can reconnect from direct composition")
                }
            default:
                break
            }
        }
        return violations
    }

    private func boundCalls(named name: String, in source: String) -> [(binding: String, arguments: String)] {
        let token = "\(name)("
        var result: [(String, String)] = []
        var searchStart = source.startIndex
        while let call = source.range(of: token, range: searchStart..<source.endIndex) {
            let lineStart = source[..<call.lowerBound].lastIndex(of: "\n")
                .map { source.index(after: $0) } ?? source.startIndex
            let prefix = String(source[lineStart..<call.lowerBound])
            guard let binding = firstCapture(
                #"(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)[^=]*=\s*$"#,
                in: prefix
            ) else {
                searchStart = call.upperBound
                continue
            }
            let open = source.index(before: call.upperBound)
            var cursor = source.index(after: open)
            var depth = 1
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" { depth -= 1 }
                if depth == 0 {
                    result.append((binding, String(source[source.index(after: open)..<cursor])))
                    searchStart = source.index(after: cursor)
                    break
                }
                cursor = source.index(after: cursor)
            }
            if depth > 0 { break }
        }
        return result
    }

    private func assignmentBinding(in line: String) -> String? {
        firstCapture(#"^\s*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)[^=]*="#, in: line)
    }

    private func simpleAssignedIdentifier(in line: String) -> String? {
        firstCapture(#"=\s*([A-Za-z_][A-Za-z0-9_]*)\s*$"#, in: line)
    }

    private func labeledIdentifier(_ label: String, in source: String) -> String? {
        firstCapture("\\b\(label)\\s*:\\s*([A-Za-z_][A-Za-z0-9_]*)", in: source)
    }

    private func memberCalls(in source: String) -> [(receiver: String, method: String, arguments: String)] {
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*\.\s*(connect|manualRetry|reconnect|selectPairedServer|forgetPairedServer)\s*\("#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        var result: [(String, String, String)] = []
        for match in expression.matches(
            in: source,
            range: NSRange(location: 0, length: nsSource.length)
        ) {
            guard match.numberOfRanges == 3,
                  let whole = Range(match.range(at: 0), in: source),
                  let receiverRange = Range(match.range(at: 1), in: source),
                  let methodRange = Range(match.range(at: 2), in: source)
            else { continue }
            let open = source.index(before: whole.upperBound)
            var cursor = source.index(after: open)
            var depth = 1
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "(" { depth += 1 }
                if source[cursor] == ")" { depth -= 1 }
                if depth == 0 {
                    let receiver = source[receiverRange].filter { !$0.isWhitespace }
                    result.append((
                        String(receiver),
                        String(source[methodRange]),
                        String(source[source.index(after: open)..<cursor])
                    ))
                    break
                }
                cursor = source.index(after: cursor)
            }
        }
        return result
    }

    private func firstCapture(_ pattern: String, in source: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: source,
                range: NSRange(location: 0, length: (source as NSString).length)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        return String(source[range])
    }
}
