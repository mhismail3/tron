import Foundation
import Testing
import UIKit
@testable import TronMobile

@Suite("Composer resource picker")
struct ComposerResourcePickerTests {
    @Test("keyboard-constrained panels yield space to the existing composer")
    func keyboardConstrainedPanel() {
        #expect(ComposerResourcePanelPolicy.visibleRows(entryCount: 12, keyboardVisible: false) == 5)
        #expect(ComposerResourcePanelPolicy.visibleRows(entryCount: 12, keyboardVisible: true) == 3)
        #expect(ComposerResourcePanelPolicy.visibleRows(entryCount: 2, keyboardVisible: true) == 2)
        #expect(ComposerResourcePanelPolicy.visibleRows(entryCount: -1, keyboardVisible: true) == 0)
        #expect(ComposerResourcePanelPolicy.editorLines(
            panelPresented: true,
            keyboardVisible: true
        ) == 4)
        #expect(ComposerResourcePanelPolicy.editorLines(
            panelPresented: false,
            keyboardVisible: true
        ) == 8)
        #expect(ComposerResourcePanelPolicy.editorLines(
            panelPresented: true,
            keyboardVisible: false
        ) == 8)
    }

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

    @Test("deleting a trigger removes the active token")
    func deletionDismissal() {
        #expect(token("@r", caret: 2) != nil)
        #expect(token("", caret: 0) == nil)
        #expect(token("/", caret: 1) != nil)
        #expect(token("plain", caret: 5) == nil)
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
        #expect(catalog.commands.map(\.displayName) == ["review-template", "skill:repair", "zeta"])
        #expect(catalog.entries(kind: .skill, query: "rev").map(\.displayName) == ["review"])
        #expect(catalog.entries(kind: .command, query: "review").map(\.displayName) == ["review-template", "zeta"])
        #expect(catalog.exactSkill(named: "review")?.invocationName == "skill:review")
    }

    @MainActor
    @Test("native attachment menu exposes commands and capability-gated skills")
    func attachmentMenuResources() {
        let supported = ComposerAttachmentMenuButton(
            isEnabled: true,
            showsSkills: true,
            onSelect: { _ in }
        )
        let supportedTitles = ComposerAttachmentMenuButton.Coordinator(parent: supported)
            .makeMenu().children.compactMap { ($0 as? UIAction)?.title }
        #expect(supportedTitles == ["Take Photo", "Select Photos", "Attach Files", "Skills", "Commands"])

        let legacy = ComposerAttachmentMenuButton(
            isEnabled: true,
            showsSkills: false,
            onSelect: { _ in }
        )
        let legacyTitles = ComposerAttachmentMenuButton.Coordinator(parent: legacy)
            .makeMenu().children.compactMap { ($0 as? UIAction)?.title }
        #expect(!legacyTitles.contains("Skills"))
        #expect(legacyTitles.last == "Commands")
    }

    @Test("the bounded catalog retains and filters its thousandth entry")
    func boundedCatalog() {
        let commands = (0..<CommandCatalogPolicy.maximumCommands).map {
            command(String(format: "command-%04d", $0), source: .prompt)
        }
        let catalog = ComposerResourceCatalog(commands: commands)
        #expect(catalog.commands.count == CommandCatalogPolicy.maximumCommands)
        #expect(catalog.entries(kind: .command, query: "0999").map(\.displayName) == ["command-0999"])
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
