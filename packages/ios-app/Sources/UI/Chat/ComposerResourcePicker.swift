import Foundation
import SwiftUI

struct ComposerResourceEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case skill, command, prompt }

    let id: String
    let kind: Kind
    let invocationName: String
    let displayName: String
    let friendlyName: String
    let description: String?
    let argumentHint: String?
    let source: CommandInfo.Source
    let sourcePath: String?
    let resourceSource: String?
    let resourceScope: CommandInfo.ResourceScope?
    let resourceOrigin: CommandInfo.ResourceOrigin?
    fileprivate let normalizedName: String
    fileprivate let normalizedSearch: String

    init?(command: CommandInfo) {
        let kind: Kind
        let displayName: String
        switch command.source {
        case .skill:
            guard command.name.hasPrefix("skill:"), command.name.count > "skill:".count else { return nil }
            kind = .skill
            displayName = String(command.name.dropFirst("skill:".count))
        case .extension:
            kind = .command
            displayName = command.name
        case .prompt:
            kind = .prompt
            displayName = command.name
        }
        guard !displayName.isEmpty else { return nil }
        self.id = command.id
        self.kind = kind
        invocationName = command.name
        self.displayName = displayName
        friendlyName = ComposerResourceNameFormatter.friendly(displayName)
        description = command.description
        argumentHint = command.argumentHint
        source = command.source
        sourcePath = command.sourcePath
        resourceSource = command.resourceSource
        resourceScope = command.resourceScope
        resourceOrigin = command.resourceOrigin
        normalizedName = displayName.lowercased()
        normalizedSearch = [displayName, command.description, command.argumentHint]
            .compactMap { $0?.lowercased() }
            .joined(separator: "\u{1f}")
    }

    var commandInfo: CommandInfo {
        CommandInfo(
            name: invocationName,
            description: description,
            argumentHint: argumentHint,
            source: source,
            sourcePath: sourcePath,
            resourceSource: resourceSource,
            resourceScope: resourceScope,
            resourceOrigin: resourceOrigin
        )
    }

    func invocation(arguments: String = "") -> ComposerResourceInvocation {
        let invocationSource: ComposerResourceInvocation.Source = switch source {
        case .skill: .skill
        case .prompt: .prompt
        case .extension: .extension
        }
        return ComposerResourceInvocation(
            source: invocationSource,
            name: source == .skill ? displayName : invocationName,
            arguments: arguments
        )
    }
}

enum ComposerResourceContentPresentation {
    struct Preview: Equatable {
        let text: String
        let isTruncated: Bool
    }

    /// Prompt and skill instructions retain their full admitted body. Only
    /// extension source uses a short excerpt instead of the transport allowance.
    static func preview(_ content: String, source: CommandInfo.Source, sourceTruncated: Bool) -> Preview {
        let text = body(content, source: source)
        guard source == .extension else { return Preview(text: text, isTruncated: sourceTruncated) }
        var end = text.index(text.startIndex, offsetBy: 480, limitedBy: text.endIndex) ?? text.endIndex
        var lines = 1
        for index in text[..<end].indices where text[index].isNewline {
            if lines == 10, text.index(after: index) < text.endIndex {
                end = index
                break
            }
            lines += 1
        }
        return Preview(text: String(text[..<end]), isTruncated: sourceTruncated || end < text.endIndex)
    }

