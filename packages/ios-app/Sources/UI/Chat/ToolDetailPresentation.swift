import Foundation

enum ToolDetailKind: String, Sendable {
    case read, write, edit, bash, grep, find, list, generic
}

private struct BoundedCircularBuffer<Element> {
    private var storage: [Element?]
    private var nextReplacementIndex = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        if count < storage.count {
            storage[count] = element
            count += 1
            return
        }
        storage[nextReplacementIndex] = element
        nextReplacementIndex = (nextReplacementIndex + 1) % storage.count
    }

    var orderedElements: [Element] {
        guard count == storage.count else { return storage.prefix(count).compactMap { $0 } }
        return (0..<count).compactMap { offset in
            storage[(nextReplacementIndex + offset) % storage.count]
        }
    }
}

enum ToolDetailDisplayDensity: Hashable, Sendable {
    case glance
    case expanded
}

struct ToolDetailMetadata: Hashable, Sendable, Identifiable {
    let label: String
    let value: String
    let chipText: String
    let icon: String
    let preview: ToolTextPreview
    let chipPreview: ToolTextPreview

    init(label: String, value: String, chipText: String? = nil, icon: String = "info.circle") {
        self.label = label
        self.value = value
        self.chipText = chipText ?? "\(label) \(value)"
        self.icon = icon
        preview = ToolTextPreview.make(value)
        chipPreview = ToolTextPreview.make(self.chipText)
    }

    var id: String { "\(label):\(value)" }

    var accessibilityLabel: String {
        let maximumCharacters = 120
        let source = chipPreview.text.replacingOccurrences(of: "\n", with: " ")
        let isShortened = chipPreview.isBounded || source.count > maximumCharacters
        let concise = source.count > maximumCharacters
            ? String(source.prefix(maximumCharacters)).trimmingCharacters(in: .whitespaces) + "…"
            : source
        let base = "\(label), \(concise)"
        return isShortened
            ? base + ". Preview shortened; complete value in Technical details."
            : base
    }
}

struct ToolStatusChipPresentation: Hashable, Sendable {
    let text: String
    let icon: String

    static func make(tool: ChatToolPresentation, at date: Date = .now) -> ToolStatusChipPresentation {
        let duration = tool.elapsedMilliseconds(at: date).map(ToolTiming.format(milliseconds:))
        let text = [tool.subtitle, duration].compactMap { $0 }.joined(separator: " · ")
        let icon: String
        if tool.error { icon = "exclamationmark.triangle.fill" }
        else if tool.isRunning { icon = "clock.arrow.circlepath" }
        else { icon = "checkmark.circle.fill" }
        return ToolStatusChipPresentation(text: text, icon: icon)
    }
}

struct ToolPathPresentation: Hashable, Sendable {
    let directory: String?
    let basename: String

    static func make(_ preview: ToolTextPreview) -> ToolPathPresentation {
        guard !preview.isBounded,
              let separator = preview.text.lastIndex(of: "/") else {
            return ToolPathPresentation(directory: nil, basename: preview.text)
        }
        let basenameStart = preview.text.index(after: separator)
        return ToolPathPresentation(
            directory: String(preview.text[...separator]),
            basename: String(preview.text[basenameStart...])
        )
    }
}

struct ToolTextPreview: Hashable, Sendable {
    static let maximumVisibleLines = 24
    static let retainedHeadLines = 16
    static let retainedTailLines = 7
    static let maximumUnomittedLines = retainedHeadLines + retainedTailLines
    static let maximumRenderedCharacters = 5_400
    static let maximumLineCharacters = 220

    let text: String
    let isBounded: Bool
    let totalLineCount: Int
    let renderedLineCount: Int

