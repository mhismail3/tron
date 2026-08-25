import Foundation
import Testing
@testable import TronMobile

@Suite("Gateway protocol fixtures")
struct GatewayProtocolContractTests {
    @Test("authoritative session snapshot decodes")
    func snapshotDecodes() throws {
        let data = Data(#"""
        {
          "sessionId":"session-1","runtimeGeneration":"generation-1","revision":8,"eventSequence":21,"phase":"running","cwd":"/workspace",
          "model":{"provider":"anthropic","id":"model"},"thinkingLevel":"high",
          "availableThinkingLevels":["off","high"],
          "contextUsage":{"tokens":120,"contextWindow":1000,"percent":12},
          "stats":{"userMessages":1,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":1,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"latestCacheHitRate":99.7,"cost":0},
          "queued":{"steering":[],"followUp":["later"]},
          "queueRevision":4,
          "queuedItems":[{"id":"queued-1","behavior":"followUp","text":"later","attachmentCount":2}],
          "pendingPrompt":{"id":"prompt-1","createdAt":"2026-01-01T00:00:02Z","behavior":"steer","text":"waiting","attachmentCount":1},
          "compactionQueued":true,"automaticCompactionEnabled":false,
          "transcript":[
            {"id":"entry-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","presentationId":"entry-1","content":[{"id":"entry-1:0","ordinal":0,"type":"text","text":"hello"},{"id":"entry-1:1","ordinal":1,"type":"text","text":"notes.pdf","attachment":{"name":"notes.pdf","mimeType":"application/pdf","size":2048}}]},
            {"id":"entry-2","parentId":"entry-1","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai","id":"next"}}
          ],"transcriptStart":10,"transcriptTotal":12,
          "leafEntryId":"entry-2","toolExecutions":[],
          "extensionPresentation":{"version":2,"hostEpoch":"host","revision":0,"capabilities":[],"diagnostics":[],"semanticState":{"statuses":{},"working":{"visible":true},"widgets":[],"toolsExpanded":false,"editorRevision":0,"editorText":""},"surfaces":[],"pendingInteractions":[]},
          "diagnostics":[]
        }
        """#.utf8)
        let snapshot = try JSONDecoder.gateway.decode(SessionSnapshot.self, from: data)
        #expect(snapshot.sessionId == "session-1")
        #expect(snapshot.model == ModelRef(provider: "anthropic", id: "model"))
        #expect(snapshot.transcript.first?.text == "hello")
        #expect(snapshot.transcript.last?.modelRef == ModelRef(provider: "openai", id: "next"))
        #expect(snapshot.transcript.first?.presentationId == "entry-1")
        #expect(snapshot.transcript.first?.content?.first?.id == "entry-1:0")
        #expect(snapshot.transcript.first?.content?.first?.ordinal == 0)
        #expect(snapshot.transcript.first?.content?.last?.type == .text)
        #expect(snapshot.transcript.first?.content?.last?.attachment?.name == "notes.pdf")
        #expect(snapshot.transcript.first?.content?.last?.attachment?.size == 2048)
        #expect(snapshot.transcriptStart == 10)
        #expect(snapshot.transcriptTotal == 12)
        #expect(snapshot.stats.latestCacheHitRate == 99.7)
        #expect(snapshot.queueRevision == 4)
        #expect(snapshot.pendingPrompt == SessionSnapshot.PendingPrompt(
            id: "prompt-1", createdAt: "2026-01-01T00:00:02Z", behavior: .steer,
            text: "waiting", attachmentCount: 1
        ))
        #expect(snapshot.compactionQueued == true)
        #expect(snapshot.automaticCompactionEnabled == false)
        #expect(snapshot.displayedQueuedMessages == [SessionSnapshot.QueuedMessage(
            id: "queued-1",
            behavior: .followUp,
            text: "later",
            attachmentCount: 2
        )])

        var legacyObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacyObject.removeValue(forKey: "compactionQueued")
        legacyObject.removeValue(forKey: "automaticCompactionEnabled")
        let legacy = try JSONDecoder.gateway.decode(
            SessionSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        #expect(legacy.compactionQueued == nil)
        #expect(legacy.automaticCompactionEnabled == nil)
    }

    @Test("message presentation identity and content ordinals are required")
    func transcriptIdentityIsRequired() throws {
        let valid: [String: Any] = [
            "id": "assistant", "parentId": NSNull(),
            "timestamp": "2026-01-01T00:00:00Z", "kind": "message", "role": "assistant",
            "presentationId": "stream:turn",
            "content": [[
                "id": "stream:turn:0", "ordinal": 0, "thinkingRunOrdinal": 0,
                "type": "thinking", "text": "working",
            ]],
        ]
        func decode(_ object: [String: Any]) throws {
            _ = try JSONDecoder.gateway.decode(
                TranscriptItem.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        try decode(valid)

        var missingPresentation = valid
        missingPresentation.removeValue(forKey: "presentationId")
        #expect(throws: DecodingError.self) { try decode(missingPresentation) }

        var emptyPresentation = valid
        emptyPresentation["presentationId"] = ""
        #expect(throws: DecodingError.self) { try decode(emptyPresentation) }

        var missingOrdinal = valid
        var missingOrdinalContent = try #require(missingOrdinal["content"] as? [[String: Any]])
        missingOrdinalContent[0].removeValue(forKey: "ordinal")
        missingOrdinal["content"] = missingOrdinalContent
        #expect(throws: DecodingError.self) { try decode(missingOrdinal) }

        var duplicateOrdinal = valid
        var duplicateOrdinalContent = try #require(duplicateOrdinal["content"] as? [[String: Any]])
        duplicateOrdinalContent.append([
            "id": "stream:turn:duplicate", "ordinal": 0,
            "type": "text", "text": "duplicate",
        ])
        duplicateOrdinal["content"] = duplicateOrdinalContent
        #expect(throws: DecodingError.self) { try decode(duplicateOrdinal) }

        var missingThinkingRun = valid
        var missingThinkingContent = try #require(missingThinkingRun["content"] as? [[String: Any]])
        missingThinkingContent[0].removeValue(forKey: "thinkingRunOrdinal")
        missingThinkingRun["content"] = missingThinkingContent
        #expect(throws: DecodingError.self) { try decode(missingThinkingRun) }
    }

    @Test("finalized tool invocation groups are complete and contiguous")
    func finalizedToolGroupsValidate() throws {
        let valid: [String: Any] = [
            "id": "assistant", "parentId": NSNull(),
            "timestamp": "2026-01-01T00:00:00Z", "kind": "message", "role": "assistant",
            "presentationId": "stream:turn",
            "content": [
                ["id": "stream:turn:0", "ordinal": 0, "type": "toolCall", "toolCallId": "a", "name": "read", "arguments": [:], "groupId": "stream:turn:tool-group:0", "groupIndex": 0, "groupCount": 2, "groupFinalized": true],
                ["id": "stream:turn:1", "ordinal": 1, "type": "toolCall", "toolCallId": "b", "name": "bash", "arguments": [:], "groupId": "stream:turn:tool-group:0", "groupIndex": 1, "groupCount": 2, "groupFinalized": true],
            ],
        ]
        func decode(_ object: [String: Any]) throws {
            _ = try JSONDecoder.gateway.decode(
                TranscriptItem.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        try decode(valid)

        var incomplete = valid
        var incompleteContent = try #require(incomplete["content"] as? [[String: Any]])
        incompleteContent[0].removeValue(forKey: "groupCount")
        incomplete["content"] = incompleteContent
        #expect(throws: DecodingError.self) { try decode(incomplete) }

        var duplicateIndex = valid
        var duplicateContent = try #require(duplicateIndex["content"] as? [[String: Any]])
        duplicateContent[1]["groupIndex"] = 0
        duplicateIndex["content"] = duplicateContent
        #expect(throws: DecodingError.self) { try decode(duplicateIndex) }

        var conflictingCount = valid
        var conflictingContent = try #require(conflictingCount["content"] as? [[String: Any]])
        conflictingContent[1]["groupCount"] = 3
        conflictingCount["content"] = conflictingContent
        #expect(throws: DecodingError.self) { try decode(conflictingCount) }
    }

    @Test("typed and JSONValue adapters have parity across prepared topics")
    func preparedTopicParityMatrix() throws {
        let topics = [
            "session.summary", "session.snapshot", "session.rebaseline", "session.progress",
            "session.toolProgress", "session.extensionActivity", "session.extensionPresentation",
            "terminal.output", "terminal.exit"
        ]
        for topic in topics {
            let payload: JSONValue = .object(["malformed": .bool(true)])
            let synthetic = GatewayEvent(type: "event", topic: topic, sessionId: "session", payload: payload)
            let frame: JSONValue = .object([
                "type": .string("event"), "topic": .string(topic), "sessionId": .string("session"),
                "payload": payload
            ])
            let network = try JSONDecoder.gateway.decode(
                GatewayInboundFrame.self,
                from: try JSONEncoder.gateway.encode(frame)
            )
            guard case .event(let decoded) = network else {
                Issue.record("event frame did not decode for \\(topic)")
                continue
            }
            #expect(decoded.preparation == synthetic.preparation, "adapter parity for \\(topic)")
        }
    }

    @Test("input lease decoding preserves omitted, null, value, and malformed states")
    func inputLeaseTriState() throws {
        func decode(_ lease: String?) throws -> ExtensionPresentationMutation {
            let suffix = lease.map { ",\"inputLease\":\($0)" } ?? ""
            return try JSONDecoder.gateway.decode(
                ExtensionPresentationMutation.self,
                from: Data("{\"version\":2,\"hostEpoch\":\"host\",\"revision\":1\(suffix)}".utf8)
            )
        }
        let absent = try decode(nil)
        #expect(!absent.inputLeasePresent)
        #expect(absent.inputLease == nil)
        let cleared = try decode("null")
        #expect(cleared.inputLeasePresent)
        #expect(cleared.inputLease == .null)
        let value = try decode("{\"id\":\"lease\"}")
        #expect(value.inputLeasePresent)
        #expect(value.inputLease?.objectValue?["id"] == .string("lease"))
        #expect(throws: DecodingError.self) { try decode("[") }

        func policy(_ lease: String) throws -> ExtensionPresentationMutation {
            let data = Data("{\"version\":2,\"hostEpoch\":\"host\",\"revision\":1,\"inputLease\":\(lease)}".utf8)
            return try JSONDecoder.gateway.decode(ExtensionPresentationMutation.self, from: data)
        }
        #expect(ExtensionPresentationPolicy.admit(try policy("null")))
        #expect(!ExtensionPresentationPolicy.admit(try policy(#"{"id":"","connectionId":"connection","surfaceId":"surface","surfaceRevision":1,"acquiredAt":"2026-01-01T00:00:00Z"}"#)))
        #expect(!ExtensionPresentationPolicy.admit(try policy(#"{"id":"lease","connectionId":"connection","surfaceId":"surface","surfaceRevision":0,"acquiredAt":"2026-01-01T00:00:00Z"}"#)))
        #expect(!ExtensionPresentationPolicy.admit(try policy(#"{"id":"lease","connectionId":"connection","surfaceId":"surface","surfaceRevision":1,"acquiredAt":"not-a-time"}"#)))
    }

    @Test("dashboard summary update carries a monotonic revision")
    func summaryUpdateDecodes() throws {
        let data = Data(#"{"sessionId":"session-1","summaryRevision":7,"phase":"running","updatedAt":"2026-01-01T00:00:01Z","messageCount":2,"firstMessage":"hello","completionRevision":3,"attentionRevision":4,"isUnread":true}"#.utf8)
        let update = try JSONDecoder.gateway.decode(SessionSummaryUpdate.self, from: data)
        #expect(update.summaryRevision == 7)
        #expect(update.phase == .running)
        #expect(update.completionRevision == 3)
        #expect(update.attentionRevision == 4)
        #expect(update.isUnread)

        let rolling = try JSONDecoder.gateway.decode(
            SessionSummaryUpdate.self,
            from: Data(#"{"sessionId":"session-1","summaryRevision":6,"phase":"idle","updatedAt":"2026-01-01T00:00:00Z","messageCount":1,"firstMessage":"hello"}"#.utf8)
        )
        #expect(rolling.completionRevision == 0)
        #expect(!rolling.isUnread)
    }

    @Test("dashboard attention revisions reject negative wire values")
    func negativeAttentionRevisionsReject() throws {
        let summaryBase = #"{"id":"session-1","cwd":"/workspace","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:01Z","messageCount":2,"firstMessage":"hello","phase":"idle""#
        let updateBase = #"{"sessionId":"session-1","summaryRevision":7,"phase":"idle","updatedAt":"2026-01-01T00:00:01Z","messageCount":2,"firstMessage":"hello""#
        for suffix in [#", "completionRevision":-1,"attentionRevision":0}"#, #", "completionRevision":0,"attentionRevision":-1}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder.gateway.decode(SessionSummary.self, from: Data((summaryBase + suffix).utf8))
            }
            #expect(throws: DecodingError.self) {
                try JSONDecoder.gateway.decode(SessionSummaryUpdate.self, from: Data((updateBase + suffix).utf8))
            }
        }
    }

    @Test("flat session-tree projection decodes")
    func treeDecodes() throws {
        let data = Data(#"[{"id":"entry","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","preview":"hello","role":"user","depth":0,"childCount":1,"isCurrentPath":true}]"#.utf8)
        let nodes = try JSONDecoder.gateway.decode([SessionTreeNode].self, from: data)
        #expect(nodes.first?.role == .user)
        #expect(nodes.first?.isCurrentPath == true)
        #expect(nodes.first?.depth == 0)
    }

    @Test("terminal events prepare typed payloads from original frame bytes")
    func terminalEventPreparation() throws {
        let output = try JSONDecoder.gateway.decode(GatewayEvent.self, from: Data(#"{"type":"event","topic":"terminal.output","sessionId":null,"payload":{"terminalId":"terminal-1","sequence":7,"data":"hello"}}"#.utf8))
        let exit = try JSONDecoder.gateway.decode(GatewayEvent.self, from: Data(#"{"type":"event","topic":"terminal.exit","sessionId":null,"payload":{"terminalId":"terminal-1","sequence":8,"exitCode":0}}"#.utf8))

        #expect(output.preparation == .terminalEvent(.output(PreparedTerminalOutputEvent(
            terminalId: "terminal-1",
            sequence: 7,
            data: "hello"
        ))))
        #expect(exit.preparation == .terminalEvent(.exit(PreparedTerminalExitEvent(
            terminalId: "terminal-1",
            sequence: 8,
            exitCode: 0
        ))))
        #expect(output.sessionCursor == nil)
        #expect(exit.isConsumableSessionReplay)
    }

    @Test("malformed known terminal payload remains an inert event")
    func malformedTerminalEventPreparation() throws {
        let event = try JSONDecoder.gateway.decode(GatewayEvent.self, from: Data(#"{"type":"event","topic":"terminal.output","sessionId":null,"payload":{"terminalId":"terminal-1","sequence":"bad"}}"#.utf8))
        #expect(event.preparation == .none)
    }

    @Test("synthetic terminal events use the same typed preparation")
    func syntheticTerminalEventPreparation() {
        let event = GatewayEvent(
            type: "event",
            topic: "terminal.exit",
            sessionId: nil,
            payload: .object([
                "terminalId": .string("terminal-2"),
                "sequence": .number(9),
                "exitCode": .number(1),
            ])
        )
        #expect(event.preparation == .terminalEvent(.exit(PreparedTerminalExitEvent(
            terminalId: "terminal-2",
            sequence: 9,
            exitCode: 1
        ))))
    }

    @Test("stored gateway profiles migrate when device identity was absent")
    func profileMigration() throws {
        let data = Data(#"{"id":"machine","label":"Mac","host":"100.64.0.1","port":9847,"machineId":"machine"}"#.utf8)
        let profile = try JSONDecoder().decode(GatewayProfile.self, from: data)
        #expect(profile.deviceId == nil)
    }

    @Test("authorized device projection decodes")
    func pairedDeviceDecodes() throws {
        let data = Data(#"{"id":"device","name":"Phone","createdAt":"2026-01-01T00:00:00Z"}"#.utf8)
        #expect(try JSONDecoder().decode(PairedDevice.self, from: data).name == "Phone")
    }

    @Test("provider-qualified model identity does not collide")
    func modelIdentity() {
        #expect(ModelRef(provider: "one", id: "shared") != ModelRef(provider: "two", id: "shared"))
    }

    @Test("model pages decode with an optional continuation cursor")
    func modelPageDecodes() throws {
        struct Page: Decodable { let models: [ModelSummary]; let nextCursor: String? }
        let data = Data(#"{"models":[{"provider":"extension","id":"model","name":"Model","reasoning":false,"input":["text"],"contextWindow":4096,"maxTokens":1024,"available":true}],"nextCursor":"500"}"#.utf8)
        let page = try JSONDecoder.gateway.decode(Page.self, from: data)
        #expect(page.models.first?.ref == ModelRef(provider: "extension", id: "model"))
        #expect(page.nextCursor == "500")
    }

    @Test("resource, workspace, and terminal DTOs preserve their wire shapes")
    func resourceWorkspaceAndTerminalDTOsDecode() throws {
        let inventory = try JSONDecoder.gateway.decode(
            PackageInventory.self,
            from: Data(#"{"packages":[{"source":"pkg","scope":"project","filtered":false,"installedPath":"/workspace/pkg"}],"resources":{"commands":2}}"#.utf8)
        )
        #expect(inventory.packages.first?.id == "project:pkg")
        #expect(inventory.resources.objectValue?["commands"] == .number(2))

        let workspace = try JSONDecoder.gateway.decode(
            WorkspaceListing.self,
            from: Data(#"{"path":"/workspace","parent":"/","entries":[{"name":"src","path":"/workspace/src","kind":"directory","hidden":false}]}"#.utf8)
        )
        #expect(workspace.entries.first?.id == "/workspace/src")
        #expect(workspace.entries.first?.kind == .directory)

        let terminal = try JSONDecoder.gateway.decode(
            TerminalSummary.self,
            from: Data(#"{"id":"terminal","sessionId":"session","cwd":"/workspace","createdAt":"2026-01-01T00:00:00Z","exitedAt":null,"exitCode":null,"sequence":9}"#.utf8)
        )
        #expect(terminal.sessionId == "session")
        #expect(terminal.sequence == 9)
    }

    @Test("extension presentation collections reject limit plus one during decoding")
    func extensionPresentationPreMaterializationBounds() throws {
        let indicator: [String: Any] = ["kind": "default", "frames": []]
        let semantic: [String: Any] = [
            "statuses": [:], "working": ["visible": true, "indicator": indicator], "widgets": [],
            "toolsExpanded": false, "editorRevision": 0, "editorText": "",
        ]
        let base: [String: Any] = [
            "version": 2, "hostEpoch": "host", "revision": 0,
            "capabilities": [], "diagnostics": [], "semanticState": semantic,
            "surfaces": [], "pendingInteractions": [],
        ]
        func decode(_ object: [String: Any]) throws -> ExtensionPresentationState {
            try JSONDecoder.gateway.decode(ExtensionPresentationState.self, from: JSONSerialization.data(withJSONObject: object))
        }
        var exact = base
        exact["capabilities"] = Array(repeating: "capability", count: 128)
        #expect(try decode(exact).capabilities.count == 128)
        var over = base
        over["capabilities"] = Array(repeating: "capability", count: 129)
        #expect(throws: DecodingError.self) { try decode(over) }

        let interaction: [String: Any] = [
            "id": "id", "hostEpoch": "host", "presentationRevision": 1,
            "method": "select", "title": "title", "options": Array(repeating: "option", count: 64),
        ]
        var interactionExact = base
        interactionExact["revision"] = 1
        interactionExact["pendingInteractions"] = Array(repeating: interaction, count: 8)
        #expect(try decode(interactionExact).pendingInteractions.count == 8)
        var interactionOver = interactionExact
        interactionOver["pendingInteractions"] = Array(repeating: interaction, count: 9)
        #expect(throws: DecodingError.self) { try decode(interactionOver) }
        var optionOverInteraction = interaction
        optionOverInteraction["options"] = Array(repeating: "option", count: 65)
        var optionOver = base
        optionOver["revision"] = 1
        optionOver["pendingInteractions"] = [optionOverInteraction]
        #expect(throws: DecodingError.self) { try decode(optionOver) }

        let line: [String: Any] = ["plainText": "x", "runs": [["text": "x", "style": [:]]]]
        let surface: [String: Any] = [
            "id": "surface", "kind": "widget", "placement": "aboveEditor", "lifecycle": "retained",
            "revision": 1, "focused": false, "inputMode": "none",
            "frame": ["width": 1, "height": 1, "plainText": "x", "lines": [line]],
        ]
        var surfaceExact = base
        surfaceExact["surfaces"] = Array(repeating: surface, count: 64)
        #expect(try decode(surfaceExact).surfaces.count == 64)
        var surfaceOver = base
        surfaceOver["surfaces"] = Array(repeating: surface, count: 65)
        #expect(throws: DecodingError.self) { try decode(surfaceOver) }

        var diagnosticsExact = base
        diagnosticsExact["diagnostics"] = Array(repeating: ["code": "c", "message": "m"], count: 64)
        #expect(try decode(diagnosticsExact).diagnostics.count == 64)
        var diagnosticsOver = base
        diagnosticsOver["diagnostics"] = Array(repeating: ["code": "c", "message": "m"], count: 65)
        #expect(throws: DecodingError.self) { try decode(diagnosticsOver) }

        var semanticExact = semantic
        semanticExact["statuses"] = Dictionary(uniqueKeysWithValues: (0..<32).map { ("s\($0)", "v") })
        semanticExact["widgets"] = (0..<24).map { ["key": "w\($0)", "revision": 1, "lines": Array(repeating: "line", count: 12), "placement": "aboveEditor"] }
        semanticExact["working"] = ["visible": true, "indicator": ["kind": "animated", "frames": Array(repeating: "-", count: 32)]]
        var stateWithSemanticExact = base
        stateWithSemanticExact["semanticState"] = semanticExact
        let decodedSemanticExact = try decode(stateWithSemanticExact).semanticState
        #expect(decodedSemanticExact.statuses.count == 32)
        #expect(decodedSemanticExact.widgets.count == 24)
        #expect(decodedSemanticExact.working.indicator?.frames.count == 32)

        var semanticStatusOver = semanticExact
        semanticStatusOver["statuses"] = Dictionary(uniqueKeysWithValues: (0..<33).map { ("s\($0)", "v") })
        var stateWithStatusOver = base
        stateWithStatusOver["semanticState"] = semanticStatusOver
        #expect(throws: DecodingError.self) { try decode(stateWithStatusOver) }
        var semanticWidgetOver = semantic
        semanticWidgetOver["widgets"] = (0..<25).map { ["key": "w\($0)", "revision": 1, "lines": [], "placement": "aboveEditor"] }
        var stateWithWidgetOver = base
        stateWithWidgetOver["semanticState"] = semanticWidgetOver
        #expect(throws: DecodingError.self) { try decode(stateWithWidgetOver) }
        var semanticIndicatorOver = semantic
        semanticIndicatorOver["working"] = ["visible": true, "indicator": ["kind": "animated", "frames": Array(repeating: "-", count: 33)]]
        var stateWithIndicatorOver = base
        stateWithIndicatorOver["semanticState"] = semanticIndicatorOver
        #expect(throws: DecodingError.self) { try decode(stateWithIndicatorOver) }
        var semanticWidgetLinesOver = semantic
        semanticWidgetLinesOver["widgets"] = [["key": "widget", "revision": 1, "lines": Array(repeating: "line", count: 13), "placement": "aboveEditor"]]
        var stateWithWidgetLinesOver = base
        stateWithWidgetLinesOver["semanticState"] = semanticWidgetLinesOver
        #expect(throws: DecodingError.self) { try decode(stateWithWidgetLinesOver) }

        var lineBoundSurface = surface
        lineBoundSurface["frame"] = [
            "width": 1, "height": 120, "plainText": Array(repeating: "x", count: 120).joined(separator: "\n"),
            "lines": Array(repeating: line, count: 120),
        ]
        var lineBoundState = base
        lineBoundState["surfaces"] = [lineBoundSurface]
        #expect(try decode(lineBoundState).surfaces[0].frame.lines.count == 120)
        var lineOverSurface = lineBoundSurface
        lineOverSurface["frame"] = ["width": 1, "height": 121, "plainText": "", "lines": Array(repeating: line, count: 121)]
        var lineOverState = base
        lineOverState["surfaces"] = [lineOverSurface]
        #expect(throws: DecodingError.self) { try decode(lineOverState) }

        let run: [String: Any] = ["text": "", "style": [:]]
        var runBoundSurface = surface
        runBoundSurface["frame"] = ["width": 1, "height": 1, "plainText": "", "lines": [["plainText": "", "runs": Array(repeating: run, count: 4_096)]]]
        var runBoundState = base
        runBoundState["surfaces"] = [runBoundSurface]
        #expect(try decode(runBoundState).surfaces[0].frame.lines[0].runs.count == 4_096)
        var runOverSurface = surface
        runOverSurface["frame"] = ["width": 1, "height": 1, "plainText": "", "lines": [["plainText": "", "runs": Array(repeating: run, count: 4_097)]]]
        var runOverState = base
        runOverState["surfaces"] = [runOverSurface]
        #expect(throws: DecodingError.self) { try decode(runOverState) }

        var projectionExact = base
        projectionExact["projection"] = [
            "complete": false, "omitted": Array(repeating: "surfaces", count: 16),
            "omittedSurfaces": (0..<64).map { ["id": "s\($0)", "revision": 1] },
        ]
        #expect(try decode(projectionExact).projection?.omittedSurfaces?.count == 64)
        var projectionOver = base
        projectionOver["projection"] = ["complete": false, "omitted": Array(repeating: "x", count: 17)]
        #expect(throws: DecodingError.self) { try decode(projectionOver) }
        var projectionSurfacesOver = base
        projectionSurfacesOver["projection"] = ["complete": false, "omitted": [], "omittedSurfaces": (0..<65).map { ["id": "s\($0)", "revision": 1] }]
        #expect(throws: DecodingError.self) { try decode(projectionSurfacesOver) }

        func decodeMutation(_ object: [String: Any]) throws -> ExtensionPresentationMutation {
            try JSONDecoder.gateway.decode(ExtensionPresentationMutation.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let mutationBase: [String: Any] = ["version": 2, "hostEpoch": "host", "revision": 1]
        var mutationExact = mutationBase
        mutationExact["interactionList"] = Array(repeating: interaction, count: 8)
        mutationExact["surfaceUpserts"] = Array(repeating: surface, count: 64)
        mutationExact["surfaceRemovals"] = Array(repeating: "id", count: 64)
        mutationExact["capabilities"] = Array(repeating: "capability", count: 128)
        mutationExact["diagnostics"] = Array(repeating: ["code": "c", "message": "m"], count: 64)
        let decodedMutationExact = try decodeMutation(mutationExact)
        #expect(decodedMutationExact.interactionList?.count == 8)
        #expect(decodedMutationExact.surfaceUpserts?.count == 64)
        #expect(decodedMutationExact.surfaceRemovals?.count == 64)
        #expect(decodedMutationExact.capabilities?.count == 128)
        #expect(decodedMutationExact.diagnostics?.count == 64)

        var mutationInteractionOver = mutationBase
        mutationInteractionOver["interactionList"] = Array(repeating: interaction, count: 9)
        #expect(throws: DecodingError.self) { try decodeMutation(mutationInteractionOver) }
        var mutationUpsertOver = mutationBase
        mutationUpsertOver["surfaceUpserts"] = Array(repeating: surface, count: 65)
        #expect(throws: DecodingError.self) { try decodeMutation(mutationUpsertOver) }
        var removalOver = mutationBase
        removalOver["surfaceRemovals"] = Array(repeating: "id", count: 65)
        #expect(throws: DecodingError.self) { try decodeMutation(removalOver) }
        var mutationCapabilitiesOver = mutationBase
        mutationCapabilitiesOver["capabilities"] = Array(repeating: "capability", count: 129)
        #expect(throws: DecodingError.self) { try decodeMutation(mutationCapabilitiesOver) }
        var mutationDiagnosticsOver = mutationBase
        mutationDiagnosticsOver["diagnostics"] = Array(repeating: ["code": "c", "message": "m"], count: 65)
        #expect(throws: DecodingError.self) { try decodeMutation(mutationDiagnosticsOver) }
        var patchStatusesExact = mutationBase
        patchStatusesExact["semantic"] = ["statuses": Dictionary(uniqueKeysWithValues: (0..<32).map { ("s\($0)", "v") })]
        #expect(try decodeMutation(patchStatusesExact).semantic?.statuses?.count == 32)
        var patchStatusOver = mutationBase
        patchStatusOver["semantic"] = ["statuses": Dictionary(uniqueKeysWithValues: (0..<33).map { ("s\($0)", "v") })]
        #expect(throws: DecodingError.self) { try decodeMutation(patchStatusOver) }
        var patchWidgetsExact = mutationBase
        patchWidgetsExact["semantic"] = ["widgets": (0..<24).map { ["key": "w\($0)", "revision": 1, "lines": [], "placement": "aboveEditor"] }]
        #expect(try decodeMutation(patchWidgetsExact).semantic?.widgets?.count == 24)
        var patchWidgetOver = mutationBase
        patchWidgetOver["semantic"] = ["widgets": (0..<25).map { ["key": "w\($0)", "revision": 1, "lines": [], "placement": "aboveEditor"] }]
        #expect(throws: DecodingError.self) { try decodeMutation(patchWidgetOver) }
    }

    @Test("extension frames enforce visible terminal cell width")
    func extensionFrameCellWidth() {
        func surface(_ text: String, width: Int) -> ExtensionSurface {
            .init(
                id: "surface", kind: .widget, placement: .aboveEditor, lifecycle: .retained,
                targetId: nil, provenance: nil, revision: 1, focused: false, inputMode: .none,
                frame: .init(width: width, height: 1, lines: [.init(plainText: text, runs: [.init(text: text, style: .init())])], plainText: text)
            )
        }
        #expect(!ExtensionPresentationPolicy.admit(surface("ab", width: 1)))
        #expect(!ExtensionPresentationPolicy.admit(surface("界", width: 1)))
        #expect(!ExtensionPresentationPolicy.admit(surface("👨‍👩‍👧‍👦", width: 1)))
        #expect(!ExtensionPresentationPolicy.admit(surface("♥️", width: 1)))
        #expect(ExtensionPresentationPolicy.admit(surface("é", width: 1)))
        #expect(ExtensionPresentationPolicy.admit(surface("界👨‍👩‍👧‍👦", width: 4)))
    }

    @Test("iOS only requests restart from a drain-capable supervised Gateway")
    func safeRestartCapability() {
        #expect(!AppModel.supportsSafeGatewayRestart(capabilities: ["sessions.v1"]))
        #expect(!AppModel.supportsSafeGatewayRestart(capabilities: ["sessions.v1", "restart-drain.v1"]))
        #expect(AppModel.supportsSafeGatewayRestart(capabilities: ["sessions.v1", "restart-drain.v1", "restart-supervised.v1"]))
    }

    @Test("gateway failure is a localized error")
    func failure() {
        let value = GatewayFailure(code: "busy", message: "Session busy", retryable: true, details: nil)
        #expect(value.localizedDescription == "Session busy")
    }
}
