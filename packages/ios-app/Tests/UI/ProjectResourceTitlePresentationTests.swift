import Testing
@testable import TronMobile

@Suite("Friendly project resource titles")
struct ProjectResourceTitlePresentationTests {
    @Test("extensions resolve package names instead of generic entrypoint filenames")
    func packageExtensions() {
        let fixtures: [(String, String, String)] = [
            ("npm:pi-subagents@0.59.0", "/packages/pi-subagents/index.ts", "Subagents"),
            ("npm:@scope/pi-ask-user@7.0.15", "/packages/pi-ask-user/dist/index.js", "Ask User"),
            ("npm:@scope/custom-tools@1.2.3", "/packages/custom-tools/extensions/search.ts", "Custom Tools · Search"),
            ("npm:@scope/custom-tools", "/packages/custom-tools/extensions/review/index.ts", "Custom Tools · Review"),
            ("git:github.com/example/pi-agent-browser-native@abc123", "/packages/pi-agent-browser-native/index.js", "Agent Browser Native"),
            ("git:github.com/example/my-tools@feature/topic", "/packages/my-tools/src/index.ts", "My Tools"),
            ("git:git@github.com:example/my-tools.git@v1", "/packages/my-tools/index.ts", "My Tools"),
            ("https://github.com/example/my-tools.git", "/packages/my-tools/index.js", "My Tools"),
        ]
        for (source, path, expected) in fixtures {
            #expect(ProjectResourceTitlePresentation.extensionTitle(name: "index.ts", object: [
                "name": .string("index.ts"), "source": .string(source), "path": .string(path),
            ]) == expected)
        }
    }

    @Test("inline and local extension names are readable without rewriting their source")
    func inlineAndLocalExtensions() {
        for (path, expected) in [
            ("<inline:tron-context-window>", "Tron Context Window"),
            ("<inline:tron-core>", "Tron Core"),
            ("<inline:tron-display>", "Tron Display"),
            ("<inline:tron-schedule>", "Tron Automations"),
            ("<inline:tron-notify>", "Tron Notifications"),
            ("<inline:1>", "Extension 1"),
            ("/project/extensions/my-extension/index.ts", "My Extension"),
            ("/project/extensions/review.ts", "Review"),
        ] {
            #expect(ProjectResourceTitlePresentation.extensionTitle(name: nil, object: [
                "path": .string(path), "source": .string("inline"),
            ]) == expected)
        }
    }

    @Test("tools prefer authored labels and preserve exact invocation names")
    func toolNames() {
        let authored: JSONValue = .object(["name": .string("project_echo"), "label": .string("Project echo")])
        #expect(ProjectResourceTitlePresentation.title(kind: .tools, value: authored) == "Project echo")
        for (name, title) in [("read", "Read File"), ("bash", "Run Shell Command"), ("ls", "List Files"), ("inspectJSONPayload", "Inspect JSON Payload"), ("web_search", "Web Search")] {
            let value: JSONValue = .object(["name": .string(name)])
            #expect(ProjectResourceTitlePresentation.title(kind: .tools, value: value) == title)
            #expect(ProjectResourceDetailPresentation(kind: .tools, value: value).invocation == name)
        }
    }

    @Test("skills and prompts share the composer formatter but not formatted identifiers")
    func skillsAndPrompts() {
        for kind in [ProjectResourceKind.skills, .prompts] {
            for (name, title) in [("test-suite-audit", "Test Suite Audit"), ("release_notes", "Release Notes"), ("ios_sdk", "iOS SDK")] {
                let value: JSONValue = .object(["name": .string(name)])
                #expect(ProjectResourceTitlePresentation.title(kind: kind, value: value) == title)
                if kind == .prompts {
                    #expect(ProjectResourceDetailPresentation(kind: kind, value: value).invocation == "/\(name)")
                }
                #expect(value.objectValue?["name"]?.stringValue == name)
            }
        }
    }
}