    static func make(_ source: String) -> ToolTextPreview {
        var head: [String] = []
        var tail = BoundedCircularBuffer<String>(capacity: retainedTailLines)
        var totalLineCount = 0
        var hasCharacterOmission = false

        BoundedLineScanner.scan(source, maximumCharacters: maximumLineCharacters) { line in
            totalLineCount += 1
            hasCharacterOmission = hasCharacterOmission || line.omittedCharacterCount > 0
            if head.count < retainedHeadLines {
                head.append(line.text)
            } else {
                tail.append(line.text)
            }
        }

        let lines: [String]
        if totalLineCount <= maximumUnomittedLines {
            lines = head + tail.orderedElements
        } else {
            let omitted = totalLineCount - head.count - tail.count
            lines = head
                + ["… [\(omitted) lines omitted from preview]"]
                + tail.orderedElements
        }
        let rendered = lines.joined(separator: "\n")
        assert(lines.count <= maximumVisibleLines)
        assert(rendered.count <= maximumRenderedCharacters)
        return ToolTextPreview(
            text: rendered,
            isBounded: totalLineCount > maximumUnomittedLines || hasCharacterOmission,
            totalLineCount: totalLineCount,
            renderedLineCount: lines.count
        )
    }
}

enum ToolDiffLineKind: Hashable, Sendable {
    case context
    case addition
    case removal
    case hunk
    case metadata
    case omitted(Int)
}

enum ToolDiffOmissionScope: Hashable, Sendable {
    case expanded
    case glance
}

enum ToolDiffLineID: Hashable, Sendable {
    case source(index: Int, kind: ToolDiffLineKind, text: String)
    case omission(
        scope: ToolDiffOmissionScope,
        precedingSourceIndex: Int?,
        followingSourceIndex: Int?,
        omittedLineCount: Int
    )
}

struct ToolDiffLine: Hashable, Sendable, Identifiable {
    let id: ToolDiffLineID
    let kind: ToolDiffLineKind
    let text: String
}

struct ToolDiffPresentation: Hashable, Sendable {
    static let maximumVisibleLines = 360
    static let retainedHeadLines = 240
    static let retainedTailLines = 119
    static let maximumRenderedLineCharacters = 360
    static let compactMaximumVisibleLines = 14
    static let compactHeadLines = 8
    static let compactTailLines = 5

    let lines: [ToolDiffLine]
    let compactLines: [ToolDiffLine]
    let sourceLabel: String
    let totalLineCount: Int
    let requestedChangeCount: Int?
    let diffUnitCount: Int?
    let hasChangeContent: Bool

    var showsInline: Bool {
        requestedChangeCount == 1 && diffUnitCount == 1 && hasChangeContent
    }

    var changesTitle: String {
        guard let requestedChangeCount else { return "View changes" }
        return "View \(requestedChangeCount) \(requestedChangeCount == 1 ? "change" : "changes")"
    }

    var changesSubtitle: String {
        guard let diffUnitCount else { return sourceLabel }
        return "\(diffUnitCount) diff \(diffUnitCount == 1 ? "section" : "sections") · \(sourceLabel)"
    }

    func visibleLines(for density: ToolDetailDisplayDensity) -> [ToolDiffLine] {
        density == .glance ? compactLines : lines
    }

    static func make(request: JSONValue?, response: JSONValue?) -> ToolDiffPresentation? {
        let requestedCount = exactRequestedChangeCount(in: request)
        if let patch = authoritativePatch(in: response), !patch.isEmpty {
            var accumulator = DiffAccumulator()
            var classifier = PatchLineClassifier()
            BoundedLineScanner.scan(patch, maximumCharacters: maximumRenderedLineCharacters) { line in
                accumulator.append(classifier.classify(line.text))
            }
            return accumulator.presentation(
                sourceLabel: "Applied diff",
                requestedChangeCount: requestedCount,
                diffUnitCount: classifier.exactDiffUnitCount,
                hasChangeContent: classifier.hasChangeContent
            )
        }

        guard let edits = request?.objectValue?["edits"]?.arrayValue,
              requestedCount != nil else { return nil }
        var accumulator = DiffAccumulator()
        for (index, value) in edits.enumerated() {
            guard let object = value.objectValue,
                  let oldText = object["oldText"]?.stringValue,
                  let newText = object["newText"]?.stringValue else { return nil }
            accumulator.append((.hunk, "Change \(index + 1)"))
            if !oldText.isEmpty {
                BoundedLineScanner.scan(oldText, maximumCharacters: maximumRenderedLineCharacters) { line in
                    accumulator.append((.removal, line.text))
                }
            }
            if !newText.isEmpty {
                BoundedLineScanner.scan(newText, maximumCharacters: maximumRenderedLineCharacters) { line in
                    accumulator.append((.addition, line.text))
                }
            }
        }
        guard !edits.isEmpty else { return nil }
        return accumulator.presentation(
            sourceLabel: "Requested changes",
            requestedChangeCount: requestedCount,
            diffUnitCount: edits.count,
            hasChangeContent: accumulator.hasChangeContent
        )
    }