    static func body(_ content: String, source: CommandInfo.Source) -> String {
        guard source != .extension else { return content }

        // Markdown resources may begin with a UTF-8 BOM decoded as U+FEFF.
        // Remove it at the Unicode-scalar boundary: U+FEFF can share a Swift
        // grapheme cluster with the opening hyphens and is not reliably found
        // as a standalone Character substring.
        var normalized = content
        if normalized.unicodeScalars.first?.value == 0xFEFF {
            let firstContentScalar = normalized.unicodeScalars.index(
                after: normalized.unicodeScalars.startIndex
            )
            normalized = String(normalized.unicodeScalars[firstContentScalar...])
        }
        normalized = normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let markdown: String
        if let openingEnd = normalized.firstIndex(of: "\n"),
           normalized[normalized.startIndex..<openingEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
            var lineStart = normalized.index(after: openingEnd)
            var bodyStart: String.Index?
            while lineStart < normalized.endIndex {
                let lineEnd = normalized[lineStart...].firstIndex(of: "\n") ?? normalized.endIndex
                let line = normalized[lineStart..<lineEnd]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line == "---" || line == "..." {
                    bodyStart = lineEnd < normalized.endIndex
                        ? normalized.index(after: lineEnd)
                        : normalized.endIndex
                    break
                }
                guard lineEnd < normalized.endIndex else { break }
                lineStart = normalized.index(after: lineEnd)
            }
            guard let bodyStart else { return content }
            markdown = String(normalized[bodyStart...])
        } else {
            markdown = normalized
        }
        return normalizingSoftWraps(in: markdown)
    }

    /// Skill and prompt files are commonly hard-wrapped for source readability.
    /// Preserve Markdown block boundaries and intentional hard breaks while
    /// letting SwiftUI choose natural visual wrapping for ordinary prose and
    /// list continuations.
    static func normalizingSoftWraps(in markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.count > 1 else { return markdown }

        var result = lines[0]
        var insideFence = isFence(lines[0])
        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let current = lines[index]
            let currentIsFence = isFence(current)
            let preservesLineBreak = insideFence
                || currentIsFence
                || previous.trimmingCharacters(in: .whitespaces).isEmpty
                || current.trimmingCharacters(in: .whitespaces).isEmpty
                || hasIntentionalHardBreak(previous)
                || beginsIndependentBlock(current)
                || endsStandaloneBlock(previous)

            result.append(preservesLineBreak ? "\n" : " ")
            result.append(contentsOf: preservesLineBreak
                ? current
                : current.trimmingCharacters(in: .whitespaces))

            if currentIsFence { insideFence.toggle() }
        }
        return result
    }

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func hasIntentionalHardBreak(_ line: String) -> Bool {
        line.hasSuffix("  ") || line.hasSuffix("\\")
    }

    private static func beginsIndependentBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isHeading(trimmed)
            || isListItem(line)
            || trimmed.hasPrefix(">")
            || isRule(trimmed)
            || line.hasPrefix("    ")
            || line.contains("|")
    }

    private static func endsStandaloneBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return isHeading(trimmed)
            || trimmed.hasPrefix(">")
            || isRule(trimmed)
            || line.hasPrefix("    ")
            || line.contains("|")
    }

    private static func isHeading(_ line: String) -> Bool {
        line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) != nil
    }

    private static func isListItem(_ line: String) -> Bool {
        line.range(
            of: #"^\s*(?:[-+*]|\d+[.)])\s+"#,
            options: .regularExpression
        ) != nil
    }

    private static func isRule(_ line: String) -> Bool {
        line.range(
            of: #"^(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$"#,
            options: .regularExpression
        ) != nil
    }
}

enum ComposerResourceNameFormatter {
    private static let initialisms: [String: String] = [
        "ai": "AI", "api": "API", "http": "HTTP", "id": "ID",
        "ios": "iOS", "json": "JSON", "macos": "macOS", "pi": "Pi",
        "rpc": "RPC", "sdk": "SDK", "ui": "UI", "url": "URL",
    ]

    static func friendly(_ value: String) -> String {
        let expanded = value
            .replacingOccurrences(
                of: "([A-Z]+)([A-Z][a-z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[-_:]+", with: " ", options: .regularExpression)
        let words = expanded.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return value }
        return words.map { word in
            let raw = String(word)
            return initialisms[raw.lowercased()]
                ?? raw.prefix(1).uppercased() + String(raw.dropFirst())
        }.joined(separator: " ")
    }
}

