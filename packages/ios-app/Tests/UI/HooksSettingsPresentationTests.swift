import Testing
@testable import TronMobile

/// Failure modes this suite targets, from the R-0 audit of the resources
/// organization: a `hooks.list` response decoded by a different presentation
/// than `session.resources`, so the Settings sheet and a live session disagree;
/// the Settings move dropping an item of today's hooks view (either projection,
/// the unregistered-events toggle, the extension detail, lifecycle events, load
/// issues, the bounded-omissions notice, the empty state); a project read
/// launched for the wrong scope or on a Gateway that cannot answer
/// `hooks.list`; and the untrusted-project note claimed without a resolved
/// blocked project, so a global-only answer reads as an empty project.
@Suite("Hooks settings sheet")
struct HooksSettingsPresentationTests {

    /// Exactly the fields `hooks.list` returns, the same ones `session.resources`
    /// carries. The handler-less extension is intentional: it registers a tool
    /// and a command but no hooks, and must stay listed.
    private var hookFields: [String: JSONValue] {
        [
            "extensions": .array([
                .object([
                    "name": .string("tron-notify"),
                    "path": .string("<inline:tron-notify>"),
                    "resolvedPath": .string("<inline:tron-notify>"),
                    "scope": .string("temporary"),
                    "source": .string("inline"),
                    "origin": .string("top-level"),
                    "tools": .array([.string("notify")]),
                    "commands": .array([]),
                    "handlers": .array([
                        .object(["event": .string("agent_end"), "count": .number(1)]),
                        .object(["event": .string("tool_call"), "count": .number(2)]),
                    ]),
                ]),
                .object([
                    "name": .string("local-tools.ts"),
                    "path": .string("/project/.pi/extensions/local-tools.ts"),
                    "resolvedPath": .string("/project/.pi/extensions/local-tools.ts"),
                    "scope": .string("project"),
                    "source": .string("local"),
                    "origin": .string("top-level"),
                    "tools": .array([.string("echo")]),
                    "commands": .array([.string("echo")]),
                    "handlers": .array([]),
                ]),
            ]),
            "extensionLoadErrors": .array([
                .object(["path": .string("/broken.ts"), "error": .string("failed to load")]),
            ]),
            "hookInventory": .object([
                "extensions": .object(["total": .number(3), "retained": .number(2), "omitted": .number(1)]),
                "handlerEvents": .object(["total": .number(2), "retained": .number(2), "omitted": .number(0)]),
                "loadErrors": .object(["total": .number(1), "retained": .number(1), "omitted": .number(0)]),
                "textFieldsOmitted": .number(0),
                "encodedBytes": .number(1_024),
                "encodedBytesLimit": .number(262_144),
            ]),
        ]
    }

    private var listResponse: JSONValue { .object(hookFields) }

    private var sessionResources: JSONValue {
        .object(hookFields.merging([
            "tools": .array([]),
            "skills": .object(["skills": .array([]), "diagnostics": .array([])]),
            "prompts": .object(["prompts": .array([]), "diagnostics": .array([])]),
            "subagents": .array([]),
        ]) { _, hooks in hooks })
    }

    @Test("a hooks.list response decodes into the same inventory as session.resources")
    func listAndSessionAgree() {
        for mode in HookViewMode.allCases {
            let fromList = HooksSettingsPresentation.content(from: listResponse, mode: mode, showsUnregisteredEvents: false)
            let fromSession = HooksSettingsPresentation.content(from: sessionResources, mode: mode, showsUnregisteredEvents: false)
            #expect(fromList.sections == fromSession.sections)
            #expect(fromList.extensionRows == fromSession.extensionRows)
            #expect(fromList.issues == fromSession.issues)
            #expect(fromList.omissions == fromSession.omissions)
            #expect(fromList.events.map(\.descriptor.identifier) == fromSession.events.map(\.descriptor.identifier))
            #expect(fromList.handlerCount == fromSession.handlerCount)
        }
        // Provenance, load issues and omission metadata survive the decode.
        let content = HooksSettingsPresentation.content(from: listResponse, mode: .byExtension, showsUnregisteredEvents: false)
        #expect(content.handlerCount == 3)
        #expect(content.extensionRows.map(\.label) == ["Tron Notifications", "Local Tools"])
        #expect(content.extensionRows.last?.record.handlers.isEmpty == true)
        #expect(content.extensionRows.last?.record.provenance == .project)
        #expect(content.issues.map(\.path) == ["/broken.ts"])
        #expect(content.omissions?.summary == "1 extension")
    }