    private static func exactRequestedChangeCount(in value: JSONValue?) -> Int? {
        guard let edits = value?.objectValue?["edits"]?.arrayValue, !edits.isEmpty else { return nil }
        guard edits.allSatisfy({ edit in
            guard let object = edit.objectValue else { return false }
            return object["oldText"]?.stringValue != nil && object["newText"]?.stringValue != nil
        }) else { return nil }
        return edits.count
    }

    private static func authoritativePatch(in value: JSONValue?) -> String? {
        guard let object = value?.objectValue else { return nil }
        let candidates = [object, object["details"]?.objectValue].compactMap { $0 }
        for candidate in candidates {
            for key in ["patch", "diff"] {
                if let text = candidate[key]?.stringValue { return text }
            }
        }
        return nil
    }

    private struct PatchLineClassifier {
        private var isInsideHunk = false
        private var diffHeaderCount = 0
        private var fileHeaderCount = 0
        private var hunkCount = 0
        private var hasInvalidUnitEvidence = false
        private(set) var hasChangeContent = false

        var exactDiffUnitCount: Int? {
            guard !hasInvalidUnitEvidence else { return nil }
            let count = max(diffHeaderCount, fileHeaderCount, hunkCount)
            return count > 0 ? count : nil
        }

        mutating func classify(_ line: String) -> (ToolDiffLineKind, String) {
            if line.hasPrefix("diff --git ") {
                isInsideHunk = false
                diffHeaderCount += 1
                return (.metadata, line)
            }
            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                isInsideHunk = false
                hasInvalidUnitEvidence = true
                return (.metadata, line)
            }
            if isUnifiedHunkHeader(line) {
                isInsideHunk = true
                hunkCount += 1
                return (.hunk, line)
            }
            if line.hasPrefix("@@") {
                isInsideHunk = false
                hasInvalidUnitEvidence = true
                return (.metadata, line)
            }
            if isUnifiedFileHeader(line) {
                if isInsideHunk {
                    // This may be source content or the start of another file
                    // in a header-light multi-file patch. Preserve its visible
                    // +/- semantics, but never admit the patch inline.
                    hasInvalidUnitEvidence = true
                } else {
                    if line.hasPrefix("+++ ") || line.hasPrefix("+++\t") { fileHeaderCount += 1 }
                    return (.metadata, line)
                }
            }
            if !isInsideHunk, line.hasPrefix("index ") {
                return (.metadata, line)
            }
            if line.hasPrefix("+") {
                if isInsideHunk { hasChangeContent = true }
                return (.addition, String(line.dropFirst()))
            }
            if line.hasPrefix("-") {
                if isInsideHunk { hasChangeContent = true }
                return (.removal, String(line.dropFirst()))
            }
            if line.hasPrefix(" ") { return (.context, String(line.dropFirst())) }
            return (.context, line)
        }

        private func isUnifiedFileHeader(_ line: String) -> Bool {
            line.hasPrefix("+++ ") || line.hasPrefix("+++\t")
                || line.hasPrefix("--- ") || line.hasPrefix("---\t")
        }

