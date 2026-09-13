import Foundation
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Composer resource picker")
struct ComposerResourcePickerTests {
    @Test("composer blur geometry reserves the measured header for both resource kinds")
    func composerBlurGeometry() {
        #expect(ComposerResourcePanelPolicy.blurFadeLength == 52)
        for headerHeight in [CGFloat(44), 72] {
            #expect(ComposerResourcePanelPolicy.viewportHeight(
                entryCount: 8,
                keyboardVisible: false,
                headerHeight: headerHeight
            ) == headerHeight + 5 * ComposerResourcePanelPolicy.rowHeight)
            #expect(headerHeight + ComposerResourcePanelPolicy.blurFadeLength > headerHeight)
        }
        #expect(ComposerResourcePanelPolicy.viewportHeight(
            entryCount: 8,
            keyboardVisible: true,
            headerHeight: 48
        ) == 48 + 3 * ComposerResourcePanelPolicy.rowHeight)
        #expect(ComposerResourcePanelPolicy.viewportHeight(
            entryCount: 8,
            keyboardVisible: false,
            headerHeight: -1
        ) == 5 * ComposerResourcePanelPolicy.rowHeight)
    }

    @MainActor
    @Test("commands and skills keep the first row clear and scroll beneath the header blur")
    func hostedPickerHeaderAndRowGeometry() async throws {
        for kind in [ComposerResourceEntry.Kind.command, .skill] {
            let source: CommandInfo.Source = kind == .skill ? .skill : .prompt
            let entries = (0..<8).compactMap {
                ComposerResourceEntry(command: command(
                    kind == .skill ? "skill:\(kind)-\($0)" : "\(kind)-\($0)",
                    source: source,
                    description: "Description"
                ))
            }
            let picker = ComposerResourcePicker(
                sessionID: nil,
                kind: kind,
                query: kind == .skill ? "review" : "compact",
                entries: entries,
                keyboardVisible: false,
                onSelect: { _ in },
                onDismiss: {}
            )
            let host = UIHostingController(rootView: picker.frame(width: 360))
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 420)
            let window = UIWindow(frame: host.view.bounds)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }

            host.view.layoutIfNeeded()
            for _ in 0..<3 { await Task.yield() }
            host.view.layoutIfNeeded()

            let pickerScrollView = try #require(scrollView(in: host.view))
            let restOffset = pickerScrollView.contentOffset.y
            let topInset = pickerScrollView.adjustedContentInset.top
            #expect(topInset > 0)
            #expect(abs(restOffset + topInset) < 1)
            #expect(pickerScrollView.contentSize.height > pickerScrollView.bounds.height)

            pickerScrollView.setContentOffset(CGPoint(x: 0, y: restOffset + 24), animated: false)
            host.view.layoutIfNeeded()
            #expect(pickerScrollView.contentOffset.y > restOffset)

            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let screenshotURL = URL(fileURLWithPath: "/tmp/tron-composer-picker-\(kind == .skill ? "skills" : "commands").png")
            if let pngData = image.pngData() {
                try pngData.write(to: screenshotURL)
            }
        }
    }

    @MainActor
    @Test("commands and skills clip the blur at rounded corners for empty and short panels")
    func hostedPickerBlurCornerClipping() async throws {
        let background = [0.93, 0.04, 0.08]
        for kind in [ComposerResourceEntry.Kind.command, .skill] {
            for scheme in [ColorScheme.light, .dark] {
                for variant in ["empty", "short"] {
                    let source: CommandInfo.Source = kind == .skill ? .skill : .prompt
                    let entries: [ComposerResourceEntry] = variant == "empty"
                        ? []
                        : [ComposerResourceEntry(command: command(
                            kind == .skill ? "skill:short" : "short",
                            source: source,
                            description: "Short description"
                        ))].compactMap { $0 }
                    let picker = ComposerResourcePicker(
                        sessionID: nil,
                        kind: kind,
                        query: "",
                        entries: entries,
                        keyboardVisible: false,
                        onSelect: { _ in },
                        onDismiss: {}
                    )
                    .environment(\.colorScheme, scheme)
                    let root = ZStack(alignment: .top) {
                        Color(red: background[0], green: background[1], blue: background[2])
                        picker.frame(width: 360, alignment: .top)
                    }
                    .frame(width: 390, height: 220, alignment: .top)
                    let host = UIHostingController(rootView: root)
                    host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
                    host.view.backgroundColor = UIColor(red: background[0], green: background[1], blue: background[2], alpha: 1)
                    host.view.isOpaque = true
                    host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
                    let window = UIWindow(frame: host.view.bounds)
                    window.rootViewController = host
                    window.makeKeyAndVisible()

                    host.view.layoutIfNeeded()
                    for _ in 0..<3 { await Task.yield() }
                    host.view.layoutIfNeeded()
                    let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                    }
                    window.isHidden = true
                    window.rootViewController = nil
                    let name = kind == .skill ? "skills" : "commands"
                    let suffix = scheme == .dark ? "dark" : "light"
                    let screenshotURL = URL(fileURLWithPath: "/tmp/tron-composer-picker-\(name)-\(variant)-\(suffix).png")
                    if let pngData = image.pngData() {
                        try pngData.write(to: screenshotURL)
                    }

                    // The picker is 360 points wide inside the 390-point host,
                    // so x=15 is its leading edge. Find its top from the actual
                    // rendered transition rather than assuming a window inset.
                    let panelTop = try firstPaintedY(image, background: background)
                    let outside = try pixel(image, x: 1, y: panelTop + 1)
                    let corner = try pixel(image, x: 16, y: panelTop + 1)
                    let interior = try pixel(image, x: 200, y: panelTop + 1)
                    #expect(colorDistance(corner, outside) < 0.12)
                    #expect(colorDistance(interior, outside) > 0.2)
                }
            }
        }
    }

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
        #expect(catalog.commands.map(\.displayName) == ["review-template", "skill:repair", "zeta"])
        #expect(catalog.skills.map(\.friendlyName) == ["Review"])
        #expect(catalog.commands.map(\.friendlyName) == ["Review Template", "Skill Repair", "Zeta"])
        #expect(catalog.entries(kind: .skill, query: "rev").map(\.displayName) == ["review"])
        #expect(catalog.entries(kind: .command, query: "review").map(\.displayName) == ["review-template", "zeta"])
        #expect(catalog.exactSkill(named: "review")?.invocationName == "skill:review")
    }

    @Test("resource names become user-facing titles without changing invocation identity")
    func friendlyNames() {
        #expect(ComposerResourceNameFormatter.friendly("council-mode") == "Council Mode")
        #expect(ComposerResourceNameFormatter.friendly("pi-subagents") == "Pi Subagents")
        #expect(ComposerResourceNameFormatter.friendly("inspectJSONPayload") == "Inspect JSON Payload")
        #expect(ComposerResourceNameFormatter.friendly("ios_sdk") == "iOS SDK")
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
        #expect(CanonicalResourceChipPresentation.tone(for: prompt) == .purple)
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
    @Test("native attachment menu exposes commands and capability-gated skills", arguments: [true, false])
    func attachmentMenuResources(commandsAvailable: Bool) {
        let supported = ComposerAttachmentMenuButton(
            isEnabled: true,
            showsSkills: true,
            commandsAvailable: commandsAvailable,
            onSelect: { _ in }
        )
        let supportedActions = ComposerAttachmentMenuButton.Coordinator(parent: supported)
            .makeMenu().children.compactMap { $0 as? UIAction }
        #expect(supportedActions.last?.attributes.contains(.disabled) == !commandsAvailable)
        #expect(supportedActions.dropLast().allSatisfy { !$0.attributes.contains(.disabled) })
        #expect(supportedActions.map(\.title) == ["Take Photo", "Select Photos", "Attach Files", "Add Skills", "Add Commands"])

        let legacy = ComposerAttachmentMenuButton(
            isEnabled: true,
            showsSkills: false,
            commandsAvailable: commandsAvailable,
            onSelect: { _ in }
        )
        let legacyActions = ComposerAttachmentMenuButton.Coordinator(parent: legacy)
            .makeMenu().children.compactMap { $0 as? UIAction }
        #expect(!legacyActions.map(\.title).contains("Add Skills"))
        #expect(legacyActions.last?.title == "Add Commands")
        #expect(legacyActions.last?.attributes.contains(.disabled) == !commandsAvailable)
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

    @MainActor
    private func scrollView(in root: UIView) -> UIScrollView? {
        if let scrollView = root as? UIScrollView { return scrollView }
        for child in root.subviews {
            if let match = scrollView(in: child) { return match }
        }
        return nil
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> [Double] {
        let bitmap = try #require(image.cgImage)
        let pixelX = min(max(Int(x * image.scale), 0), bitmap.width - 1)
        let pixelY = min(max(Int(y * image.scale), 0), bitmap.height - 1)
        let point = try #require(bitmap.cropping(to: CGRect(x: pixelX, y: pixelY, width: 1, height: 1)))
        var values = [UInt8](repeating: 0, count: 4)
        values.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(point, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return values.prefix(3).map { Double($0) / 255 }
    }

    private func colorDistance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { partial, pair in
            partial + (pair.0 - pair.1) * (pair.0 - pair.1)
        }.squareRoot()
    }

    private func firstPaintedY(_ image: UIImage, background: [Double]) throws -> CGFloat {
        for y in 0..<220 {
            if colorDistance(try pixel(image, x: 200, y: CGFloat(y)), background) > 0.12 {
                return CGFloat(y)
            }
        }
        throw CocoaError(.fileReadCorruptFile)
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
