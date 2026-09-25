import Testing
@testable import TronMobile

@Suite("Hook inventory presentation")
struct HookInventoryPresentationTests {

    @Test("runtime registrations retain handler counts and truthful provenance")
    func runtimeHandlers() throws {
        let value: JSONValue = .object([
            "extensions": .array([
                .object([
                    "name": .string("package.ts"),
                    "path": .string("/packages/example/package.ts"),
                    "scope": .string("user"),
                    "source": .string("npm:example"),
                    "origin": .string("package"),
                    "handlers": .array([
                        .object(["event": .string("session_start"), "count": .number(2)]),
                        .object(["event": .string("before_agent_start"), "count": .number(1)]),
                    ]),
                ]),
            ]),
            "extensionLoadErrors": .array([
                .object(["path": .string("/broken.ts"), "error": .string("failed to load")]),
            ]),
        ])
        let record = try #require(HookInventoryPresentation.extensions(from: value).first)
        #expect(record.provenance == .user)
        #expect(record.handlerCount == 3)
        #expect(record.handlers.map(\.event) == ["before_agent_start", "session_start"])
        #expect(HookInventoryPresentation.issues(from: value).count == 1)
    }

    @Test("friendly extension names and event grouping preserve unknowns and zero-count supported events")
    func friendlyNamesAndEvents() throws {
        let value: JSONValue = .object([
            "extensions": .array([
                .object(["name": .string("index.ts"), "path": .string("/packages/pi-subagents/dist/index.ts"), "source": .string("npm:pi-subagents"), "scope": .string("user"), "handlers": .array([
                    .object(["event": .string("tool_call"), "count": .number(2)]),
                    .object(["event": .string("future_event"), "count": .number(1)]),
                ])]),
                .object(["name": .string("index.ts"), "path": .string("/project/extensions/index.ts"), "source": .string("project"), "scope": .string("project"), "handlers": .array([
                    .object(["event": .string("tool_call"), "count": .number(1)]),
                ])]),
            ]),
        ])
        let records = HookInventoryPresentation.extensions(from: value)
        #expect(records.first?.friendlyName == "Subagents")
        let reversed = HookInventoryPresentation.extensions(from: .object(["extensions": .array([value.objectValue!["extensions"]!.arrayValue![1], value.objectValue!["extensions"]!.arrayValue![0]])]))
        #expect(Set(records.map(\.id)) == Set(reversed.map(\.id)))
        let events = HookInventoryPresentation.eventRecords(from: records, includeUnregistered: false)
        #expect(events.count == 2)
        #expect(events.first?.descriptor.identifier == "tool_call")
        #expect(events.first?.handlerCount == 3)
        #expect(events.first?.providers.count == 2)
        #expect(events.contains { $0.descriptor.identifier == "future_event" && !$0.descriptor.isSupported })
        let withUnregistered = HookInventoryPresentation.eventRecords(from: records, includeUnregistered: true)
        #expect(withUnregistered.contains { $0.descriptor.identifier == "session_start" && $0.providers.isEmpty })
    }

    @Test("friendly collision labels include provenance and exact source discriminators")
    func collisionLabels() throws {
        let value: JSONValue = .object(["extensions": .array([
            .object(["name": .string("index.ts"), "path": .string("/a/src/index.ts"), "source": .string("npm:shared"), "scope": .string("user")]),
            .object(["name": .string("index.ts"), "path": .string("/b/src/index.ts"), "source": .string("npm:shared"), "scope": .string("user")]),
        ])])
        let records = HookInventoryPresentation.extensions(from: value)
        let labels = HookInventoryPresentation.extensionLabels(for: records)
        #expect(Set(labels.values).count == 2)
        #expect(labels.values.allSatisfy { $0.contains("User") && $0.contains("/src/index.ts") })
    }

    @Test("ordinary resources without hook inventory are unavailable, not empty")
    func missingInventoryIsNotEmpty() {
        #expect(!HookInventoryPresentation.hasInventory(.object(["extensions": .array([])])))
        #expect(HookInventoryPresentation.hasInventory(.object(["hookInventory": .object([:])])) )
    }

    @Test("runtime omission metadata is surfaced instead of presenting a false complete list")
    func omissions() {
        let resources: JSONValue = .object([
            "hookInventory": .object([
                "extensions": .object(["omitted": .number(2)]),
                "handlerEvents": .object(["omitted": .number(3)]),
                "loadErrors": .object(["omitted": .number(1)]),
                "textFieldsOmitted": .number(1),
            ]),
        ])
        let omissions = HookInventoryOmissions(resources: resources)
        #expect(omissions?.hasOmissions == true)
        #expect(omissions?.summary == "2 extensions, 3 handler events, 1 load issue, 1 long metadata field")
    }
}