        private func isUnifiedHunkHeader(_ line: String) -> Bool {
            guard line.hasPrefix("@@ -"),
                  let delimiter = line.range(of: " @@", range: line.index(line.startIndex, offsetBy: 3)..<line.endIndex) else {
                return false
            }
            let coordinates = line[line.index(line.startIndex, offsetBy: 3)..<delimiter.lowerBound]
                .split(separator: " ", omittingEmptySubsequences: false)
            guard coordinates.count == 2,
                  validRange(coordinates[0], prefix: "-"),
                  validRange(coordinates[1], prefix: "+") else {
                return false
            }
            let suffix = line[delimiter.upperBound...]
            return suffix.isEmpty || suffix.first == " "
        }

        private func validRange(_ value: Substring, prefix: Character) -> Bool {
            guard value.first == prefix else { return false }
            let range = value.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard range.count == 1 || range.count == 2 else { return false }
            return range.allSatisfy { component in
                !component.isEmpty && component.allSatisfy { character in
                    character >= "0" && character <= "9"
                }
            }
        }
    }

    private struct DiffAccumulator {
        private struct SourceLine {
            let sourceIndex: Int
            let kind: ToolDiffLineKind
            let text: String

            var presentation: ToolDiffLine {
                ToolDiffLine(
                    id: .source(index: sourceIndex, kind: kind, text: text),
                    kind: kind,
                    text: text
                )
            }
        }

        private var head: [SourceLine] = []
        private var tail = BoundedCircularBuffer<SourceLine>(
            capacity: ToolDiffPresentation.retainedTailLines
        )
        private var compactHead: [SourceLine] = []
        private var compactTail = BoundedCircularBuffer<SourceLine>(
            capacity: ToolDiffPresentation.compactTailLines
        )
        private var compactSemanticCount = 0
        private(set) var totalCount = 0
        private(set) var hasChangeContent = false

        mutating func append(_ line: (ToolDiffLineKind, String)) {
            let sourceLine = SourceLine(sourceIndex: totalCount, kind: line.0, text: line.1)
            totalCount += 1
            if line.0 == .addition || line.0 == .removal { hasChangeContent = true }
            if case .metadata = line.0 {
                // File headers remain available in the expanded/full diff but
                // do not consume the medium-detent semantic glance budget.
            } else {
                compactSemanticCount += 1
                if compactHead.count < ToolDiffPresentation.compactHeadLines {
                    compactHead.append(sourceLine)
                } else {
                    compactTail.append(sourceLine)
                }
            }
            if head.count < ToolDiffPresentation.retainedHeadLines {
                head.append(sourceLine)
                return
            }
            tail.append(sourceLine)
        }

        func presentation(
            sourceLabel: String,
            requestedChangeCount: Int?,
            diffUnitCount: Int?,
            hasChangeContent: Bool
        ) -> ToolDiffPresentation {
            let orderedTail = tail.orderedElements
            let maximumUnomittedLines = ToolDiffPresentation.retainedHeadLines
                + ToolDiffPresentation.retainedTailLines
            let visible: [ToolDiffLine]
            if totalCount <= maximumUnomittedLines {
                visible = (head + orderedTail).map(\.presentation)
            } else {
                let omitted = totalCount - head.count - tail.count
                visible = head.map(\.presentation)
                    + [omission(
                        scope: .expanded,
                        preceding: head.last,
                        following: orderedTail.first,
                        count: omitted,
                        text: "\(omitted) diff lines omitted from preview"
                    )]
                    + orderedTail.map(\.presentation)
            }
            return ToolDiffPresentation(
                lines: visible,
                compactLines: compactPresentation(),
                sourceLabel: sourceLabel,
                totalLineCount: totalCount,
                requestedChangeCount: requestedChangeCount,
                diffUnitCount: diffUnitCount,
                hasChangeContent: hasChangeContent
            )
        }

        private func compactPresentation() -> [ToolDiffLine] {
            let orderedTail = compactTail.orderedElements
            let maximumUnomitted = ToolDiffPresentation.compactHeadLines
                + ToolDiffPresentation.compactTailLines
            guard compactSemanticCount > maximumUnomitted else {
                return (compactHead + orderedTail).map(\.presentation)
            }
            let omitted = compactSemanticCount - compactHead.count - compactTail.count
            return compactHead.map(\.presentation)
                + [omission(
                    scope: .glance,
                    preceding: compactHead.last,
                    following: orderedTail.first,
                    count: omitted,
                    text: "\(omitted) diff lines omitted from glance"
                )]
                + orderedTail.map(\.presentation)
        }

        private func omission(
            scope: ToolDiffOmissionScope,
            preceding: SourceLine?,
            following: SourceLine?,
            count: Int,
            text: String
        ) -> ToolDiffLine {
            ToolDiffLine(
                id: .omission(
                    scope: scope,
                    precedingSourceIndex: preceding?.sourceIndex,
                    followingSourceIndex: following?.sourceIndex,
                    omittedLineCount: count
                ),
                kind: .omitted(count),
                text: text
            )
        }
    }
}

