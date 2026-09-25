import Foundation
import Testing
import UIKit
@testable import TronMobile

@Suite("Composer resource picker")
struct ComposerResourcePickerTests {

    @Test("mention and command triggers respect boundaries, caret, and inline code")
    func triggerBoundaries() {
        #expect(token("@", caret: 1)?.kind == .skill)
        #expect(token("hello @rev", caret: 10)?.query == "rev")
        #expect(token("email@example", caret: 13) == nil)
        #expect(token("`@review", caret: 8) == nil)
        #expect(token("`code` @review", caret: 14)?.kind == .skill)
        #expect(token("/comp", caret: 5)?.kind == .command)
        #expect(token("hello /comp", caret: 11) == nil)
        #expect(token("/comp more", caret: 10) == nil)
        #expect(token("@review", caret: 4)?.replacementRange == NSRange(location: 0, length: 7))
        #expect(token("/compact args", caret: 4)?.replacementRange == NSRange(location: 0, length: 8))
        #expect(ComposerSuggestionTriggerPolicy.activeToken(
            in: "@review",
            selection: NSRange(location: 2, length: 2)
        ) == nil)
    }

    @Test("manual leading resources use Pi delimiter and extension precedence")
    func manualLeadingResourceParsing() {
        let commands = [
            command("skill:review", source: .skill),
            command("review", source: .prompt),
            command("review", source: .extension),
        ]
        #expect(ComposerResourceInvocationPolicy.leadingInvocation(in: "/skill:review inspect", commands: commands)
            == ComposerResourceInvocation(source: .skill, name: "review", arguments: "inspect"))
        #expect(ComposerResourceInvocationPolicy.leadingInvocation(in: "/review inspect", commands: commands)
            == ComposerResourceInvocation(source: .extension, name: "review", arguments: "inspect"))
        #expect(ComposerResourceInvocationPolicy.leadingInvocation(in: "/review\tinspect", commands: commands)
            == ComposerResourceInvocation(source: .prompt, name: "review", arguments: "inspect"))
        #expect(ComposerResourceInvocationPolicy.leadingInvocation(in: "/review\ninspect", commands: commands)
            == ComposerResourceInvocation(source: .prompt, name: "review", arguments: "inspect"))
        #expect(ComposerResourceInvocationPolicy.leadingInvocation(in: "say /review inspect", commands: commands) == nil)
    }

    @Test("resource invocation transport identity is bounded before optimistic admission")
    func resourceInvocationTransportAdmission() {
        #expect(ComposerResourceInvocation(
            source: .skill, name: "review", arguments: "one\ntwo"
        ).isTransportValid)
        #expect(!ComposerResourceInvocation(
            source: .prompt, name: "two words", arguments: "x"
        ).isTransportValid)
        #expect(!ComposerResourceInvocation(
            source: .prompt, name: "review",
            arguments: String(repeating: "x", count: ComposerResourceInvocation.maximumArgumentBytes + 1)
        ).isTransportValid)
        #expect(!ComposerResourceInvocation(
            source: .extension, name: "goal", arguments: "bad\u{0}value"
        ).isTransportValid)
    }

    @Test("catalog strips skill transport prefixes, excludes skills from commands, and filters deterministically")
    func catalogFiltering() throws {
        let catalog = ComposerResourceCatalog(commands: [
            command("zeta", source: .extension, description: "Review later"),
            command("skill:review", source: .skill, description: "Inspect changes"),
            command("skill:repair", source: .skill, description: "Fix changes"),
            command("skill:repair", source: .extension, description: "Ambiguous extension"),
            command("review-template", source: .prompt, description: "Review now"),
        ])
        #expect(catalog.skills.map(\.displayName) == ["review"])
        #expect(catalog.commands.map(\.displayName) == ["skill:repair", "zeta"])
        #expect(catalog.prompts.map(\.displayName) == ["review-template"])
        #expect(catalog.skills.map(\.friendlyName) == ["Review"])
        #expect(catalog.commands.map(\.friendlyName) == ["Skill Repair", "Zeta"])
        #expect(catalog.entries(kind: .skill, query: "rev").map(\.displayName) == ["review"])
        #expect(catalog.entries(kind: .command, query: "review").map(\.displayName) == ["zeta"])
        #expect(catalog.entries(kind: .prompt, query: "review").map(\.displayName) == ["review-template"])
        #expect(catalog.slashEntries(query: "review").map(\.displayName) == ["review-template", "zeta"])
        #expect(catalog.exactSkill(named: "review")?.invocationName == "skill:review")
    }

    @Test("project badges take precedence and User badges require global authorship",
          arguments: [CommandInfo.Source.skill, .prompt, .extension])
    func resourceProvenance(source: CommandInfo.Source) throws {
        let user = try #require(ComposerResourceEntry(command: CommandInfo(
            name: source == .skill ? "skill:review" : "review",
            description: nil,
            argumentHint: nil,
            source: source,
            sourcePath: "/resources/review.md",
            resourceScope: .project,
            resourceOrigin: .topLevel
        )))
        let package = try #require(ComposerResourceEntry(command: CommandInfo(
            name: source == .skill ? "skill:review" : "review",
            description: nil,
            argumentHint: nil,
            source: source,
            sourcePath: "/package/resources/review.md",
            resourceScope: .user,
            resourceOrigin: .package
        )))
        #expect(ComposerResourceBadges.titles(origin: user.resourceOrigin, scope: user.resourceScope) == ["Project"])
        #expect(ComposerResourceBadges.titles(origin: package.resourceOrigin, scope: package.resourceScope).isEmpty)
        #expect(ComposerResourceBadges.titles(origin: .topLevel, scope: .user) == ["User"])
        #expect(ComposerResourceBadges.titles(origin: .package, scope: .project) == ["Project"])
        #expect(ComposerResourceBadges.titles(origin: nil, scope: .project) == ["Project"])
        #expect(ComposerResourceBadges.titles(origin: nil, scope: nil).isEmpty)
        #expect(ComposerResourceBadges.titles(origin: .topLevel, scope: nil).isEmpty)
        #expect(ComposerResourceBadges.titles(origin: .topLevel, scope: .temporary).isEmpty)
        #expect(ComposerResourceBadges.titles(origin: nil, scope: .user).isEmpty)
        #expect(ComposerResourceContentPresentation.normalizingSoftWraps(
            in: "A folded\ndescription stays natural."
        ) == "A folded description stays natural.")
    }

    @Test("canonical resource chips lead with the friendly name and recover exact detail identity")
    func canonicalChipPresentation() throws {
        let skill = ComposerResourceInvocation(source: .skill, name: "tron-ios", arguments: "inspect")
        #expect(CanonicalResourceChipPresentation.title(for: skill) == "Tron iOS")
        #expect(CanonicalResourceChipPresentation.kindTitle(for: skill) == "Skill")
        #expect(CanonicalResourceChipPresentation.tone(for: skill) == .information)
        #expect(CanonicalResourceChipPresentation.invocationPrefix(for: skill) == "@")
        let skillEntry = try #require(CanonicalResourceChipPresentation.detailEntry(for: skill))
        #expect(skillEntry.commandInfo.source == .skill)
        #expect(skillEntry.commandInfo.name == "skill:tron-ios")

        let prompt = ComposerResourceInvocation(source: .prompt, name: "release_notes", arguments: "")
        #expect(CanonicalResourceChipPresentation.title(for: prompt) == "Release Notes")
        #expect(CanonicalResourceChipPresentation.kindTitle(for: prompt) == "Prompt")
        #expect(CanonicalResourceChipPresentation.icon(for: prompt) == "text.quote")
        #expect(CanonicalResourceChipPresentation.detailEntry(for: prompt)?.kind == .prompt)
        #expect(ChatSemanticPillRole.prompt.tone != ChatSemanticPillRole.command.tone)
        #expect(CanonicalResourceChipPresentation.tone(for: prompt) == ChatSemanticPillRole.prompt.tone)
        #expect(CanonicalResourceChipPresentation.invocationPrefix(for: prompt) == "/")
        #expect(CanonicalResourceChipPresentation.detailEntry(for: prompt)?.commandInfo.name == "release_notes")

        let command = ComposerResourceInvocation(source: .extension, name: "goal", arguments: "set")
        #expect(CanonicalResourceChipPresentation.kindTitle(for: command) == "Command")
        #expect(CanonicalResourceChipPresentation.tone(for: command) == .command)
        #expect(CanonicalResourceChipPresentation.detailEntry(for: command)?.commandInfo.source == .extension)
    }

    @Test("resource content hides duplicate Markdown front matter only")
    func resourceContentBody() {
        let skill = "---\nname: council-mode\ndescription: Council guidance\n---\n# Council Mode\n\nBody"
        #expect(ComposerResourceContentPresentation.body(skill, source: .skill) == "# Council Mode\n\nBody")

        let prompt = "\u{FEFF}---\r\ndescription: Review carefully\r\n...\r\nReview $ARGUMENTS"
        #expect(ComposerResourceContentPresentation.body(prompt, source: .prompt) == "Review $ARGUMENTS")

        let markdownHardBreak = String(repeating: " ", count: 2)
        let hardWrapped = """
        # Benchmark

        Compare alternatives under a frozen contract. Correctness and task
        completeness precede speed.

        - Read repository instructions before creating any
          temporary harness or dataset.
        - Preserve intentional\(markdownHardBreak)
          hard breaks.

        ```text
        keep
        source wrapping
        ```
        """
        #expect(ComposerResourceContentPresentation.body(hardWrapped, source: .skill) == """
        # Benchmark

        Compare alternatives under a frozen contract. Correctness and task completeness precede speed.

        - Read repository instructions before creating any temporary harness or dataset.
        - Preserve intentional\(markdownHardBreak)
          hard breaks.

        ```text
        keep
        source wrapping
        ```
        """)

        let malformed = "---\nname: council-mode\n# No closing delimiter"
        #expect(ComposerResourceContentPresentation.body(malformed, source: .skill) == malformed)
        #expect(ComposerResourceContentPresentation.body(skill, source: .extension) == skill)
    }

    @Test("extension previews are bounded independently of the source read")
    func boundedDetailPreviews() {
        let full = String(repeating: "abcdefghij", count: 400)
        let preview = ComposerResourceContentPresentation.preview(full, source: .extension, sourceTruncated: false)
        #expect(preview.text == String(full.prefix(480)))
        #expect(preview.isTruncated)
        let lines = (1...20).map { "line \($0)" }.joined(separator: "\r\n")
        let linePreview = ComposerResourceContentPresentation.preview(lines, source: .extension, sourceTruncated: false)
        #expect(linePreview.text == (1...10).map { "line \($0)" }.joined(separator: "\r\n"))
        #expect(linePreview.isTruncated)
        let unicode = String(repeating: "👨‍👩‍👧‍👦", count: 481)
        #expect(ComposerResourceContentPresentation.preview(unicode, source: .extension, sourceTruncated: false)
            .text == String(unicode.prefix(480)))
    }

    @Test("prompt and skill details keep their full admitted body", arguments: [CommandInfo.Source.prompt, .skill])
    func fullMarkdownResourceDetails(source: CommandInfo.Source) {
        let paragraph = String(repeating: "Read the complete instructions. ", count: 500)
        // Keep this below 480 characters to catch the line cap independently.
        let steps = (1...20).map { "- Step \($0)" }.joined(separator: "\n")
        let unicode = String(repeating: "👨‍👩‍👧‍👦", count: 481)
        for content in [paragraph, steps, unicode] {
            #expect(ComposerResourceContentPresentation.preview(content, source: source, sourceTruncated: false)
                == .init(text: content, isTruncated: false))
            #expect(ComposerResourceContentPresentation.preview(content, source: source, sourceTruncated: true)
                == .init(text: content, isTruncated: true))
        }
    }

    @Test("truncation notes reflect actual local or Gateway omissions")
    func detailPreviewOmissions() {
        let exact = String(repeating: "x", count: 480)
        let uncut = ComposerResourceContentPresentation.preview(exact, source: .extension, sourceTruncated: false)
        #expect(uncut.text == exact)
        #expect(!uncut.isTruncated)
        let tenLines = String(repeating: "one line\r\n", count: 10)
        #expect(ComposerResourceContentPresentation.preview(tenLines, source: .extension, sourceTruncated: false)
            == .init(text: tenLines, isTruncated: false))
        #expect(ComposerResourceContentPresentation.preview(exact, source: .extension, sourceTruncated: true).isTruncated)
        let prompt = "---\ndescription: A summary\n---\nRead carefully.\nKeep $@ unchanged."
        #expect(ComposerResourceContentPresentation.preview(prompt, source: .prompt, sourceTruncated: false)
            == .init(text: "Read carefully. Keep $@ unchanged.", isTruncated: false))
    }

    @MainActor
    @Test("native attachment menu orders capability-gated skills, prompts, and commands", arguments: [true, false])
    func attachmentMenuResources(commandsAvailable: Bool) {
        let supported = ComposerAttachmentMenuButton(
            isEnabled: true,
            showsSkills: true,
            promptsAvailable: true,
            commandsAvailable: commandsAvailable,
            onSelect: { _ in }
        )
        let supportedActions = ComposerAttachmentMenuButton.Coordinator(parent: supported)
            .makeMenu().children.compactMap { $0 as? UIAction }
        #expect(supportedActions[5].attributes.contains(.disabled) == !commandsAvailable)
        #expect(supportedActions.prefix(5).allSatisfy { !$0.attributes.contains(.disabled) })
        #expect(supportedActions.map(\.title) == ["Take Photo", "Select Photos", "Attach Files", "Add Skills", "Add Prompts", "Add Commands"])

        let legacy = ComposerAttachmentMenuButton(
            isEnabled: true,
            showsSkills: false,
            promptsAvailable: false,
            commandsAvailable: commandsAvailable,
            onSelect: { _ in }
        )
        let legacyActions = ComposerAttachmentMenuButton.Coordinator(parent: legacy)
            .makeMenu().children.compactMap { $0 as? UIAction }
        #expect(!legacyActions.map(\.title).contains("Add Skills"))
        #expect(legacyActions.map(\.title).suffix(2) == ["Add Prompts", "Add Commands"])
        #expect(legacyActions[4].attributes.contains(.disabled) == !commandsAvailable)
        #expect(legacyActions[3].attributes.contains(.disabled))
    }

    @Test("selected resource detail requires exact identity and bounded content")
    func selectedResourceDetailAdmission() throws {
        let command = command("skill:council-mode", source: .skill)
        let detail = CommandResourceDetail(
            name: command.name,
            description: "Council guidance",
            argumentHint: nil,
            source: .skill,
            sourcePath: "/skills/council-mode/SKILL.md",
            resourceSource: "project skills",
            resourceScope: .project,
            resourceOrigin: .topLevel,
            content: "# Council Mode",
            contentBytes: 14,
            contentTruncated: false
        )
        #expect(try CommandResourceDetailPolicy.admit(detail, matching: command) == detail)
        let mismatched = CommandResourceDetail(
            name: "skill:other",
            description: nil,
            argumentHint: nil,
            source: .skill,
            sourcePath: nil,
            resourceSource: nil,
            resourceScope: nil,
            resourceOrigin: nil,
            content: nil,
            contentBytes: nil,
            contentTruncated: nil
        )
        #expect(throws: GatewayFailure.self) {
            try CommandResourceDetailPolicy.admit(mismatched, matching: command)
        }
    }

    @Test("the bounded catalog retains and filters its thousandth entry")
    func boundedCatalog() {
        let commands = (0..<CommandCatalogPolicy.maximumCommands).map {
            command(String(format: "command-%04d", $0), source: .prompt)
        }
        let catalog = ComposerResourceCatalog(commands: commands)
        #expect(catalog.prompts.count == CommandCatalogPolicy.maximumCommands)
        #expect(catalog.entries(kind: .prompt, query: "0999").map(\.displayName) == ["command-0999"])
    }

    @Test("skill and leading command selection can replace one another without losing arguments")
    func mutuallyExclusiveResources() throws {
        let command = try #require(ComposerResourceEntry(command: command("compact", source: .prompt)))
        let removed = ComposerCommandCompletionPolicy.removingLeadingCommand(
            text: "/compact keep these arguments",
            selection: NSRange(location: 12, length: 0),
            commands: [command]
        )
        #expect(removed.text == "keep these arguments")
        #expect(removed.selection.location == 3)
    }

    @Test("completion replaces only the active UTF-16 trigger range")
    func completionRange() throws {
        let text = "👋 hello @rev tail"
        let caret = ("👋 hello @rev" as NSString).length
        let active = try #require(token(text, caret: caret))
        let skill = try #require(ComposerSuggestionTriggerPolicy.replacing(
            text: text,
            range: active.replacementRange,
            with: ""
        ))
        #expect(skill.text == "👋 hello  tail")
        #expect(skill.selection.location == ("👋 hello " as NSString).length)

        let command = try #require(ComposerSuggestionTriggerPolicy.replacing(
            text: "/com existing",
            range: NSRange(location: 0, length: 4),
            with: "/compact "
        ))
        #expect(command.text == "/compact  existing")
        #expect(command.selection == NSRange(location: 9, length: 0))
    }

    private func token(_ text: String, caret: Int) -> ComposerSuggestionToken? {
        ComposerSuggestionTriggerPolicy.activeToken(
            in: text,
            selection: NSRange(location: caret, length: 0)
        )
    }

    private func command(
        _ name: String,
        source: CommandInfo.Source,
        description: String? = nil
    ) -> CommandInfo {
        CommandInfo(
            name: name,
            description: description,
            argumentHint: nil,
            source: source,
            sourcePath: "/resource/\(name)"
        )
    }
}