/// Immutable, bounded presentation index derived from the authoritative session
/// command catalog. It owns no fetch path and can be prepared off-main.
struct ComposerResourceCatalogIdentity: Hashable {
    let commands: [CommandInfo]
    let catalogTarget: SessionPresentationIdentity?
    let presentationTarget: SessionPresentationIdentity?
    let supportsSkillPrompt: Bool
}

struct ComposerResourceCatalog: Equatable, Sendable {
    static let maximumResults = CommandCatalogPolicy.maximumCommands
    private(set) var skills: [ComposerResourceEntry]
    private(set) var commands: [ComposerResourceEntry]
    private(set) var prompts: [ComposerResourceEntry]

    init(commands source: [CommandInfo]) {
        let admitted = source.prefix(CommandCatalogPolicy.maximumCommands).compactMap(ComposerResourceEntry.init)
        let extensionInvocationNames = Set(
            admitted.filter { $0.source == .extension }.map(\.invocationName)
        )
        skills = admitted.filter {
            $0.kind == .skill && !extensionInvocationNames.contains($0.invocationName)
        }.sorted(by: Self.order)
        commands = admitted.filter { $0.kind == .command }.sorted(by: Self.order)
        prompts = admitted.filter { $0.kind == .prompt }.sorted(by: Self.order)
    }

    func entries(kind: ComposerResourceEntry.Kind, query: String) -> [ComposerResourceEntry] {
        let source: [ComposerResourceEntry]
        switch kind {
        case .skill: source = skills
        case .command: source = commands
        case .prompt: source = prompts
        }
        return Self.filtered(source, query: query)
    }

    private static func filtered(_ source: [ComposerResourceEntry], query: String) -> [ComposerResourceEntry] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return source }
        var prefixes: [ComposerResourceEntry] = []
        var remaining: [ComposerResourceEntry] = []
        prefixes.reserveCapacity(min(source.count, 32))
        for entry in source where entry.normalizedSearch.contains(normalized) {
            if entry.normalizedName.hasPrefix(normalized) { prefixes.append(entry) }
            else { remaining.append(entry) }
            if prefixes.count + remaining.count == Self.maximumResults { break }
        }
        let relevanceOrder: (ComposerResourceEntry, ComposerResourceEntry) -> Bool = { lhs, rhs in
            if lhs.displayName.count != rhs.displayName.count {
                return lhs.displayName.count < rhs.displayName.count
            }
            return Self.order(lhs, rhs)
        }
        return prefixes.sorted(by: relevanceOrder) + remaining.sorted(by: relevanceOrder)
    }

    /// Slash completion intentionally searches both extension commands and
    /// prompts; the selected entry retains its canonical source for admission.
    func slashEntries(query: String) -> [ComposerResourceEntry] {
        Self.filtered((commands + prompts).sorted(by: Self.order), query: query)
    }

    /// Both fresh derivation and subsequent typing use the same picker scope.
    /// An @ mention never admits slash resources, even after catalog replacement.
    func entries(for picker: ComposerResourcePickerSource) -> [ComposerResourceEntry] {
        if case .token(let token) = picker, token.kind == .command {
            return slashEntries(query: token.query)
        }
        return entries(kind: picker.kind, query: picker.query)
    }

    func exactSkill(named displayName: String) -> ComposerResourceEntry? {
        let matches = skills.filter { $0.displayName == displayName }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func order(_ lhs: ComposerResourceEntry, _ rhs: ComposerResourceEntry) -> Bool {
        if lhs.normalizedName != rhs.normalizedName { return lhs.normalizedName < rhs.normalizedName }
        return lhs.id < rhs.id
    }
}

struct ComposerSuggestionToken: Equatable, Sendable {
    let kind: ComposerResourceEntry.Kind
    let query: String
    /// UTF-16 range from trigger through the character immediately before the caret.
    let replacementRange: NSRange
}