private struct BoundedLine {
    let text: String
    let sourceCharacterCount: Int
    let omittedCharacterCount: Int
}

private enum BoundedLineScanner {
    static func scan(
        _ source: String,
        maximumCharacters: Int,
        consume: (BoundedLine) -> Void
    ) {
        var retained = ""
        retained.reserveCapacity(maximumCharacters)
        var retainedCharacterCount = 0
        var characterCount = 0

        func emit() {
            let omitted = max(0, characterCount - maximumCharacters)
            if omitted == 0 {
                consume(BoundedLine(
                    text: retained,
                    sourceCharacterCount: characterCount,
                    omittedCharacterCount: 0
                ))
            } else {
                var exactOmitted = omitted
                var marker = ""
                var prefixCount = 0
                while true {
                    marker = " … [\(exactOmitted) characters omitted]"
                    prefixCount = max(0, maximumCharacters - marker.count)
                    let hiddenCharacterCount = characterCount - prefixCount
                    guard hiddenCharacterCount != exactOmitted else { break }
                    exactOmitted = hiddenCharacterCount
                }
                consume(BoundedLine(
                    text: String(retained.prefix(prefixCount)) + marker,
                    sourceCharacterCount: characterCount,
                    omittedCharacterCount: exactOmitted
                ))
            }
        }

        for character in source {
            if character == "\n" {
                emit()
                retained.removeAll(keepingCapacity: true)
                retainedCharacterCount = 0
                characterCount = 0
            } else {
                characterCount += 1
                if retainedCharacterCount < maximumCharacters {
                    retained.append(character)
                    retainedCharacterCount += 1
                }
            }
        }
        emit()
    }
}

struct ToolDetailPresentation: Hashable, Sendable {
    let kind: ToolDetailKind
    let displayTitle: String
    let icon: String
    let sheetTitleIcon: String?
    let primaryLabel: String?
    let primaryValue: String?
    let primaryPreview: ToolTextPreview?
    let primaryPath: ToolPathPresentation?
    let metadata: [ToolDetailMetadata]
    let readableResult: String?
    let readableResultPreview: ToolTextPreview?
    let structuredResult: JSONValue?
    let diff: ToolDiffPresentation?
    let usesCodeResult: Bool

    init(tool: ChatToolPresentation) {
        let request = tool.request?.objectValue
        let rawToolName = tool.toolName ?? tool.title
        kind = Self.kind(for: rawToolName)
        displayTitle = Self.displayTitle(for: tool.title)
        icon = Self.icon(for: rawToolName)
        sheetTitleIcon = Self.sheetTitleIcon(for: rawToolName)
        let primary = Self.primary(kind: kind, request: request)
        primaryLabel = primary?.label
        primaryValue = primary?.value
        primaryPreview = primary.map { ToolTextPreview.make($0.value) }
        if [.read, .write, .edit].contains(kind), let primaryPreview {
            primaryPath = ToolPathPresentation.make(primaryPreview)
        } else {
            primaryPath = nil
        }

        metadata = Self.metadata(kind: kind, request: request)
        diff = kind == .edit ? ToolDiffPresentation.make(request: tool.request, response: tool.response) : nil
        readableResult = Self.readableResult(tool: tool)
        readableResultPreview = readableResult.map(ToolTextPreview.make)
        structuredResult = Self.structuredResult(tool: tool, readableResult: readableResult)
        usesCodeResult = [.read, .write, .edit, .bash, .grep, .find, .list].contains(kind)
    }

