import Foundation
import SwiftUI

struct ComposerResourceEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case skill, command }

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
        case .extension, .prompt:
            kind = .command
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
}

enum ComposerResourceContentPresentation {
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
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
        guard let openingEnd = normalized.firstIndex(of: "\n") else { return content }
        let opening = normalized[normalized.startIndex..<openingEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        guard opening == "---" else { return content }

        var lineStart = normalized.index(after: openingEnd)
        while lineStart < normalized.endIndex {
            let lineEnd = normalized[lineStart...].firstIndex(of: "\n") ?? normalized.endIndex
            let line = normalized[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." {
                guard lineEnd < normalized.endIndex else { return "" }
                return String(normalized[normalized.index(after: lineEnd)...])
            }
            guard lineEnd < normalized.endIndex else { break }
            lineStart = normalized.index(after: lineEnd)
        }
        return content
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

    init(commands source: [CommandInfo]) {
        let admitted = source.prefix(CommandCatalogPolicy.maximumCommands).compactMap(ComposerResourceEntry.init)
        let extensionInvocationNames = Set(
            admitted.filter { $0.source == .extension }.map(\.invocationName)
        )
        skills = admitted.filter {
            $0.kind == .skill && !extensionInvocationNames.contains($0.invocationName)
        }.sorted(by: Self.order)
        commands = admitted.filter { $0.kind == .command }.sorted(by: Self.order)
    }

    func entries(kind: ComposerResourceEntry.Kind, query: String) -> [ComposerResourceEntry] {
        let source = kind == .skill ? skills : commands
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
}

struct ComposerResourcePicker: View {
    let sessionID: String?
    let kind: ComposerResourceEntry.Kind
    let query: String
    let entries: [ComposerResourceEntry]
    let keyboardVisible: Bool
    let onSelect: (ComposerResourceEntry) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var detail: ComposerResourceEntry?

    private var accent: Color { kind == .skill ? Color.tronCyan : Color.tronPurple }
    private var icon: String { kind == .skill ? "sparkles" : "command" }
    private var title: String { kind == .skill ? "Skills" : "Commands" }
    private var prefix: String { kind == .skill ? "@" : "/" }

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
                accent: accent,
                prefix: prefix
            )
        }
    }

    private func resourceRow(_ entry: ComposerResourceEntry) -> some View {
        HStack(spacing: 0) {
            Button { onSelect(entry) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(accent.opacity(0.15)).frame(width: 28, height: 28)
                        Image(systemName: icon)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.friendlyName)
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                                .foregroundStyle(Color.tronTextPrimary)
                                .lineLimit(1)
                            if entry.source == .prompt {
                                sourceBadge("prompt")
                            } else if entry.source == .extension {
                                sourceBadge("extension")
                            }
                        }
                        Text(entry.description ?? entry.argumentHint ?? "No description")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title.dropLast()), \(entry.displayName)")
            .accessibilityHint("Selects \(prefix)\(entry.displayName)")

            Button { detail = entry } label: {
                Image(systemName: "info.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                    .foregroundStyle(accent)
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

    private func sourceBadge(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            .foregroundStyle(accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(accent.opacity(0.15), in: Capsule())
    }
}

struct ComposerResourceDetailSheet: View {
    let sessionID: String?
    let entry: ComposerResourceEntry
    let accent: Color
    let prefix: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var detail: CommandResourceDetail?
    @State private var loadError: String?
    @State private var loadRevision = 0
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    summary
                    TronTechnicalMetadataSection(
                        title: "Resource",
                        items: metadata,
                        accent: accent
                    )
                    contentSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: entry.friendlyName, accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .task(id: "\(entry.id):\(loadRevision)") { await loadDetail() }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    private var resolvedDescription: String? {
        detail?.description ?? entry.description
    }

    private var metadata: [TronTechnicalMetadataItem] {
        var items = [
            TronTechnicalMetadataItem(
                title: "Type",
                value: entry.kind == .skill ? "Skill" : "Command",
                icon: entry.kind == .skill ? "sparkles" : "command"
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

    private var displayedContent: String? {
        detail?.content.map {
            ComposerResourceContentPresentation.body($0, source: entry.source)
        }
    }

    private var sourceTitle: String {
        switch entry.source {
        case .skill: "Skill resource"
        case .prompt: "Prompt template"
        case .extension: "Extension command"
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let description = resolvedDescription, !description.isEmpty {
            Text(description)
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
                if let content = displayedContent, !content.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if detail?.contentTruncated == true {
                            Label("Showing the first 96 KiB of the source", systemImage: "text.badge.minus")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronAmber)
                        }
                        if entry.source == .extension {
                            Text(content)
                                .font(TronTypography.codeContent)
                                .foregroundStyle(Color.tronTextPrimary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            TronMarkdownView(text: content, streaming: false)
                                .textSelection(.enabled)
                        }
                    }
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

    private func loadDetail() async {
        detail = nil
        loadError = nil
        guard let sessionID else { return }
        do {
            detail = try await model.commandDetail(sessionID: sessionID, command: entry.commandInfo)
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
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
            cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
        ) {
            HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                Button { showsDetail = true } label: {
                    ChatCompactPillLabel(
                        icon: resource.commandInfo.source == .skill ? "sparkles" : "command",
                        title: resource.friendlyName,
                        tone: tone,
                        iconSize: TronTypography.sizeBody,
                        titleWeight: .bold
                    )
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
        resource.source == .skill ? .information : .purple
    }

    private var accent: Color {
        resource.source == .skill ? .tronCyan : .tronPurple
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
