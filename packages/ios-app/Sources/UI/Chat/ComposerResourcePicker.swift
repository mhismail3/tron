import Foundation
import SwiftUI

struct ComposerResourceEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case skill, command }

    let id: String
    let kind: Kind
    let invocationName: String
    let displayName: String
    let description: String?
    let argumentHint: String?
    let source: CommandInfo.Source
    let sourcePath: String?
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
        description = command.description
        argumentHint = command.argumentHint
        source = command.source
        sourcePath = command.sourcePath
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
            sourcePath: sourcePath
        )
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
        .sheet(item: $detail) { entry in
            ComposerResourceDetailSheet(entry: entry, accent: accent, prefix: prefix)
        }
    }

    private func resourceRow(_ entry: ComposerResourceEntry) -> some View {
        HStack(spacing: 0) {
            Button { onSelect(entry) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(accent.opacity(0.15)).frame(width: 32, height: 32)
                        Image(systemName: icon)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("\(prefix)\(entry.displayName)")
                                .font(TronTypography.secondaryCodeDescription)
                                .foregroundStyle(Color.tronTextPrimary)
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

private struct ComposerResourceDetailSheet: View {
    let entry: ComposerResourceEntry
    let accent: Color
    let prefix: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(prefix)\(entry.displayName)")
                        .font(TronTypography.headline)
                        .foregroundStyle(accent)
                    if let description = entry.description {
                        Text(description).font(TronTypography.body).foregroundStyle(Color.tronTextPrimary)
                    }
                    if let hint = entry.argumentHint {
                        Text(hint).font(TronTypography.secondaryCodeDescription).foregroundStyle(Color.tronTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.tronBackground)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.tronEmerald)
                }
            }
        }
        .presentationDragIndicator(.hidden)
    }
}

struct ComposerSkillChip: View {
    let skill: ComposerResourceEntry
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(Color.tronCyan)
            Text(skill.displayName)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(Color.tronTextMuted)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove skill, \(skill.displayName)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .glassEffect(.regular.tint(Color.tronCyan.opacity(0.40)), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skill, \(skill.displayName)")
    }
}