enum ComposerSuggestionTriggerPolicy {
    static func activeToken(in text: String, selection: NSRange) -> ComposerSuggestionToken? {
        let value = text as NSString
        guard selection.length == 0, selection.location <= value.length else { return nil }
        let prefix = value.substring(to: selection.location)
        guard let candidate = lastCandidate(in: prefix) else { return nil }
        let triggerLocation = (prefix as NSString).range(of: String(candidate.trigger), options: .backwards).location
        guard triggerLocation != NSNotFound else { return nil }
        let before = (prefix as NSString).substring(to: triggerLocation)
        if candidate.trigger == "/" {
            // Pi commands are executable only as the leading trimmed token.
            guard before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        } else if !before.isEmpty {
            guard before.last?.isWhitespace == true else { return nil }
        }
        guard !isInsideInlineCode(prefix: before) else { return nil }
        let queryLocation = triggerLocation + 1
        var tokenEnd = selection.location
        while tokenEnd < value.length,
              let scalar = UnicodeScalar(value.character(at: tokenEnd)),
              isQueryScalar(scalar) {
            tokenEnd += 1
        }
        let query = value.substring(with: NSRange(
            location: queryLocation,
            length: tokenEnd - queryLocation
        ))
        guard query.unicodeScalars.allSatisfy(isQueryScalar) else { return nil }
        return ComposerSuggestionToken(
            kind: candidate.trigger == "@" ? .skill : .command,
            query: query,
            replacementRange: NSRange(location: triggerLocation, length: tokenEnd - triggerLocation)
        )
    }

    static func replacing(
        text: String,
        range: NSRange,
        with replacement: String
    ) -> (text: String, selection: NSRange)? {
        let value = text as NSString
        guard range.location <= value.length, range.length <= value.length - range.location else { return nil }
        let replaced = value.replacingCharacters(in: range, with: replacement)
        let caret = range.location + (replacement as NSString).length
        return (replaced, NSRange(location: caret, length: 0))
    }

    private static func lastCandidate(in prefix: String) -> (trigger: Character, location: Int)? {
        let value = prefix as NSString
        let at = value.range(of: "@", options: .backwards).location
        let slash = value.range(of: "/", options: .backwards).location
        let location = max(at == NSNotFound ? -1 : at, slash == NSNotFound ? -1 : slash)
        guard location >= 0 else { return nil }
        return (value.character(at: location) == 64 ? "@" : "/", location)
    }

    private static func isInsideInlineCode(prefix: String) -> Bool {
        var unescapedBackticks = 0
        var escaped = false
        for character in prefix {
            if character == "\\" { escaped.toggle(); continue }
            if character == "`", !escaped { unescapedBackticks += 1 }
            escaped = false
        }
        return unescapedBackticks.isMultiple(of: 2) == false
    }

    private static func isQueryScalar(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
            || scalar == "-" || scalar == "_" || scalar == ":" || scalar == "."
    }
}

enum ComposerCommandCompletionPolicy {
    static func removingLeadingCommand(
        text: String,
        selection: NSRange,
        commands: [ComposerResourceEntry]
    ) -> (text: String, selection: NSRange) {
        let value = text as NSString
        for command in commands.sorted(by: { $0.invocationName.count > $1.invocationName.count }) {
            let prefix = "/\(command.invocationName)"
            guard value.hasPrefix(prefix) else { continue }
            var end = (prefix as NSString).length
            if end < value.length {
                guard let boundary = UnicodeScalar(value.character(at: end)),
                      CharacterSet.whitespacesAndNewlines.contains(boundary) else { continue }
            }
            while end < value.length,
                  let scalar = UnicodeScalar(value.character(at: end)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                end += 1
            }
            let replacement = ComposerSuggestionTriggerPolicy.replacing(
                text: text,
                range: NSRange(location: 0, length: end),
                with: ""
            ) ?? (text, selection)
            let adjustedLocation = selection.location >= end
                ? selection.location - end
                : 0
            return (replacement.text, NSRange(
                location: min(adjustedLocation, (replacement.text as NSString).length),
                length: 0
            ))
        }
        return (text, selection)
    }
}