    @Test("the sheet's sections carry every item the R-0 audit mapped")
    func itemMap() {
        let byEvent = HooksSettingsPresentation.content(from: listResponse, mode: .byEvent, showsUnregisteredEvents: false)
        #expect(byEvent.sections == [.omissionsNotice, .viewMode, .unregisteredEvents, .lifecycleEvents, .loadIssues, .caption])
        let byExtension = HooksSettingsPresentation.content(from: listResponse, mode: .byExtension, showsUnregisteredEvents: false)
        #expect(byExtension.sections == [.omissionsNotice, .viewMode, .registeredExtensions, .loadIssues, .caption])
        // The two projections together reach every section the surface owns.
        #expect(Set(byEvent.sections + byExtension.sections) == Set([
            .omissionsNotice, .viewMode, .unregisteredEvents, .registeredExtensions,
            .lifecycleEvents, .loadIssues, .caption,
        ]))
    }

    @Test("an unanswered read is unavailable, and an empty inventory is its own state")
    func emptyAndUnavailable() {
        for projection in [nil, JSONValue.object(["extensions": .array([])]), JSONValue.object([:])] {
            #expect(HooksSettingsPresentation.content(from: projection, mode: .byEvent, showsUnregisteredEvents: false).sections.isEmpty)
        }
        let emptyInventory: JSONValue = .object([
            "extensions": .array([]),
            "extensionLoadErrors": .array([]),
            "hookInventory": .object([:]),
        ])
        let byEvent = HooksSettingsPresentation.content(from: emptyInventory, mode: .byEvent, showsUnregisteredEvents: false)
        #expect(byEvent.sections == [.viewMode, .unregisteredEvents, .emptyPlaceholder, .caption])
        #expect(HooksSettingsPresentation.content(from: emptyInventory, mode: .byExtension, showsUnregisteredEvents: false).sections == [.viewMode, .emptyPlaceholder, .caption])
        // Showing unregistered events replaces the empty state with the catalogue.
        let catalogue = HooksSettingsPresentation.content(from: emptyInventory, mode: .byEvent, showsUnregisteredEvents: true)
        #expect(!catalogue.sections.contains(.emptyPlaceholder))
        #expect(catalogue.sections.contains(.lifecycleEvents))
        #expect(!catalogue.events.isEmpty)
    }

    @Test("one hooks.list request per scope, and none without the capability")
    func requestFrames() throws {
        let everyProject = try #require(HooksListRequest.make(scope: .global, projectCWD: "/project", capabilities: ["sessions.v1", "hooks.v1"]))
        #expect(try JSONValue.encode(everyProject.params).objectValue?["cwd"] == nil)
        let currentProject = try #require(HooksListRequest.make(scope: .project, projectCWD: "/project", capabilities: ["sessions.v1", "hooks.v1"]))
        #expect(try JSONValue.encode(currentProject.params).objectValue?["cwd"]?.stringValue == "/project")
        // Current Project without a project path stays the global scope.
        #expect(HooksListRequest.make(scope: .project, projectCWD: nil, capabilities: ["hooks.v1"])?.cwd == nil)
        #expect(HooksListRequest.make(scope: .project, projectCWD: "", capabilities: ["hooks.v1"])?.cwd == nil)
        // A Gateway that does not advertise hooks.v1 is never asked.
        #expect(HooksListRequest.make(scope: .global, projectCWD: "/project", capabilities: []) == nil)
        #expect(HooksListRequest.make(scope: .project, projectCWD: "/project", capabilities: ["sessions.v1", "modules.v1"]) == nil)
    }

    @Test("the untrusted-project note needs a resolved project that is not trusted")
    func untrustedNote() {
        let trusted = ProjectTrustSummary(.object([
            "cwd": .string("/project"),
            "requiresDecision": .bool(true),
            "savedDecision": .bool(true),
            "defaultDecision": .string("ask"),
            "effectiveDecision": .bool(true),
        ]))
        let blocked = ProjectTrustSummary(.object([
            "cwd": .string("/project"),
            "requiresDecision": .bool(true),
            "savedDecision": .bool(false),
            "defaultDecision": .string("ask"),
            "effectiveDecision": .bool(false),
        ]))
        let undecided = ProjectTrustSummary(.object([
            "cwd": .string("/project"),
            "requiresDecision": .bool(true),
            "savedDecision": .null,
            "defaultDecision": .string("ask"),
            "effectiveDecision": .null,
        ]))
        #expect(HooksProjectTrustNote.isRequired(projectCWD: "/project", trust: trusted) == false)
        #expect(HooksProjectTrustNote.isRequired(projectCWD: "/project", trust: blocked))
        #expect(HooksProjectTrustNote.isRequired(projectCWD: "/project", trust: undecided))
        // An unread trust state never claims a project state, and no project
        // path means there is no project scope to explain.
        #expect(HooksProjectTrustNote.isRequired(projectCWD: "/project", trust: nil) == false)
        #expect(HooksProjectTrustNote.isRequired(projectCWD: nil, trust: blocked) == false)
        #expect(HooksProjectTrustNote.isRequired(projectCWD: "", trust: blocked) == false)
    }
}