    static func kind(for title: String) -> ToolDetailKind {
        switch title {
        case "read": .read
        case "write": .write
        case "edit": .edit
        case "bash": .bash
        case "grep": .grep
        case "find": .find
        case "ls": .list
        default: .generic
        }
    }

    static func primary(
        kind: ToolDetailKind,
        request: [String: JSONValue]?
    ) -> (label: String, value: String)? {
        switch kind {
        case .read, .write, .edit:
            firstString(in: request, keys: ["path", "filePath"]).map { ("File", $0) }
        case .bash:
            firstString(in: request, keys: ["command"]).map { ("Command", $0) }
        case .grep, .find:
            firstString(in: request, keys: ["pattern"]).map { ("Pattern", $0) }
        case .list:
            ("Directory", firstString(in: request, keys: ["path"]) ?? ".")
        case .generic:
            genericPrimary(in: request)
        }
    }

    static func displayTitle(for tool: ChatToolPresentation) -> String {
        displayTitle(for: tool.title)
    }

    static func sheetTitleIcon(for tool: ChatToolPresentation) -> String? {
        sheetTitleIcon(for: tool.toolName ?? tool.title)
    }

    static func displayTitle(for title: String) -> String {
        switch title {
        case "read": "Read file"
        case "write": "Write file"
        case "edit": "Edit file"
        case "bash": "Run command"
        case "grep": "Search text"
        case "find": "Find files"
        case "ls": "List files"
        default: title
        }
    }

    static func icon(for title: String) -> String {
        switch title {
        case "read": "doc.text"
        case "write": "square.and.pencil"
        case "edit": "pencil.and.outline"
        case "bash": "terminal"
        case "grep": "text.magnifyingglass"
        case "find": "doc.text.magnifyingglass"
        case "ls": "folder"
        default: "wrench.and.screwdriver"
        }
    }

    private static func sheetTitleIcon(for toolName: String) -> String? {
        switch kind(for: toolName) {
        case .read, .write, .edit, .bash:
            icon(for: toolName)
        case .grep, .find, .list, .generic:
            nil
        }
    }

    private static func genericPrimary(in object: [String: JSONValue]?) -> (String, String)? {
        let candidates: [(key: String, label: String)] = [
            ("command", "Command"), ("path", "File"), ("filePath", "File"),
            ("query", "Query"), ("url", "URL"), ("task", "Task"),
            ("prompt", "Prompt"), ("message", "Message"), ("id", "ID"), ("name", "Name"),
        ]
        for candidate in candidates {
            guard let value = object?[candidate.key]?.stringValue, !value.isEmpty else { continue }
            return (candidate.label, value)
        }
        return nil
    }