enum ComposerResourcePanelPolicy {
    static let regularVisibleRows = 5
    static let keyboardVisibleRows = 3
    static let regularEditorLines = 8
    static let panelEditorLines = 4

    static func visibleRows(entryCount: Int, keyboardVisible: Bool) -> Int {
        min(max(0, entryCount), keyboardVisible ? keyboardVisibleRows : regularVisibleRows)
    }

    static func editorLines(panelPresented: Bool, keyboardVisible: Bool) -> Int {
        panelPresented && keyboardVisible ? panelEditorLines : regularEditorLines
    }
}

enum ComposerResourcePickerSource: Equatable {
    case menu(ComposerResourceEntry.Kind)
    case token(ComposerSuggestionToken)

    var kind: ComposerResourceEntry.Kind {
        switch self {
        case .menu(let kind): kind
        case .token(let token): token.kind
        }
    }

    var query: String {
        if case .token(let token) = self { return token.query }
        return ""
    }

    var title: String {
        if case .token(let token) = self, token.kind == .command { return "Commands & Prompts" }
        return switch kind {
        case .skill: "Skills"
        case .command: "Commands"
        case .prompt: "Prompts"
        }
    }
}

struct ComposerResourcePicker: View {
    let sessionID: String?
    let source: ComposerResourcePickerSource
    let entries: [ComposerResourceEntry]
    let keyboardVisible: Bool
    let onSelect: (ComposerResourceEntry) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var detail: ComposerResourceEntry?

    private var kind: ComposerResourceEntry.Kind { source.kind }
    private var query: String { source.query }

    private var accent: Color {
        switch kind {
        case .skill: .tronCyan
        case .prompt: ChatSemanticPillRole.prompt.accent
        case .command: ChatSemanticPillRole.command.accent
        }
    }
    private var icon: String {
        switch kind {
        case .skill: "sparkles"
        case .prompt: "text.quote"
        case .command: "command"
        }
    }
    private var title: String { source.title }
    private func accent(for entry: ComposerResourceEntry) -> Color {
        switch entry.kind {
        case .skill: .tronCyan
        case .prompt: ChatSemanticPillRole.prompt.accent
        case .command: ChatSemanticPillRole.command.accent
        }
    }