    private static func firstString(in object: [String: JSONValue]?, keys: [String]) -> String? {
        for key in keys {
            guard let value = object?[key]?.stringValue, !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func metadata(
        kind: ToolDetailKind,
        request: [String: JSONValue]?
    ) -> [ToolDetailMetadata] {
        guard let request else { return [] }
        var values: [ToolDetailMetadata] = []
        func append(_ label: String, _ value: String?, chipText: String? = nil, icon: String = "info.circle") {
            guard let value, !value.isEmpty else { return }
            values.append(ToolDetailMetadata(label: label, value: value, chipText: chipText, icon: icon))
        }
        func integer(_ key: String) -> Int? { request[key]?.intValue }
        func pluralized(_ count: Int, singular: String) -> String {
            "\(count) \(singular)\(count == 1 ? "" : "s")"
        }

        switch kind {
        case .read:
            if let offset = integer("offset") {
                append("Starts at line", String(offset), chipText: "From line \(offset)", icon: "text.alignleft")
            }
            if let limit = integer("limit") {
                append("Maximum lines", String(limit), chipText: "Up to \(pluralized(limit, singular: "line"))", icon: "text.alignleft")
            }
        case .write:
            if let content = request["content"]?.stringValue {
                let lineCount = content.reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                append("Lines", String(lineCount), chipText: pluralized(lineCount, singular: "line"), icon: "text.alignleft")
                let size = ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
                append("Size", size, chipText: size, icon: "internaldrive")
            }
        case .edit:
            if let edits = request["edits"]?.arrayValue {
                append("Changes", String(edits.count), chipText: pluralized(edits.count, singular: "change"), icon: "pencil")
            }
        case .bash:
            if let timeout = integer("timeout") {
                append("Timeout", "\(timeout)s", chipText: "\(timeout)s timeout", icon: "timer")
            }
        case .grep:
            let location = firstString(in: request, keys: ["path"]) ?? "."
            append("Location", location, chipText: location, icon: "folder")
            if let glob = firstString(in: request, keys: ["glob"]) {
                append("File filter", glob, chipText: glob, icon: "line.3.horizontal.decrease.circle")
            }
            if request["ignoreCase"]?.boolValue == true {
                append("Ignore case", "Yes", chipText: "Ignore case", icon: "textformat")
            }
            if request["literal"]?.boolValue == true {
                append("Literal", "Yes", chipText: "Literal match", icon: "equal")
            }
            if let context = integer("context") {
                append("Context lines", String(context), chipText: pluralized(context, singular: "context line"), icon: "text.insert")
            }
            if let limit = integer("limit") {
                append("Result limit", String(limit), chipText: "Up to \(pluralized(limit, singular: "result"))", icon: "number")
            }
        case .find:
            let location = firstString(in: request, keys: ["path"]) ?? "."
            append("Location", location, chipText: location, icon: "folder")
            if let limit = integer("limit") {
                append("Result limit", String(limit), chipText: "Up to \(pluralized(limit, singular: "result"))", icon: "number")
            }
        case .list:
            if let limit = integer("limit") {
                append("Result limit", String(limit), chipText: "Up to \(pluralized(limit, singular: "entry"))", icon: "number")
            }
        case .generic:
            break
        }
        return values
    }

    static func readableResult(tool: ChatToolPresentation) -> String? {
        if !tool.content.isEmpty { return tool.content }
        if let value = readableString(in: tool.response) { return value }
        guard let fallback = tool.fallbackContent, fallback != tool.request else { return nil }
        return readableString(in: fallback)
    }

    private static func readableString(in value: JSONValue?) -> String? {
        if let text = value?.stringValue, !text.isEmpty { return text }
        guard let object = value?.objectValue else { return nil }
        return firstString(in: object, keys: ["content", "output", "text", "message", "summary", "answer", "result"])
    }

    static func structuredResult(tool: ChatToolPresentation, readableResult: String?) -> JSONValue? {
        if let response = tool.response {
            if let text = response.stringValue, text == readableResult { return nil }
            return response
        }
        guard let fallback = tool.fallbackContent, fallback != tool.request else { return nil }
        if let text = fallback.stringValue, text == readableResult { return nil }
        return fallback
    }
}

/// A bounded suffix preview for aggregate tool rows. This intentionally keeps
/// only the newest nonempty logical lines: live output is a current display
/// frame, not an append-only log, and the full result remains in the detail view.
struct ToolOutputTailPreview: Hashable, Sendable {
    static let maximumLines = 2
    static let maximumLineCharacters = 180

    let text: String
    let isBounded: Bool
    let renderedLineCount: Int

    static func make(_ source: String) -> ToolOutputTailPreview? {
        guard !source.isEmpty else { return nil }
        var lines: [String] = []
        lines.reserveCapacity(Self.maximumLines)
        var current: [Character] = []
        current.reserveCapacity(Self.maximumLineCharacters)
        var hasNonWhitespace = false
        var lineWasBounded = false
        var boundedOutput = false
        var omittedLines = false

        func finishLine() {
            let rendered = String(current.reversed())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if hasNonWhitespace, !rendered.isEmpty {
                if lines.count < Self.maximumLines {
                    lines.append(rendered)
                    if lineWasBounded { boundedOutput = true }
                } else {
                    omittedLines = true
                }
            }
            // Clear even blank logical lines; otherwise trailing whitespace
            // would leak into the next retained line while walking backwards.
            current.removeAll(keepingCapacity: true)
            hasNonWhitespace = false
            lineWasBounded = false
        }

        // Walk from the suffix so a pathological output frame never requires
        // an unbounded split array. Each retained line is bounded before it is
        // materialized; after the requested lines are complete, stop at the
        // first older non-whitespace character needed to prove omission.
        for character in source.reversed() {
            // Swift represents CRLF as one extended grapheme cluster, so
            // recognize both forms while scanning the suffix.
            if character == "\n" || character == "\r\n" {
                finishLine()
                continue
            }
            if lines.count == Self.maximumLines {
                if !character.isWhitespace {
                    omittedLines = true
                    break
                }
                continue
            }
            if character == "\r", current.isEmpty { continue }
            if !character.isWhitespace { hasNonWhitespace = true }
            if current.count < Self.maximumLineCharacters {
                current.append(character)
            } else if !character.isWhitespace {
                lineWasBounded = true
            }
        }
        if !omittedLines { finishLine() }
        guard !lines.isEmpty else { return nil }

        return ToolOutputTailPreview(
            text: lines.reversed().joined(separator: "\n"),
            isBounded: boundedOutput || omittedLines,
            renderedLineCount: lines.count
        )
    }
}

/// Lightweight aggregate-sheet data. It deliberately extracts only bounded
/// semantic fields and never prepares diffs or full technical JSON.
struct ToolRunRowPresentation: Hashable, Sendable {
    let id: String
    let title: String
    let icon: String
    let status: String
    let isRunning: Bool
    let error: Bool
    let elapsedMilliseconds: Int?
    let primaryLabel: String?
    let primaryPreview: ToolTextPreview?
    let primaryPath: ToolPathPresentation?
    let outputPreview: ToolOutputTailPreview?
    let hasStructuredResult: Bool
    let outputTruncated: Bool

    init(tool: ChatToolPresentation, at date: Date = .now) {
        let rawToolName = tool.toolName ?? tool.title
        let kind = ToolDetailPresentation.kind(for: rawToolName)
        let request = tool.request?.objectValue
        let primary = ToolDetailPresentation.primary(kind: kind, request: request)
        let readableResult = ToolDetailPresentation.readableResult(tool: tool)
        id = tool.id
        title = ToolDetailPresentation.displayTitle(for: tool)
        icon = ToolDetailPresentation.icon(for: rawToolName)
        status = tool.subtitle
        isRunning = tool.isRunning
        error = tool.error
        elapsedMilliseconds = tool.elapsedMilliseconds(at: date)
        primaryLabel = primary?.label
        primaryPreview = primary.map { ToolTextPreview.make($0.value) }
        if [.read, .write, .edit].contains(kind), let primaryPreview {
            primaryPath = ToolPathPresentation.make(primaryPreview)
        } else {
            primaryPath = nil
        }
        outputPreview = readableResult.flatMap { ToolOutputTailPreview.make($0) }
        hasStructuredResult = outputPreview == nil
            && ToolDetailPresentation.structuredResult(
                tool: tool,
                readableResult: readableResult
            ) != nil
        outputTruncated = tool.outputTruncated
    }
}

enum ToolTechnicalResultResolver {
    static func resolve(_ tool: ChatToolPresentation) -> JSONValue {
        if let response = tool.response { return response }
        if !tool.content.isEmpty { return .string(tool.content) }
        if let fallback = tool.fallbackContent, fallback != tool.request { return fallback }
        return .null
    }
}