    private func icon(for entry: ComposerResourceEntry) -> String {
        switch entry.kind {
        case .skill: "sparkles"
        case .prompt: "text.quote"
        case .command: "command"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    if !query.isEmpty {
                        Text("· \"\(query)\"")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                }
                .foregroundStyle(accent)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeXL))
                        .foregroundStyle(Color.tronTextMuted)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss \(title.lowercased())")
            }
            .padding(.leading, 14)
            .padding(.trailing, 7)
            .padding(.top, 6)

            if entries.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("No \(title.lowercased()) found")
                }
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            resourceRow(entry)
                        }
                    }
                }
                .frame(
                    maxHeight: CGFloat(ComposerResourcePanelPolicy.visibleRows(
                        entryCount: entries.count,
                        keyboardVisible: keyboardVisible
                    )) * 48
                )
            }
        }
        .padding(.bottom, 6)
        .glassEffect(
            .regular.tint(accent.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .tronManagedSheet(
            item: $detail,
            identity: { "composer.resource.\($0.id)" }
        ) { entry in
            ComposerResourceDetailSheet(
                sessionID: sessionID,
                entry: entry,
                accent: accent(for: entry),
                prefix: entry.kind == .skill ? "@" : "/"
            )
        }
    }

    private func resourceRow(_ entry: ComposerResourceEntry) -> some View {
        HStack(spacing: 0) {
            Button { onSelect(entry) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(accent(for: entry).opacity(0.15)).frame(width: 28, height: 28)
                        Image(systemName: icon(for: entry))
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                            .foregroundStyle(accent(for: entry))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.friendlyName)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                                .foregroundStyle(Color.tronTextPrimary)
                                .lineLimit(1)
                            ComposerResourceBadges(
                                origin: entry.resourceOrigin, scope: entry.resourceScope,
                                accent: accent(for: entry)
                            )
                        }
                        Text(ComposerResourceContentPresentation.normalizingSoftWraps(
                            in: entry.description ?? entry.argumentHint ?? "No description"
                        ))
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(CanonicalResourceChipPresentation.kindTitle(for: entry.invocation())), \(entry.displayName)\(ComposerResourceBadges.titles(origin: entry.resourceOrigin, scope: entry.resourceScope).map { ", \($0)" }.joined())")
            .accessibilityHint("Selects \(entry.kind == .skill ? "@" : "/")\(entry.displayName)")

            Button { detail = entry } label: {
                Image(systemName: "info.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                    .foregroundStyle(accent(for: entry))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About \(entry.displayName)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
    }

}

/// Project scope takes precedence over authorship. User identifies only
/// directly authored global resources, never a package installation.
struct ComposerResourceBadges: View {
    let origin: CommandInfo.ResourceOrigin?
    let scope: CommandInfo.ResourceScope?
    let hookProvenance: HookProvenance?
    let accent: Color

    init(
        origin: CommandInfo.ResourceOrigin? = nil,
        scope: CommandInfo.ResourceScope? = nil,
        hookProvenance: HookProvenance? = nil,
        accent: Color
    ) {
        self.origin = origin
        self.scope = scope
        self.hookProvenance = hookProvenance
        self.accent = accent
    }

    static func titles(origin: CommandInfo.ResourceOrigin?, scope: CommandInfo.ResourceScope?) -> [String] {
        if scope == .project { return ["Project"] }
        return scope == .user && origin == .topLevel ? ["User"] : []
    }

    var body: some View {
        ForEach(hookProvenance.map { [$0.rawValue] } ?? Self.titles(origin: origin, scope: scope), id: \.self) { title in
            ResourceTagLabel(title: title, accent: accent)
        }
    }
}

struct ComposerResourceDetailSheet: View {
    let sessionID: String?
    let entry: ComposerResourceEntry
    let accent: Color
    let prefix: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var detail: CommandResourceDetail?
    @State private var loadError: String?
    @State private var loadRevision = 0
    @State private var detailGeneration = 0
    @State private var loadedIdentity: String?
    @State private var detent: PresentationDetent = .medium
    @State private var showsResourceInfo = false

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    summary
                    contentSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsResourceInfo = true } label: {
                        Image(systemName: "info.circle")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Resource Info")
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 5) {
                        TronSheetTitle(title: entry.friendlyName, accent: accent)
                        ComposerResourceBadges(
                            origin: detail?.resourceOrigin ?? entry.resourceOrigin,
                            scope: detail?.resourceScope ?? entry.resourceScope,
                            accent: accent
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
            .tint(accent)
        }
        .tronManagedSheet(isPresented: $showsResourceInfo, identity: "composer.resource-info.\(entry.id)") {
            ComposerResourceInfoSheet(items: metadata, accent: accent)
        }
        .task(id: PresentationActivityTaskID(
            source: "\(entry.id):\(resourceRevision):\(loadRevision)",
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await loadDetail()
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    private var resolvedDescription: String? {
        detail?.description ?? entry.description
    }

    private var metadata: [TronTechnicalMetadataItem] {
        let kindTitle: String
        let kindIcon: String
        switch entry.kind {
        case .skill:
            kindTitle = "Skill"
            kindIcon = "sparkles"
        case .prompt:
            kindTitle = "Prompt"
            kindIcon = "text.quote"
        case .command:
            kindTitle = "Command"
            kindIcon = "command"
        }
        var items = [
            TronTechnicalMetadataItem(
                title: "Type",
                value: kindTitle,
                icon: kindIcon
            ),
            TronTechnicalMetadataItem(
                title: "Invocation",
                value: "\(prefix)\(entry.displayName)",
                icon: "terminal"
            ),
            TronTechnicalMetadataItem(
                title: "Source",
                value: sourceTitle,
                icon: "shippingbox"
            ),
        ]
        if let resourceSource = detail?.resourceSource ?? entry.resourceSource,
           !resourceSource.isEmpty {
            items.append(.init(title: "Resource source", value: resourceSource, icon: "shippingbox.fill"))
        }
        if let scope = detail?.resourceScope ?? entry.resourceScope {
            items.append(.init(
                title: "Scope",
                value: ComposerResourceNameFormatter.friendly(scope.rawValue),
                icon: scope == .project ? "folder" : "person"
            ))
        }
        if let origin = detail?.resourceOrigin ?? entry.resourceOrigin {
            items.append(.init(
                title: "Origin",
                value: ComposerResourceNameFormatter.friendly(origin.rawValue),
                icon: "point.3.connected.trianglepath.dotted"
            ))
        }
        if let hint = detail?.argumentHint ?? entry.argumentHint, !hint.isEmpty {
            items.append(.init(title: "Arguments", value: hint, icon: "text.badge.plus"))
        }
        if let path = detail?.sourcePath ?? entry.sourcePath, !path.isEmpty {
            items.append(.init(title: "Source file", value: path, icon: "doc.text"))
        }
        if let bytes = detail?.contentBytes {
            items.append(.init(
                title: "Content size",
                value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                icon: "internaldrive"
            ))
        }
        return items
    }

    private var displayedContent: ComposerResourceContentPresentation.Preview? {
        detail?.content.map {
            ComposerResourceContentPresentation.preview(
                $0, source: entry.source, sourceTruncated: detail?.contentTruncated == true
            )
        }
    }

    private var sourceTitle: String {
        switch entry.source {
        case .skill: "Skill resource"
        case .prompt: "Prompt"
        case .extension: "Extension command"
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let description = resolvedDescription, !description.isEmpty {
            Text(ComposerResourceContentPresentation.normalizingSoftWraps(in: description))
                .font(TronTypography.body)
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tronGlassSurface(accent: accent, tintOpacity: 0.10)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TronTechnicalSectionLabel("Content")
            Group {
                if let content = displayedContent, !content.text.isEmpty {
                    ComposerResourceContentBody(preview: content, source: entry.source)
                } else if let loadError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(loadError)
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                        Button("Try Again", systemImage: "arrow.clockwise") { loadRevision &+= 1 }
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                } else if sessionID == nil {
                    Text("Source content is unavailable for this session.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                } else if detail != nil {
                    Text("This resource does not expose body content.")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextSecondary)
                } else {
                    TronLoadingState(label: "Loading resource content…")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronScrollSurface(accent: accent, cornerRadius: 16, tintOpacity: 0.06)
        }
    }

    /// Identity of the reader this sheet displays. A completed detail for this
    /// exact identity stays mounted across a cover, so returning from the
    /// nested Info sheet neither blanks content nor refetches the same source.
    private var loadIdentity: String {
        "\(sessionID ?? "-"):\(entry.id)"
    }

    private var resourceRevision: Int {
        sessionID.map { model.sessionResourceRevision(for: $0) } ?? 0
    }

    private func loadDetail() async {
        guard let sessionID else {
            detailGeneration &+= 1
            detail = nil
            loadError = nil
            loadedIdentity = nil
            return
        }
        if loadedIdentity == loadIdentity, detail != nil, loadError == nil { return }
        detailGeneration &+= 1
        let generation = detailGeneration
        let identity = loadIdentity
        detail = nil
        loadError = nil
        do {
            let loaded = try await model.commandDetail(sessionID: sessionID, command: entry.commandInfo)
            guard generation == detailGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            detail = loaded
            loadedIdentity = identity
        } catch is CancellationError {
            // Interrupted work publishes nothing, so the next activation retries.
            return
        } catch {
            guard generation == detailGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            loadError = error.localizedDescription
            loadedIdentity = identity
        }
    }
}

struct ComposerResourceChip: View {
    let sessionID: String?
    let resource: ComposerResourceEntry
    let onRemove: () -> Void
    @State private var showsDetail = false

    var body: some View {
        ChatCompactPillSurface(
            tone: tone,
            material: .glass,
            interactive: true,
            accentOverride: accent,
            cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
        ) {
            HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                Button { showsDetail = true } label: {
                    HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                        ChatCompactPillLabel(
                            icon: resourceIcon,
                            title: resource.friendlyName,
                            tone: tone,
                            iconSize: TronTypography.sizeBody,
                            titleWeight: .bold,
                            foregroundOverride: resource.source == .skill ? accent : nil
                        )
                        ComposerResourceBadges(
                            origin: resource.resourceOrigin, scope: resource.resourceScope,
                            accent: accent
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show resource details, \(resource.friendlyName)")

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove resource, \(resource.friendlyName)")
            }
        }
        .accessibilityElement(children: .contain)
        .tronManagedSheet(
            isPresented: $showsDetail,
            identity: "composer.canonical-resource.\(resource.id)"
        ) {
            ComposerResourceDetailSheet(
                sessionID: sessionID,
                entry: resource,
                accent: accent,
                prefix: resource.source == .skill ? "@" : "/"
            )
        }
    }

    private var tone: ChatNotificationTone {
        switch resource.source {
        case .skill: .information
        case .prompt: ChatSemanticPillRole.prompt.tone
        case .extension: ChatSemanticPillRole.command.tone
        }
    }

    private var resourceIcon: String {
        switch resource.source {
        case .skill: "sparkles"
        case .prompt: "text.quote"
        case .extension: "command"
        }
    }

    private var accent: Color {
        switch resource.source {
        case .skill: .tronCyan
        case .prompt: ChatSemanticPillRole.prompt.accent
        case .extension: ChatSemanticPillRole.command.accent
        }
    }
}

enum ComposerResourceInvocationPolicy {
    /// Resolves only a leading, catalog-backed Pi resource command. Extension
    /// and skill commands use Pi's literal ASCII-space delimiter; prompt
    /// templates use Pi's whitespace delimiter after extension precedence.
    static func leadingInvocation(
        in text: String,
        commands: [CommandInfo]
    ) -> ComposerResourceInvocation? {
        guard text.first == "/" else { return nil }
        let remainder = text.dropFirst()
        let literalParts = remainder.split(
            separator: " ", maxSplits: 1, omittingEmptySubsequences: false
        )
        let literalName = String(literalParts.first ?? "")
        guard !literalName.isEmpty else { return nil }
        let literalArguments = literalParts.count > 1 ? String(literalParts[1]) : ""

        if let command = commands.first(where: {
            $0.source == .extension && $0.name == literalName
        }) {
            return invocation(command, arguments: literalArguments)
        }
        if literalName.hasPrefix("skill:"), let command = commands.first(where: {
            $0.source == .skill && $0.name == literalName
        }) {
            return invocation(command, arguments: literalArguments)
        }

        let promptName: String
        let promptArguments: String
        if let boundary = remainder.firstIndex(where: \.isWhitespace) {
            promptName = String(remainder[..<boundary])
            promptArguments = String(remainder[boundary...])
        } else {
            promptName = String(remainder)
            promptArguments = ""
        }
        guard !promptName.isEmpty, let command = commands.first(where: {
            $0.source == .prompt && $0.name == promptName
        }) else { return nil }
        return invocation(command, arguments: promptArguments)
    }

    private static func invocation(
        _ command: CommandInfo,
        arguments: String
    ) -> ComposerResourceInvocation {
        let source: ComposerResourceInvocation.Source = switch command.source {
        case .skill: .skill
        case .prompt: .prompt
        case .extension: .extension
        }
        return ComposerResourceInvocation(
            source: source,
            name: source == .skill && command.name.hasPrefix("skill:")
                ? String(command.name.dropFirst("skill:".count))
                : command.name,
            arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
