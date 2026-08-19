import Foundation
import Testing
@testable import TronMobile

@Suite("Chat transcript presentation")
struct ChatTranscriptPresentationTests {
    @Test("native visible edge is authoritative over independently settling inset fields")
    func nativeVisibleBottomDistance() {
        let geometry = ChatTranscriptGeometry(
            offsetY: 400,
            contentHeight: 1_000,
            containerHeight: 400,
            bottomInset: 200,
            visibleBottomY: 1_200
        )

        #expect(geometry.distanceFromBottom == 0)
        #expect(geometry.isAtCatchUpBoundary)
    }

    @Test("opening plausibility distinguishes a physical tail from overflow overshoot")
    func openingViewportPlausibility() {
        let bottom = ChatTranscriptGeometry(
            offsetY: 600,
            contentHeight: 1_000,
            containerHeight: 400,
            visibleBottomY: 1_000
        )
        let overshoot = ChatTranscriptGeometry(
            offsetY: 1_200,
            contentHeight: 1_000,
            containerHeight: 400,
            visibleBottomY: 1_600
        )
        let undersized = ChatTranscriptGeometry(
            offsetY: 0,
            contentHeight: 180,
            containerHeight: 400,
            visibleTopY: 0,
            visibleBottomY: 400
        )
        let undersizedOvershoot = ChatTranscriptGeometry(
            offsetY: 100,
            contentHeight: 180,
            containerHeight: 400,
            visibleTopY: 100,
            visibleBottomY: 500
        )

        #expect(bottom.isPlausibleOpeningViewport)
        #expect(bottom.isAtCatchUpBoundary)
        #expect(!overshoot.isPlausibleOpeningViewport)
        #expect(overshoot.isAtCatchUpBoundary)
        #expect(undersized.isPlausibleOpeningViewport)
        #expect(!undersizedOvershoot.isPlausibleOpeningViewport)
    }

    @Test("extension widgets project into their generic composer slots")
    func extensionWidgetPresentationIsVisible() {
        let widgets = [
            ExtensionWidget(key: "below-one", lines: ["One"], placement: .belowEditor),
            ExtensionWidget(key: "above-one", lines: ["Two"], placement: .aboveEditor),
            ExtensionWidget(key: "below-two", lines: ["Three"], placement: .belowEditor),
            ExtensionWidget(key: "above-two", lines: ["Four"], placement: .aboveEditor),
        ]

        #expect(ChatExtensionChromePolicy.rendersWidgets)
        #expect(ChatExtensionWidgetPolicy.visibleWidgets(widgets, placement: .aboveEditor).map(\.key) == ["above-one", "above-two"])
        #expect(ChatExtensionWidgetPolicy.visibleWidgets(widgets, placement: .belowEditor).map(\.key) == ["below-one", "below-two"])
    }

    @Test("extension activity policy is bounded, deterministic, and summarizes service work")
    func extensionActivityPolicy() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.extensionPresentation.semanticState.statuses = [
            "z": "Last status",
            "a": String(repeating: "x", count: 700)
        ]
        snapshot.extensionPresentation.semanticState.widgets = [
            ExtensionWidget(key: "widget", lines: ["detail"], placement: .aboveEditor)
        ]
        let service = ToolExecutionState(
            toolCallId: "call-1", toolName: "subtask", order: 3, status: .running,
            arguments: .null, partialResult: nil, result: nil,
            isError: false, startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            extensionOrigin: ExtensionToolOrigin(source: "public-source")
        )
        let summary = try #require(ChatExtensionWidgetPolicy.summary(snapshot.extensionPresentation, executions: [service]))
        #expect(summary.runningServiceCount == 1)
        #expect(summary.services.first?.source == "public-source")
        #expect(summary.label == "Extension activity · 1 running")
        #expect(ChatExtensionWidgetPolicy.admittedStatuses(snapshot.extensionPresentation.semanticState.statuses).count == 2)
        #expect(ChatExtensionWidgetPolicy.admittedStatuses(snapshot.extensionPresentation.semanticState.statuses).allSatisfy { $0.value.count <= ChatExtensionWidgetPolicy.maximumStatusValueCharacters })
        let descriptor = ChatToolDescriptor(ChatToolPresentation(
            id: "call-1", title: "subtask", subtitle: "Running", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false, startedAt: nil, completedAt: nil,
            durationMs: nil, lastProgressAt: nil, progressSequence: nil,
            extensionOrigin: ExtensionToolOrigin(source: "public-source")
        ))
        let run = ChatToolRunPresentation(tools: [descriptor])
        #expect(run.isExtensionActivity)
        #expect(run.title == "Extension activity")
    }

    @Test("widget groups remain separate and deterministic with conservative activity fallback")
    func widgetGroupsAreSeparate() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.extensionPresentation.semanticState.widgets = [
            ExtensionWidget(key: "second", lines: ["B"], placement: .belowEditor),
            ExtensionWidget(key: "first", lines: ["A"], placement: .belowEditor)
        ]
        snapshot.extensionPresentation.semanticState.statuses = ["status": "live"]
        let groups = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation)
        #expect(groups.map(\.id) == ["activity", "semantic:first", "semantic:second"])
        #expect(groups.filter(\.isWidgetGroup).count == 2)
        #expect(groups.first(where: { $0.id == "activity" })?.statuses.map(\.key) == ["status"])
        snapshot.extensionPresentation.semanticState.statuses["first"] = "First status"
        let matched = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation)
        #expect(matched.first(where: { $0.id == "semantic:first" })?.statuses.map(\.key) == ["first"])
        let frame = ExtensionFrame(width: 5, height: 1, lines: [ExtensionFrameLine(plainText: "Surface", runs: [ExtensionFrameRun(text: "Surface", style: ExtensionFrameStyle())])], plainText: "Surface")
        snapshot.extensionPresentation.surfaces = [ExtensionSurface(id: "surface", kind: .widget, placement: .belowEditor, lifecycle: .retained, targetId: nil, provenance: .init(source: "public-source", path: nil), revision: 1, focused: false, inputMode: .none, frame: frame)]
        let service = ToolExecutionState(toolCallId: "service", toolName: "tool", order: 1, status: .running, arguments: .null, partialResult: nil, result: nil, isError: false, startedAt: "now", updatedAt: "now", extensionOrigin: .init(source: "public-source"))
        let sourced = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation, executions: [service])
        #expect(sourced.first(where: { $0.id == "source:public-source" })?.services.map(\.id) == ["service"])
        snapshot.extensionPresentation.semanticState.widgets = []
        snapshot.extensionPresentation.surfaces = []
        #expect(ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation).count == 1)
        #expect(ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation).first?.id == "activity")
    }

    @Test("owner provenance groups live semantic, surface, status, and service content")
    func ownerProvenanceGroupsLiveExtension() throws {
        var snapshot = try fixture(transcript: "[]")
        let goal = ExtensionOwner(id: "/extensions/goal.ts", title: "Goal", source: "goal-source")
        let subagent = ExtensionOwner(id: "/extensions/subagents.ts", title: "Subagents", source: "subagent-source")
        snapshot.extensionPresentation.semanticState.widgets = [
            ExtensionWidget(key: "goal", lines: ["Goal"], placement: .belowEditor, owner: goal),
            ExtensionWidget(key: "subagent", lines: ["Subagent"], placement: .belowEditor, owner: subagent)
        ]
        snapshot.extensionPresentation.semanticState.statuses = ["goal-status": "Goal is live", "subagent": "Running"]
        snapshot.extensionPresentation.semanticState.statusOwners = ["goal-status": goal, "subagent": subagent]
        let longSource = String(repeating: "source/", count: 40)
        let service = ToolExecutionState(toolCallId: "service", toolName: "subagent", order: 1, status: .running, arguments: .null, partialResult: nil, result: nil, isError: false, startedAt: "now", updatedAt: "now", extensionOrigin: .init(source: "subagent-source"))
        let groups = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation, executions: [service])
        #expect(groups.map(\.label) == ["Goal", "Subagents"])
        #expect(groups.first(where: { $0.label == "Goal" })?.statuses.map(\.key) == ["goal-status"])
        #expect(groups.first(where: { $0.label == "Subagents" })?.items.count == 1)
        #expect(groups.first(where: { $0.label == "Subagents" })?.services.map(\.id) == ["service"])
        let sourcedOwner = ExtensionOwner(id: "/extensions/long.ts", title: "Long", source: longSource)
        snapshot.extensionPresentation.semanticState.widgets = [ExtensionWidget(key: "long", lines: ["Long"], placement: .belowEditor, owner: sourcedOwner)]
        let longService = ToolExecutionState(toolCallId: "long-service", toolName: "long", order: 2, status: .running, arguments: .null, partialResult: nil, result: nil, isError: false, startedAt: "now", updatedAt: "now", extensionOrigin: .init(source: longSource))
        let sourcedGroups = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation, executions: [service, longService])
        #expect(sourcedGroups.first(where: { $0.label == "Long" })?.services.map(\.id) == ["long-service"])
    }

    @Test("semantic and surface representations share one canonical widget group")
    func semanticSurfaceRepresentationsDeduplicate() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.extensionPresentation.semanticState.widgets = [
            ExtensionWidget(key: "goal", lines: ["Goal content"], placement: .belowEditor),
            ExtensionWidget(key: "subagent", lines: ["Subagent content"], placement: .belowEditor)
        ]
        let encoded = Data("subagent".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let frame = ExtensionFrame(width: 8, height: 1, lines: [ExtensionFrameLine(plainText: "Surface content", runs: [ExtensionFrameRun(text: "Surface content", style: ExtensionFrameStyle())])], plainText: "Surface content")
        snapshot.extensionPresentation.surfaces = [ExtensionSurface(id: "mounted:\(encoded)", kind: .widget, placement: .belowEditor, lifecycle: .retained, targetId: nil, provenance: nil, revision: 1, focused: false, inputMode: .none, frame: frame)]
        let groups = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation)
        #expect(groups.map(\.id) == ["semantic:goal", "semantic:subagent"])
        #expect(groups.first(where: { $0.id == "semantic:subagent" })?.items.count == 2)
        #expect(ChatExtensionWidgetPolicy.canonicalWidgetKey(for: "mounted:\(encoded)") == "subagent")
    }

    @Test("source labels are bounded provenance labels and unmatched activity remains fallback")
    func extensionLabelsUseProvenance() throws {
        var snapshot = try fixture(transcript: "[]")
        let frame = ExtensionFrame(width: 4, height: 1, lines: [ExtensionFrameLine(plainText: "content-derived title", runs: [])], plainText: "content-derived title")
        snapshot.extensionPresentation.surfaces = [ExtensionSurface(id: "unrelated", kind: .widget, placement: .belowEditor, lifecycle: .retained, targetId: nil, provenance: .init(source: "example-extension_source", path: nil), revision: 1, focused: false, inputMode: .none, frame: frame)]
        snapshot.extensionPresentation.semanticState.statuses = ["other": "Unmatched"]
        let groups = ChatExtensionWidgetPolicy.groups(snapshot.extensionPresentation)
        #expect(groups.first(where: { $0.id == "source:example-extension_source" })?.label == "Example Extension Source")
        #expect(groups.first(where: { $0.id == "source:example-extension_source" })?.label != "content-derived title")
        #expect(groups.first(where: { $0.id == "activity" })?.label == "Extension activity")
        #expect(groups.first(where: { $0.id == "source:example-extension_source" })?.label.count == 24)
    }

    @Test("native extension text strips complete terminal navigation hints only")
    func nativeExtensionTextStripsTerminalChrome() {
        #expect(NativeExtensionText.isDetailHint("Press ↓/← to inspect") == true)
        #expect(NativeExtensionText.isDetailHint("↔ to inspect") == true)
        #expect(NativeExtensionText.clean("Press ↓/← to inspect") == "")
        #expect(NativeExtensionText.clean("  useful arrow status  ") == "useful arrow status")
        #expect(NativeExtensionText.clean("Keyboard shortcuts: arrow keys move the cursor") == "Keyboard shortcuts: arrow keys move the cursor")
    }

    @Test("status identity remains complete when display keys share a long prefix")
    func statusIdentityIsNotTruncated() {
        let prefix = String(repeating: "k", count: 255)
        let firstKey = prefix + "a"
        let secondKey = prefix + "b"
        let statuses = ChatExtensionWidgetPolicy.admittedStatuses([
            firstKey: "one",
            secondKey: "two"
        ])
        #expect(statuses.count == 2)
        #expect(Set(statuses.map(\.id)) == Set([firstKey, secondKey]))
        #expect(statuses.allSatisfy { $0.displayKey.count <= 128 })
    }

    @Test("interaction and editor presentation use deterministic priority")
    func extensionPresentationArbiterPriority() {
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: false, hasInteraction: true, hasEditorRequest: true
        ) == .none)
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: true, hasInteraction: true, hasEditorRequest: true
        ) == .interaction)
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: true, hasInteraction: false, hasEditorRequest: true
        ) == .editorRequest)
        #expect(ChatExtensionPresentationArbiter.presentation(
            modelSettled: true, hasInteraction: false, hasEditorRequest: false
        ) == .none)
    }

    @Test("unknown tool provenance fails open and does not become extension activity")
    func unknownToolProvenanceFailsOpen() throws {
        var snapshot = try fixture(transcript: "[]")
        let service = ToolExecutionState(
            toolCallId: "call-unknown", toolName: "tool", order: 1, status: .completed,
            arguments: .null, partialResult: nil, result: nil,
            isError: false, startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z"
        )
        #expect(ChatExtensionWidgetPolicy.serviceItems([service]).isEmpty)
        #expect(!ChatExtensionWidgetPolicy.hasActivity(snapshot.extensionPresentation, executions: [service]))
    }

    @Test("semantic and remote widgets merge with stable namespaced order")
    func mergedExtensionWidgetPolicyIsDeterministic() {
        let widget = ExtensionWidget(key: "goal", lines: ["Goal"], placement: .belowEditor)
        let frame = ExtensionFrame(width: 4, height: 1, lines: [ExtensionFrameLine(plainText: "run", runs: [ExtensionFrameRun(text: "run", style: ExtensionFrameStyle())])], plainText: "run")
        let surface = ExtensionSurface(id: "widget:c3Vi", kind: .widget, placement: .belowEditor, lifecycle: .retained, targetId: nil, provenance: nil, revision: 1, focused: false, inputMode: .none, frame: frame)
        let items = ChatExtensionWidgetPolicy.mergedItems(widgets: [widget], surfaces: [surface], placement: .belowEditor)
        #expect(items.map(\.id) == ["semantic-widget:goal", "surface-widget:widget:c3Vi"])
        #expect(items.count == 2)
    }

    @Test("only admitted read-only widget surfaces project into composer slots")
    func extensionSurfaceWidgetPolicyIsBounded() {
        let frame = ExtensionFrame(width: 4, height: 1, lines: [ExtensionFrameLine(plainText: "goal", runs: [ExtensionFrameRun(text: "goal", style: ExtensionFrameStyle())])], plainText: "goal")
        let surfaces = [
            ExtensionSurface(id: "widget:subagent", kind: .widget, placement: .belowEditor, lifecycle: .retained, targetId: nil, provenance: nil, revision: 1, focused: false, inputMode: .none, frame: frame),
            ExtensionSurface(id: "overlay:blocked", kind: .overlay, placement: .overlay, lifecycle: .blocking, targetId: nil, provenance: nil, revision: 1, focused: true, inputMode: .keys, frame: frame),
            ExtensionSurface(id: "widget:interactive", kind: .widget, placement: .aboveEditor, lifecycle: .retained, targetId: nil, provenance: nil, revision: 1, focused: false, inputMode: .keys, frame: frame),
        ]
        #expect(ChatExtensionWidgetPolicy.visibleSurfaces(surfaces, placement: .belowEditor).map(\.id) == ["widget:subagent"])
        #expect(ChatExtensionWidgetPolicy.visibleSurfaces(surfaces, placement: .aboveEditor).isEmpty)
    }

    @Test("extreme frame colors fall back when contrast is unreadable")
    func extensionFrameContrastPolicy() {
        #expect(ExtensionFrameColorPolicy.contrastRatio("000000", "FFFFFF") > 20)
        #expect(ExtensionFrameColorPolicy.contrastRatio("000000", "000000") < 1.1)
        #expect(ExtensionFrameColorPolicy.usableForeground("000000", background: "000000", fallback: "FFFFFF") == "FFFFFF")
        #expect(ExtensionFrameColorPolicy.usableBackground("FFFFFF", foreground: "FFFFFF", fallback: "16181D") == "16181D")
    }

    @Test("inverse frame colors resolve as one contrast-checked swapped pair")
    func inverseFrameColorsRemainReadable() {
        let colors = ExtensionFrameColorPolicy.resolvedColors(
            foreground: "FFFFFF",
            background: "FFFFFF",
            inverse: true,
            nativeForeground: "F8FAFC",
            nativeBackground: "090A0C",
            fallbackBackground: "16181D"
        )
        #expect(colors.foreground == "FFFFFF")
        #expect(colors.background == "16181D")
        #expect(ExtensionFrameColorPolicy.contrastRatio(colors.foreground, colors.background) >= ExtensionFrameColorPolicy.minimumContrast)
        let defaults = ExtensionFrameColorPolicy.resolvedColors(
            foreground: nil,
            background: nil,
            inverse: true,
            nativeForeground: "F8FAFC",
            nativeBackground: "090A0C",
            fallbackBackground: "16181D"
        )
        #expect(defaults.foreground == "090A0C")
        #expect(defaults.background == "F8FAFC")
    }

    @Test("interaction suppression is exact-scope and queue-safe")
    func interactionSuppressionScope() {
        let first = ExtensionInteraction(id: "first", hostEpoch: "epoch", presentationRevision: 4, method: .select, title: "First", options: ["A"])
        let newer = ExtensionInteraction(id: "newer", hostEpoch: "epoch", presentationRevision: 5, method: .input, title: "Newer")
        let replacement = ExtensionInteraction(id: "first", hostEpoch: "epoch", presentationRevision: 6, method: .select, title: "Replacement", options: ["B"])
        let nextEpoch = ExtensionInteraction(id: "first", hostEpoch: "next", presentationRevision: 1, method: .select, title: "Next", options: ["C"])
        let scope = ExtensionInteractionScope(first)

        #expect(ChatExtensionInteractionPolicy.presentedInteraction([first], suppressing: scope) == nil)
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([first, newer], suppressing: scope) == newer)
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([replacement], suppressing: scope) == replacement)
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([nextEpoch], suppressing: scope) == nextEpoch)
        #expect(!ChatExtensionInteractionPolicy.shouldClearSuppression(scope, from: [first, newer]))
        #expect(ChatExtensionInteractionPolicy.shouldClearSuppression(scope, from: [replacement]))
        #expect(ChatExtensionInteractionPolicy.shouldClearSuppression(scope, from: []))
    }

    @Test("failed interaction responses do not create suppression scope")
    func failedInteractionResponseLeavesScopeAvailable() {
        let interaction = ExtensionInteraction(id: "failed", hostEpoch: "epoch", presentationRevision: 2, method: .confirm, title: "Continue?")
        #expect(ChatExtensionInteractionPolicy.presentedInteraction([interaction], suppressing: nil) == interaction)
    }

    @Test("extension statuses stay out of transcript notifications and drive the activity pill")
    func extensionStatusesAreVisible() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.extensionPresentation.semanticState.statuses = ["goal": "Pursuing goal"]
        snapshot.extensionPresentation.semanticState.working = .init(message: "Still working", visible: true)

        let runtime = ChatNotificationPresentation.runtime(in: snapshot)
        #expect(!ChatExtensionChromePolicy.rendersStatusPills)
        #expect(runtime.map(\.id) == ["runtime-working"])
        #expect(ChatExtensionWidgetPolicy.hasActivity(snapshot.extensionPresentation))
    }

    @Test("queued compaction is explicit until canonical compaction starts")
    func queuedCompactionPresentation() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.compactionQueued = true
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)

        let queued = ChatNotificationPresentation.runtime(in: snapshot)
        #expect(queued.map(\.id) == ["runtime-compaction-queued"])
        #expect(queued.first?.title == "Compaction queued")
        #expect(queued.first?.detail == "After current work")
        #expect(queued.first?.semanticID == nil)
        #expect(queued.first?.material == .flat)

        snapshot.compactionQueued = false
        snapshot.phase = .compacting
        let active = ChatNotificationPresentation.runtime(in: snapshot)
        #expect(active.count == 1)
        #expect(active.first?.title == "Compacting context")
        #expect(active.first?.id == "runtime-working")
    }

    @Test("pending prompts retain their requested delivery label across reconstruction")
    func pendingPromptPresentation() {
        let steer = ChatPendingPromptPresentation(snapshot: .init(
            id: "pending-steer",
            createdAt: "2026-01-01T00:00:00Z",
            behavior: .steer,
            text: "wait for compaction",
            attachmentCount: 0
        ), isCompacting: true)
        #expect(steer.statusTitle == "Steering after compaction")
        #expect(steer.text == "wait for compaction")

        let ordinary = ChatPendingPromptPresentation(snapshot: .init(
            id: "pending-prompt",
            createdAt: "2026-01-01T00:00:00Z",
            behavior: nil,
            text: "send after compaction",
            attachmentCount: 1
        ), isCompacting: false)
        #expect(ordinary.statusTitle == "Sending")
        #expect(ordinary.attachmentCount == 1)
    }

    @Test("ordinary running state uses ambient bottom activity without a transcript row")
    func ordinaryRunningUsesAmbientActivity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)
        snapshot.retry = nil

        let presentation = try #require(ChatRuntimeWorkingPresentation(
            phase: snapshot.phase,
            working: snapshot.extensionPresentation.semanticState.working,
            retry: snapshot.retry
        ))
        #expect(presentation.message == "Tron is working")
        #expect(presentation.usesAmbientBottomIndicator)
        #expect(ChatNotificationPresentation.runtime(in: snapshot).isEmpty)

        snapshot.extensionPresentation.semanticState.working.message = "Reading files"
        let custom = try #require(ChatRuntimeWorkingPresentation(
            phase: snapshot.phase,
            working: snapshot.extensionPresentation.semanticState.working,
            retry: snapshot.retry
        ))
        #expect(!custom.usesAmbientBottomIndicator)
        #expect(ChatNotificationPresentation.runtime(in: snapshot).map(\.id) == ["runtime-working"])
    }

    @Test("runtime working row follows phase, visibility, message, retry, and ambient policy")
    func runtimeWorkingRowPolicy() {
        struct PolicyCase {
            let name: String
            let phase: SessionPhase
            let visible: Bool
            let message: String?
            let retry: RetryState?
            let expectedMessage: String?
            let expectedRetryMessage: String?
        }

        let retryWithMaximum = RetryState(
            source: .agent,
            attempt: 2,
            maxAttempts: 4,
            delayMs: 500,
            errorMessage: "transient"
        )
        let retryWithoutMaximum = RetryState(
            source: .compaction,
            attempt: 3,
            maxAttempts: nil,
            delayMs: nil,
            errorMessage: nil
        )
        let cases = [
            PolicyCase(
                name: "running visible default message without retry",
                phase: .running, visible: true, message: nil, retry: nil,
                expectedMessage: "Tron is working", expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "running invisible custom message with retry maximum",
                phase: .running, visible: false, message: "Reading files", retry: retryWithMaximum,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "compacting visible custom message with retry without maximum",
                phase: .compacting, visible: true, message: "Trimming history", retry: retryWithoutMaximum,
                expectedMessage: "Trimming history", expectedRetryMessage: "Attempt 3"
            ),
            PolicyCase(
                name: "compacting invisible default message without retry",
                phase: .compacting, visible: false, message: nil, retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "retrying visible default message with retry maximum",
                phase: .retrying, visible: true, message: nil, retry: retryWithMaximum,
                expectedMessage: "Retrying provider", expectedRetryMessage: "Attempt 2 of 4"
            ),
            PolicyCase(
                name: "retrying invisible custom message without retry",
                phase: .retrying, visible: false, message: "Trying again", retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "idle visible default message without retry",
                phase: .idle, visible: true, message: nil, retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "idle invisible custom message with retry without maximum",
                phase: .idle, visible: false, message: "Ignored", retry: retryWithoutMaximum,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "interrupted visible custom message with retry maximum",
                phase: .interrupted, visible: true, message: "Ignored", retry: retryWithMaximum,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
            PolicyCase(
                name: "interrupted invisible default message without retry",
                phase: .interrupted, visible: false, message: nil, retry: nil,
                expectedMessage: nil, expectedRetryMessage: nil
            ),
        ]

        for policyCase in cases {
            let presentation = ChatRuntimeWorkingPresentation(
                phase: policyCase.phase,
                working: .init(message: policyCase.message, visible: policyCase.visible),
                retry: policyCase.retry
            )
            #expect(
                (presentation != nil) == (policyCase.expectedMessage != nil),
                "unexpected visibility for \(policyCase.name)"
            )
            #expect(
                presentation?.message == policyCase.expectedMessage,
                "unexpected message for \(policyCase.name)"
            )
            #expect(
                presentation?.retryMessage == policyCase.expectedRetryMessage,
                "unexpected retry message for \(policyCase.name)"
            )
            let expectedAmbient = policyCase.phase == .running
                && policyCase.visible
                && policyCase.message == nil
                && policyCase.retry == nil
            #expect(
                (presentation?.usesAmbientBottomIndicator ?? false) == expectedAmbient,
                "unexpected ambient activity policy for \(policyCase.name)"
            )
        }
    }

    @Test("zero and partial geometry never masquerade as bottom readiness")
    func chatGeometryValidity() {
        #expect(!ChatTranscriptGeometry.zero.isValid)
        #expect(!ChatTranscriptGeometry.zero.isAtExactBottom)
        let partial = ChatTranscriptGeometry(offsetY: 0, contentHeight: 100, containerHeight: 0)
        #expect(!partial.isValid)
        #expect(!partial.isAtBottom)
        let ready = ChatTranscriptGeometry(offsetY: 400, contentHeight: 800, containerHeight: 400)
        #expect(ready.isValid)
        #expect(ready.isAtExactBottom)

        let insetBottom = ChatTranscriptGeometry(
            offsetY: 472, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        let insetAway = ChatTranscriptGeometry(
            offsetY: 372, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        #expect(insetBottom.isAtExactBottom)
        #expect(insetBottom.isAtCatchUpBoundary)
        #expect(insetAway.distanceFromBottom == 100)
        #expect(!insetAway.isAtBottom)
        let roundedTail = ChatTranscriptGeometry(
            offsetY: 460, contentHeight: 800, containerHeight: 400, bottomInset: 72
        )
        #expect(!roundedTail.isAtExactBottom)
        #expect(roundedTail.isAtCatchUpBoundary)
    }

    @Test("chat toolbar title remains bounded during interactive navigation")
    func toolbarTitleWidth() {
        #expect(ChatToolbarTitleLayout.width(containerWidth: 0) == 80)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 402) == 250)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 440) == 288)
        #expect(ChatToolbarTitleLayout.width(containerWidth: 1_024) == 360)
    }

    @Test("attachment menu availability is session scoped and independent of draft text")
    func attachmentAvailability() {
        #expect(!ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: false, phase: .idle, isSending: false
        ))
        #expect(!ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: nil, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .running, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .idle, isSending: true
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .idle, isSending: false
        ))
        #expect(ChatAttachmentAvailabilityPolicy.actionsEnabled(
            isTranscriptReady: true, phase: .interrupted, isSending: false
        ))

        let running = ChatAttachmentMenuState(
            sessionID: "session", phase: .running,
            isTranscriptReady: true, isSending: false
        )
        let compacting = ChatAttachmentMenuState(
            sessionID: "session", phase: .compacting,
            isTranscriptReady: true, isSending: false
        )
        let idle = ChatAttachmentMenuState(
            sessionID: "session", phase: .idle,
            isTranscriptReady: true, isSending: false
        )
        let anotherIdle = ChatAttachmentMenuState(
            sessionID: "another-session", phase: .idle,
            isTranscriptReady: true, isSending: false
        )
        #expect(running.actionsEnabled)
        #expect(idle.actionsEnabled)
        #expect(running.identity == compacting.identity)
        #expect(running.identity == idle.identity)
        #expect(idle.identity != anotherIdle.identity)
    }

    @Test("authoritative sync remains covered until the physical viewport is positioned")
    func chatOpenPresentationState() {
        var state = ChatOpenPresentationState(sessionID: "session-a")
        let epoch = state.begin()
        let wrongSession = state.installAuthoritativeBaseline(sessionID: "session-b", epoch: epoch)
        let staleEpoch = state.installAuthoritativeBaseline(sessionID: "session-a", epoch: epoch - 1)
        #expect(!wrongSession)
        #expect(!staleEpoch)
        #expect(state.phase == .opening)

        let installed = state.installAuthoritativeBaseline(sessionID: "session-a", epoch: epoch)
        #expect(installed)
        #expect(state.phase == .positioning)
        let wrongPositionedSession = state.installPositionedViewport(
            sessionID: "session-b", epoch: epoch
        )
        let stalePositionedEpoch = state.installPositionedViewport(
            sessionID: "session-a", epoch: epoch - 1
        )
        let positioned = state.installPositionedViewport(sessionID: "session-a", epoch: epoch)
        #expect(!wrongPositionedSession)
        #expect(!stalePositionedEpoch)
        #expect(positioned)
        #expect(state.phase == .ready)
    }

    @Test("stale presentation callbacks cannot fail a newer opening epoch")
    func staleChatOpenCallbacks() {
        var state = ChatOpenPresentationState(sessionID: "session-a")
        let staleEpoch = state.begin()
        let currentEpoch = state.begin()
        let stale = state.fail(sessionID: "session-a", epoch: staleEpoch, message: "stale")
        let wrongSession = state.fail(sessionID: "session-b", epoch: currentEpoch, message: "wrong session")
        #expect(!stale)
        #expect(!wrongSession)
        #expect(state.phase == .opening)
        let failed = state.fail(sessionID: "session-a", epoch: currentEpoch, message: "offline")
        #expect(failed)
        #expect(state.phase == .failed("offline"))
    }

    @Test("earlier page responses require the exact mounted generation and cursor")
    func earlierPageRequestIdentity() {
        let request = ChatTranscriptPageRequest(
            sessionID: "session-a",
            presentationGeneration: 7,
            runtimeGeneration: "runtime-a",
            before: 40,
            expectedTotal: 48,
            expectedNextEntryID: "entry-40"
        )
        #expect(request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: 48, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 8,
            runtimeGeneration: "runtime-a", transcriptStart: 40,
            transcriptTotal: 48, firstTranscriptID: "entry-40"
        ))
        #expect(!request.canInstall(
            sessionID: "session-a", presentationGeneration: 7,
            runtimeGeneration: "runtime-a", transcriptStart: 20,
            transcriptTotal: 48, firstTranscriptID: "entry-20"
        ))
        let maximum = ChatTranscriptPageRequest(
            sessionID: "session-a",
            presentationGeneration: 7,
            runtimeGeneration: "runtime-a",
            before: Int.max,
            expectedTotal: Int.max,
            expectedNextEntryID: nil
        )
        #expect(!maximum.canInstallPage(
            start: Int.max - 1,
            end: Int.max,
            total: Int.max,
            itemCount: 1,
            visibleItemCount: 1
        ))
    }

    @Test("bootstrap configuration stays in Manage Session")
    func hidesBootstrapConfiguration() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"model","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:01Z","kind":"thinkingChange","level":"high"},
          {"id":"user","parentId":"thinking","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"hello"}]}
        ]
        """)

        #expect(ChatTranscriptPresentation.items(in: snapshot).map(\.id) == ["user"])
    }

    @Test("configuration changes after conversation begins remain notifications")
    func retainsLaterChanges() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"hello"}]},
          {"id":"model","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}},
          {"id":"thinking","parentId":"model","timestamp":"2026-01-01T00:00:02Z","kind":"thinkingChange","level":"high"}
        ]
        """)

        #expect(ChatTranscriptPresentation.items(in: snapshot).map(\.id) == ["user", "model", "thinking"])
    }

    @Test("initial hydration and session changes do not manufacture unread responses")
    func unreadBaselinePolicy() throws {
        let first = ChatResponseState(snapshot: try fixture(transcript: "[]"))
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: nil,
            current: first,
            userScrolledAway: true
        ))

        var switchedSnapshot = try fixture(transcript: "[]")
        switchedSnapshot.sessionId = "another-session"
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: first,
            current: ChatResponseState(snapshot: switchedSnapshot),
            userScrolledAway: true
        ))
    }

    @Test("unread observation ignores tool and runtime status while retaining response facts")
    func unreadObservationEquality() throws {
        var snapshot = try fixture(transcript: "[]")
        let baseline = ChatResponseState(snapshot: snapshot)

        snapshot.phase = .running
        snapshot.toolExecutions = [tool("call", "read", startedAt: "2026-01-01T00:00:00Z")]
        snapshot.extensionPresentation.semanticState.statuses = ["provider": "Working"]
        #expect(ChatResponseState(snapshot: snapshot) == baseline)

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"one"}}]}
        """)
        let toolOnly = ChatResponseState(snapshot: snapshot)
        #expect(toolOnly == baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"call","name":"read","arguments":{"path":"two"}}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) == toolOnly)

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"hello"}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"thinking","type":"thinking","text":"considering"}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"image","type":"image","mimeType":"image/png","blobId":"blob"}]}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[],"errorMessage":"failed"}
        """)
        #expect(ChatResponseState(snapshot: snapshot) != baseline)

        snapshot.streaming = nil
        snapshot.transcript = try transcript("""
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"hello"}]}]
        """)
        snapshot.transcriptTotal = 1
        #expect(ChatResponseState(snapshot: snapshot) != baseline)
    }

    @Test("new response marks unread only while scrolled away")
    func unreadResponsePolicy() throws {
        let previous = ChatResponseState(snapshot: try fixture(transcript: "[]"))
        let updated = ChatResponseState(snapshot: try fixture(transcript: """
        [{"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"assistant:0","type":"text","text":"hello"}]}]
        """))
        #expect(ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: previous,
            current: updated,
            userScrolledAway: true
        ))
        #expect(!ChatUnreadResponsePolicy.shouldMarkUnread(
            previous: previous,
            current: updated,
            userScrolledAway: false
        ))
    }

    @Test("tool run identity follows authoritative order rather than opaque ID sorting")
    func toolRunIdentityUsesAuthoritativeOrder() {
        let ordered = ChatToolRunPresentation(tools: [
            toolPresentation("opaque-z-first"),
            toolPresentation("opaque-a-second"),
        ])
        #expect(ordered.id == "tool-run-opaque-z-first")
    }

    @Test("tool detail rows are reverse chronological with stable source fallback")
    func reverseChronologicalToolDetails() {
        let run = ChatToolRunPresentation(tools: [
            toolPresentation("old", startedAt: "2026-01-01T00:00:01Z").descriptor,
            toolPresentation("new", startedAt: "2026-01-01T00:00:03Z").descriptor,
            toolPresentation("latest-without-timestamp").descriptor,
            toolPresentation("middle", startedAt: "2026-01-01T00:00:02Z").descriptor,
        ])

        #expect(run.reverseChronologicalTools.map(\.id) == [
            "middle", "latest-without-timestamp", "new", "old",
        ])
        #expect(ChatToolInvocationOrdering.reverseChronological([
            toolPresentation("old", startedAt: "2026-01-01T00:00:01Z"),
            toolPresentation("new", startedAt: "2026-01-01T00:00:03Z"),
        ]).map(\.id) == ["new", "old"])
    }

    @Test("compaction token counts use compact K shorthand")
    func compactCompactionTokenCounts() {
        #expect(ChatTokenCountPresentation.beforeCompaction(0) == "0 tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(1) == "1 token before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(999) == "999 tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(1_000) == "1K tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(12_300) == "12.3K tokens before compaction")
        #expect(ChatTokenCountPresentation.beforeCompaction(322_486) == "322K tokens before compaction")
    }

    @Test("notification policy separates flat status from detail-bearing summaries")
    func notificationMaterialPolicy() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"compact","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"Condensed context","tokensBefore":1200},
          {"id":"model","parentId":"compact","timestamp":"2026-01-01T00:00:01Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"gpt-5.6-sol"}}
        ]
        """)
        let compact = try #require(ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 8))
        let model = try #require(ChatNotificationPresentation.canonical(snapshot.transcript[1], globalOrdinal: 9))

        #expect(compact.id == "notification-compaction-slot-8")
        #expect(compact.material == .glass)
        #expect(compact.hasDetailSheet)
        #expect(compact.tone == .accent)
        #expect(model.material == .flat)
        #expect(!model.hasDetailSheet)
        #expect(model.detail == "OpenAI Codex / GPT 5.6 Sol")
    }

    @Test("whitespace-only summaries stay flat and noninteractive")
    func whitespaceSummaryIsFlat() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"blank","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"  \\n  ","tokensBefore":1200}
        ]
        """)
        let notification = try #require(
            ChatNotificationPresentation.canonical(snapshot.transcript[0], globalOrdinal: 0)
        )
        #expect(notification.body == nil)
        #expect(notification.material == .flat)
        #expect(!notification.hasDetailSheet)
    }

    @Test("pending compaction shares identity only under exact tail bounds")
    func pendingCompactionContinuity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .compacting
        snapshot.extensionPresentation.semanticState.working = .init(message: nil, visible: true)
        snapshot.transcriptStart = 7
        snapshot.transcriptTotal = 7
        let exact = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(exact.id == "notification-compaction-slot-7")
        #expect(exact.title == "Compacting context")
        #expect(exact.material == .flat)

        snapshot.transcriptTotal = 8
        let malformed = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(malformed.id == "runtime-working")
        #expect(malformed.id != exact.id)

        snapshot.transcriptStart = Int.max
        snapshot.transcriptTotal = Int.max
        snapshot.transcript = [try fixture(transcript: """
        [{"id":"user-max","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"x"}]}]
        """).transcript[0]]
        let maximum = try #require(ChatNotificationPresentation.runtime(in: snapshot).first)
        #expect(maximum.id == "runtime-working")
    }

    @Test("canonical compaction ordinals survive bounded tails and prepends")
    func canonicalCompactionOrdinals() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"compact-a","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"A","tokensBefore":100},
          {"id":"compact-b","parentId":"compact-a","timestamp":"2026-01-01T00:00:01Z","kind":"compaction","summary":"B","tokensBefore":200}
        ]
        """)
        snapshot.transcriptStart = 5
        snapshot.transcriptTotal = 7
        let notifications = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatNotificationPresentation? in
            guard case .notification(let notification) = item else { return nil }
            return notification
        }
        #expect(notifications.map(\.id) == [
            "notification-compaction-slot-5", "notification-compaction-slot-6",
        ])

        snapshot.transcriptStart = 3
        snapshot.transcript.insert(contentsOf: try fixture(transcript: """
        [
          {"id":"older-a","parentId":null,"timestamp":"2025-12-31T23:59:58Z","kind":"modelChange","modelRef":{"provider":"openai-codex","id":"older"}},
          {"id":"older-b","parentId":"older-a","timestamp":"2025-12-31T23:59:59Z","kind":"thinkingChange","level":"low"}
        ]
        """).transcript, at: 0)
        let prepended = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> ChatNotificationPresentation? in
            guard case .notification(let notification) = item,
                  notification.id.hasPrefix("notification-compaction-slot") else { return nil }
            return notification
        }
        #expect(prepended.map(\.id) == notifications.map(\.id))

        snapshot.transcriptTotal = 99
        let malformed = ChatTranscriptPresentation.timeline(in: snapshot).items.compactMap { item -> String? in
            guard case .notification(let notification) = item,
                  notification.semanticID?.hasPrefix("compact-") == true else { return nil }
            return notification.id
        }
        #expect(malformed == [
            "notification-compaction-compact-a", "notification-compaction-compact-b",
        ])
    }

    @Test("duplicate canonical IDs fail safe without ordinal construction trap")
    func duplicateCompactionIDsFailSafe() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"compaction","summary":"A","tokensBefore":100},
          {"id":"duplicate","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"compaction","summary":"B","tokensBefore":200}
        ]
        """)
        snapshot.transcriptStart = 0
        snapshot.transcriptTotal = 2
        let ids = ChatTranscriptPresentation.timeline(in: snapshot).items.map(\.id)
        #expect(ids == [
            "notification-compaction-duplicate", "notification-compaction-duplicate",
        ])
    }

    @Test("prompt images and files share one attachment strip above text")
    func promptAttachmentStrip() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[
            {"id":"user:0","type":"text","text":"What about these?"},
            {"id":"user:1","type":"image","mimeType":"image/jpeg","blobId":"photo"},
            {"id":"user:2","type":"text","text":"notes.pdf","attachment":{"name":"notes.pdf","mimeType":"application/pdf","size":2048}}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let attachments = ChatTranscriptPresentation.attachmentParts(in: item)
        #expect(attachments.map(\.type) == [.image, .text])
        #expect(attachments.last?.attachment?.name == "notes.pdf")
        #expect(attachments.last?.attachment?.size == 2048)
    }

    @Test("consecutive thinking lines become one complete inline run")
    func groupsConsecutiveThinkingLines() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"  Inspecting the transcript  \\nChecking spacing..."},
            {"id":"thinking-2","type":"thinking","text":"Confirming   the grouped lines…\\n..."},
            {"id":"answer","type":"text","text":"Done"}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let parts = ChatTranscriptPresentation.messageParts(in: item)

        #expect(parts.count == 2)
        guard case .thinking(let run) = parts[0] else {
            Issue.record("Expected one thinking run")
            return
        }
        #expect(run.id == "thinking-1")
        #expect(run.segments.map(\.id) == [
            "thinking-1:line:0",
            "thinking-1:line:1",
            "thinking-2:line:0",
            "thinking-2:line:1",
        ])
        #expect(run.segments.map(\.text) == [
            "Inspecting the transcript…",
            "Checking spacing…",
            "Confirming the grouped lines…",
            "…",
        ])
        guard case .content(let answer) = parts[1] else {
            Issue.record("Expected answer after thinking")
            return
        }
        #expect(answer.id == "answer")
    }

    @Test("content boundaries keep thinking runs separate and stable")
    func thinkingRunBoundaries() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"thinking-empty","type":"thinking","text":"  \\n  "},
            {"id":"thinking-2","type":"thinking","text":"Second"}
          ]}
        ]
        """)
        let item = try #require(snapshot.transcript.first)
        let parts = ChatTranscriptPresentation.messageParts(in: item)

        #expect(parts.map(\.id) == ["thinking-thinking-1", "content-call", "thinking-thinking-2"])
        guard case .thinking(let trailingRun) = parts[2] else {
            Issue.record("Expected trailing thinking run")
            return
        }
        #expect(trailingRun.segments.map(\.id) == ["thinking-2:line:0"])
        #expect(trailingRun.segments.map(\.text) == ["Second…"])
    }

    @Test("timeline preserves thinking around an intervening tool")
    func preservesThinkingToolOrder() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"thinking-2","type":"thinking","text":"Second"}
          ]}
        ]
        """)
        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let timeline = candidate.timeline

        #expect(timeline.ids == [
            "assistant",
            "tool-run-call-1",
            "assistant-slice-thinking-thinking-2",
        ])
        guard case .message(let first) = timeline.items[0],
              case .thinking(let firstRun) = first.parts.first,
              case .toolRun(let toolRun) = timeline.items[1],
              case .message(let last) = timeline.items[2],
              case .thinking(let lastRun) = last.parts.first else {
            Issue.record("Expected thinking slices around the tool run")
            return
        }
        #expect(firstRun.segments.map(\.text) == ["First…"])
        let detail = try #require(toolRun.tools.first.flatMap(candidate.toolPayloads.resolving))
        #expect(detail.content == "")
        #expect(detail.request == .object([:]))
        #expect(detail.fallbackContent == .object([:]))
        #expect(lastRun.segments.map(\.text) == ["Second…"])
    }

    @Test("thinking barriers preserve exact order across multiple consolidated tool runs")
    func thinkingBarriersPreserveToolOrder() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[
            {"id":"thinking-1","type":"thinking","text":"First"},
            {"id":"call-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{}},
            {"id":"call-2","type":"toolCall","toolCallId":"call-2","name":"read","arguments":{}},
            {"id":"thinking-2","type":"thinking","text":"Between"},
            {"id":"call-3","type":"toolCall","toolCallId":"call-3","name":"bash","arguments":{}},
            {"id":"thinking-3","type":"thinking","text":"Last"}
          ]}
        ]
        """)
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)

        #expect(timeline.ids == [
            "assistant",
            "tool-run-call-1",
            "assistant-slice-thinking-thinking-2",
            "tool-run-call-3",
            "assistant-slice-thinking-thinking-3",
        ])
        guard case .toolRun(let firstRun) = timeline.items[1],
              case .message(let between) = timeline.items[2],
              case .thinking(let betweenThinking) = between.parts.first,
              case .toolRun(let secondRun) = timeline.items[3] else {
            Issue.record("Expected thinking to split canonical tool runs")
            return
        }
        #expect(firstRun.tools.map(\.id) == ["call-1", "call-2"])
        #expect(betweenThinking.segments.map(\.text) == ["Between…"])
        #expect(secondRun.tools.map(\.id) == ["call-3"])
    }

    @Test("consecutive tool calls collapse into one presentation run")
    func groupsConsecutiveToolCalls() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{"path":"one"}}]},
          {"id":"result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text-1","type":"text","text":"one"}],"toolCallId":"call-1","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"}}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        let timeline = candidate.timeline
        let rendered = timeline.items
        #expect(rendered.count == 1)
        guard case .toolRun(let run) = rendered.first else {
            Issue.record("Expected one grouped tool run")
            return
        }
        #expect(run.tools.map(\.title) == ["read", "bash"])
        let details = run.tools.compactMap(candidate.toolPayloads.resolving)
        #expect(details[0].request == .object(["path": .string("one")]))
        #expect(details[0].response == nil)
        #expect(details[1].request == .object(["command": .string("pwd")]))
        #expect(run.title == "Used 2 tools")
        #expect(timeline.preferredSemanticIDByRenderedID[run.id] == "call-2")
        #expect(timeline.renderedIDBySemanticID["call-1"] == run.id)
        #expect(timeline.renderedIDBySemanticID["call-2"] == run.id)
    }

    @Test("semantic tool anchor survives page-boundary regrouping when the outer row changes")
    func semanticAnchorSurvivesPageBoundaryRegrouping() throws {
        let current = try fixture(transcript: """
        [
          {"id":"assistant-2","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"}}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)
        let before = ChatTranscriptPresentation.timeline(in: current)
        #expect(before.ids == ["tool-run-call-2"])
        #expect(before.preferredSemanticIDByRenderedID["tool-run-call-2"] == "call-2")

        let prepended = try fixture(transcript: """
        [
          {"id":"assistant-1","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part-1","type":"toolCall","toolCallId":"call-1","name":"read","arguments":{"path":"one"}}]},
          {"id":"result-1","parentId":"assistant-1","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text-1","type":"text","text":"one"}],"toolCallId":"call-1","toolName":"read","isError":false},
          {"id":"assistant-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"call-part-2","type":"toolCall","toolCallId":"call-2","name":"bash","arguments":{"command":"pwd"}}]},
          {"id":"result-2","parentId":"assistant-2","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"result-text-2","type":"text","text":"/workspace"}],"toolCallId":"call-2","toolName":"bash","isError":false}
        ]
        """)
        let after = ChatTranscriptPresentation.timeline(in: prepended)
        #expect(after.ids == ["tool-run-call-1"])
        #expect(after.renderedIDBySemanticID["call-2"] == "tool-run-call-1")
    }

    @Test("parallel live tools keep one stable canonical row through settlement")
    func liveToolsKeepStableTimelineIdentity() throws {
        let callOne = "call-1"
        let callTwo = "call-2"
        let callThree = "call-3"
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"test tools"}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
          {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
          {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
        ]}
        """)
        snapshot.toolExecutions = [
            tool(callOne, "bash", startedAt: "2026-01-01T00:00:01Z"),
            tool(callTwo, "read", startedAt: "2026-01-01T00:00:01Z"),
            tool(callThree, "subagent", startedAt: "2026-01-01T00:00:01Z"),
        ]

        let live = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(live.ids == ["user", "streaming", "tool-run-call-1"])
        guard case .toolRun(let liveRun) = live.items.last else {
            Issue.record("Expected a live tool run")
            return
        }
        #expect(liveRun.tools.map(\.id) == [callOne, callTwo, callThree])
        #expect(liveRun.title == "Using 3 tools")

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}}
        ]}
        """)
        snapshot.toolExecutions = [snapshot.toolExecutions[0]]
        let partial = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(partial.ids.last == "tool-run-call-1")

        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
          {"id":"thinking","type":"thinking","text":"Testing tools"},
          {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
          {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
          {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
        ]}
        """)
        snapshot.toolExecutions = [
            tool(callThree, "subagent", startedAt: "2026-01-01T00:00:01Z", order: 2),
            tool(callOne, "bash", startedAt: "2026-01-01T00:00:01Z", order: 0),
            tool(callTwo, "read", startedAt: "2026-01-01T00:00:01Z", order: 1),
        ]
        let expanded = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(expanded.ids.last == partial.ids.last)
        guard case .toolRun(let expandedRun) = expanded.items.last else {
            Issue.record("Expected expanded live tool run")
            return
        }
        #expect(expandedRun.tools.map(\.id) == [callOne, callTwo, callThree])

        snapshot.transcript = try transcript("""
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"user:0","type":"text","text":"test tools"}]},
          {"id":"assistant-tools","parentId":"user","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[
            {"id":"thinking","type":"thinking","text":"Testing tools"},
            {"id":"part-1","type":"toolCall","toolCallId":"\(callOne)","name":"bash","arguments":{"command":"pwd"}},
            {"id":"part-2","type":"toolCall","toolCallId":"\(callTwo)","name":"read","arguments":{"path":"README.md"}},
            {"id":"part-3","type":"toolCall","toolCallId":"\(callThree)","name":"subagent","arguments":{}}
          ]},
          {"id":"result-1","parentId":"assistant-tools","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r1","type":"text","text":"one"}],"toolCallId":"\(callOne)","toolName":"bash","isError":false},
          {"id":"result-2","parentId":"result-1","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r2","type":"text","text":"two"}],"toolCallId":"\(callTwo)","toolName":"read","isError":false},
          {"id":"result-3","parentId":"result-2","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"r3","type":"text","text":"three"}],"toolCallId":"\(callThree)","toolName":"subagent","isError":false}
        ]
        """)
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"All done"}]}
        """)
        snapshot.toolExecutions = snapshot.toolExecutions.map {
            tool($0.toolCallId, $0.toolName, status: .completed, startedAt: $0.startedAt)
        }

        let completing = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(completing.ids == ["user", "assistant-tools", "tool-run-call-1", "streaming"])
        #expect(completing.ids.filter { $0 == "tool-run-call-1" }.count == 1)
        guard case .toolRun(let completedRun) = completing.items[2] else {
            Issue.record("Expected the settled tool run before the response")
            return
        }
        #expect(completedRun.title == "Used 3 tools")

        snapshot.transcript.append(try message("""
        {"id":"assistant-final","parentId":"result-3","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"All done"}]}
        """))
        snapshot.streaming = nil
        snapshot.toolExecutions = []
        let settled = ChatTranscriptPresentation.timeline(in: snapshot)
        #expect(settled.ids == ["user", "assistant-tools", "tool-run-call-1", "assistant-final"])
    }

    @Test("streaming assistant rows keep their visual identity when canonical text settles")
    func streamingSettlementKeepsVisualIdentity() throws {
        var liveSnapshot = try fixture(transcript: "[]")
        liveSnapshot.phase = .running
        liveSnapshot.streaming = try message("""
        {"id":"streaming","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"hello"}]}
        """)
        var settledSnapshot = liveSnapshot
        settledSnapshot.phase = .idle
        settledSnapshot.revision += 1
        settledSnapshot.eventSequence += 1
        settledSnapshot.transcript = [try message("""
        {"id":"assistant-final","parentId":null,"timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"hello"}]}
        """)]
        settledSnapshot.streaming = nil
        let liveTag = ChatTranscriptProjectionTag(snapshot: liveSnapshot, presentationGeneration: 3)
        let settledTag = ChatTranscriptProjectionTag(snapshot: settledSnapshot, presentationGeneration: 3)
        let live = InstalledChatTranscript(
            tag: liveTag,
            timeline: ChatTranscriptPresentation.timeline(in: liveSnapshot),
            runtimeItems: [],
            sourceWindow: .init(snapshot: liveSnapshot)
        )
        let settled = InstalledChatTranscript(
            tag: settledTag,
            timeline: ChatTranscriptPresentation.timeline(in: settledSnapshot),
            runtimeItems: [],
            sourceWindow: .init(snapshot: settledSnapshot)
        )

        let adjusted = ChatTranscriptTransitionPolicy.continuityAdjusted(previous: live, next: settled)
        #expect(adjusted.timeline.ids == ["streaming"])
        #expect(adjusted.timeline.renderedIDBySemanticID["assistant-final"] == "streaming")
    }

    @Test("isolated text streaming tail is identical when no runtime tool is unanchored")
    func isolatedStreamingParity() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"prompt","type":"text","text":"continue"}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = []
        snapshot.streaming = try message("""
        {"id":"streaming","parentId":"user","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"thinking","type":"thinking","text":"Preparing"},{"id":"answer","type":"text","text":"Current answer"}]}
        """)

        let cold = ChatTranscriptPresentation.timeline(in: snapshot)
        let streaming = try #require(snapshot.streaming)
        var baseSnapshot = snapshot
        baseSnapshot.streaming = nil
        let base = ChatTranscriptPresentation.timeline(in: baseSnapshot)
        let live = try #require(ChatTranscriptPresentation.isolatedStreamingTimeline(streaming))
        let incremental = base.appendingLive(live)

        #expect(incremental == cold)
        #expect(incremental.items.canonical.count == base.items.count)
        #expect(incremental.items.live.count == 1)
    }

    @Test("explicit empty tool output never falls back to duplicated request content")
    func explicitEmptyToolOutputPreservesDetailParity() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool(
                "empty-output",
                "read",
                status: .completed,
                startedAt: "2026-01-01T00:00:01Z",
                output: ""
            ),
        ]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first,
              let descriptor = run.tools.first,
              let tool = candidate.toolPayloads.resolving(descriptor) else {
            Issue.record("Expected completed tool row")
            return
        }
        #expect(tool.content == "")
        #expect(tool.fallbackContent == nil)
        #expect(tool.response == .object(["ok": .bool(true)]))
    }

    @Test("live tool order is deterministic when progress events arrive out of order")
    func deterministicLiveToolOrder() throws {
        var snapshot = try fixture(transcript: "[]")
        snapshot.phase = .running
        snapshot.toolExecutions = [
            tool("later", "read", startedAt: "2026-01-01T00:00:01Z", order: 2),
            tool("same-b", "bash", startedAt: "2026-01-01T00:00:01Z", order: 1),
            tool("same-a", "find", startedAt: "2026-01-01T00:00:01Z", order: 0),
        ]
        let timeline = ChatTranscriptPresentation.timeline(in: snapshot)
        guard case .toolRun(let run) = timeline.items.first else {
            Issue.record("Expected deterministic live run")
            return
        }
        #expect(run.tools.map(\.id) == ["same-a", "same-b", "later"])
    }

    @Test("live output, monotonic progress, and execution timing stay auditable")
    func liveToolAuditProjection() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"wait","name":"subagent_wait","arguments":{"id":"child"}}]}
        ]
        """)
        snapshot.phase = .running
        snapshot.toolExecutions = [ToolExecutionState(
            toolCallId: "wait",
            toolName: "subagent_wait",
            order: 0,
            status: .running,
            arguments: .object(["id": .string("child")]),
            partialResult: .object(["content": .array([.object(["type": .string("text"), "text": .string("Waiting 12s · reviewer: read")])])]),
            result: nil,
            output: "Waiting 12s · reviewer: read",
            outputTruncated: true,
            isError: false,
            startedAt: "2026-01-01T00:00:01Z",
            updatedAt: "2026-01-01T00:00:13Z",
            lastProgressAt: "2026-01-01T00:00:13Z",
            progressSequence: 14
        )]

        let candidate = ChatTranscriptProjectionKernel.cold(snapshot: snapshot)
        guard case .toolRun(let run) = candidate.timeline.items.first else {
            Issue.record("Expected live tool run")
            return
        }
        let descriptor = try #require(run.tools.first)
        let tool = try #require(candidate.toolPayloads.resolving(descriptor))
        #expect(tool.content == "Waiting 12s · reviewer: read")
        #expect(tool.outputTruncated)
        #expect(tool.progressSequence == 14)
        #expect(tool.elapsedMilliseconds(at: try #require(ToolTiming.date("2026-01-01T00:00:13Z"))) == 12_000)
        #expect(ToolTiming.format(milliseconds: 0) == "0ms")
        #expect(ToolTiming.format(milliseconds: 99) == "99ms")
        #expect(ToolTiming.format(milliseconds: 100) == "100ms")
        #expect(ToolTiming.format(milliseconds: 999) == "999ms")
        #expect(ToolTiming.format(milliseconds: 1_000) == "1.0s")
        #expect(ToolTiming.format(milliseconds: 478_000) == "7m 58s")
    }

    @Test("tool timing parses cached ISO timestamps with and without fractional seconds")
    func toolTimingISOParsing() throws {
        let whole = try #require(ToolTiming.date("2026-01-01T00:00:01Z"))
        let fractional = try #require(ToolTiming.date("2026-01-01T00:00:01.125Z"))
        #expect(Int((fractional.timeIntervalSince(whole) * 1_000).rounded()) == 125)
        #expect(ToolTiming.intervalMilliseconds(
            start: "2026-01-01T00:00:01.125Z",
            end: "2026-01-01T00:00:02Z"
        ) == 875)
        #expect(ToolTiming.date("not-a-timestamp") == nil)
    }

    @Test("canonical history derives timing when exact runtime metadata is unavailable")
    func canonicalTimingFallback() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"read","name":"read","arguments":{}}]},
          {"id":"result","parentId":"assistant","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"text","type":"text","text":"done"}],"toolCallId":"read","toolName":"read","isError":false,"completedAt":"2026-01-01T00:00:03Z"}
        ]
        """)
        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first,
              let tool = run.tools.first else {
            Issue.record("Expected canonical tool run")
            return
        }
        #expect(tool.durationMs == 2_000)
        #expect(tool.elapsedMilliseconds() == 2_000)
    }

    @Test("Gateway duration is authoritative and tool runs accumulate durations")
    func completedAndAccumulatedTiming() {
        let first = ChatToolPresentation(
            id: "first", title: "edit", subtitle: "Completed", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:01Z", completedAt: "2026-01-01T00:00:03Z",
            durationMs: 25, lastProgressAt: nil, progressSequence: nil
        )
        let second = ChatToolPresentation(
            id: "second", title: "write", subtitle: "Completed", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:04Z", completedAt: "2026-01-01T00:00:07Z",
            durationMs: 40, lastProgressAt: nil, progressSequence: nil
        )
        let run = ChatToolRunPresentation(tools: [first.descriptor, second.descriptor])

        #expect(first.elapsedMilliseconds() == 25)
        #expect(second.elapsedMilliseconds() == 40)
        #expect(run.elapsedMilliseconds() == 65)
    }

    @Test("running Gateway duration does not use the device wall clock")
    func runningGatewayDurationIsAuthoritative() throws {
        let tool = ChatToolPresentation(
            id: "running", title: "bash", subtitle: "Running", request: nil, response: nil,
            content: "", fallbackContent: nil, error: false,
            startedAt: "2026-01-01T00:00:01Z", completedAt: nil,
            durationMs: 237, lastProgressAt: "2026-01-01T00:00:02Z", progressSequence: 2
        )

        let farFuture = try #require(ToolTiming.date("2036-01-01T00:00:01Z"))
        #expect(tool.elapsedMilliseconds(at: farFuture) == 237)
    }

    @Test("conversation content interrupts tool grouping")
    func conversationBreaksToolRuns() throws {
        let snapshot = try fixture(transcript: """
        [
          {"id":"assistant-tool","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"call-part","type":"toolCall","toolCallId":"call","name":"read","arguments":{}}]},
          {"id":"result","parentId":"assistant-tool","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"toolResult","content":[{"id":"result-text","type":"text","text":"done"}],"toolCallId":"call","toolName":"read","isError":false},
          {"id":"assistant-text","parentId":"result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"assistant","content":[{"id":"answer","type":"text","text":"Finished"}]},
          {"id":"bash","parentId":"assistant-text","timestamp":"2026-01-01T00:00:03Z","kind":"bash","command":"pwd","output":"/workspace","exitCode":0,"cancelled":false,"truncated":false}
        ]
        """)

        let rendered = ChatTranscriptPresentation.timeline(in: snapshot).items
        #expect(rendered.count == 3)
        #expect(rendered.map(\.id) == ["tool-run-call", "assistant-text", "bash"])
    }

    @Test("idle snapshots never present retained foreground tools as running")
    func idleRunningToolIsInterrupted() throws {
        var snapshot = try fixture(transcript: """
        [
          {"id":"assistant","parentId":null,"timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"call","type":"toolCall","toolCallId":"wait","name":"subagent_wait","arguments":{}}]}
        ]
        """)
        snapshot.toolExecutions = [tool("wait", "subagent_wait", startedAt: "2026-01-01T00:00:01Z")]

        guard case .toolRun(let run) = ChatTranscriptPresentation.timeline(in: snapshot).items.first else {
            Issue.record("Expected retained tool run")
            return
        }
        #expect(run.title == "Used 1 tool")
        #expect(!run.isRunning)
        #expect(run.tools.first?.subtitle == "Interrupted")
    }

    @Test("entrance geometry follows exact displayed install across desired and identity replacements")
    func entranceGeometryAdmissionPolicy() throws {
        var displayed = try fixture(transcript: "[]")
        let displayedTag = ChatTranscriptProjectionTag(
            snapshot: displayed,
            presentationGeneration: 41,
            canonicalGeneration: 10,
            timelineGeneration: 20
        )
        var desired = displayed
        desired.eventSequence += 1
        let desiredTag = ChatTranscriptProjectionTag(
            snapshot: desired,
            presentationGeneration: 41,
            canonicalGeneration: 10,
            timelineGeneration: 21
        )
        let observation = ChatSemanticFrameObservation(
            layoutEpoch: 7,
            frame: CGRect(x: 0, y: 10, width: 100, height: 30),
            entranceAdmissionTag: displayedTag
        )

        // Model-ahead desired source is intentionally absent from the policy:
        // the displayed A installation remains sufficient admission authority.
        #expect(desiredTag != displayedTag)
        #expect(ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: displayedTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: desiredTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))

        displayed.runtimeGeneration = "replacement-runtime"
        let runtimeReplacement = ChatTranscriptProjectionTag(
            snapshot: displayed,
            presentationGeneration: 41,
            canonicalGeneration: 10,
            timelineGeneration: 20
        )
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: runtimeReplacement,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))
        let presentationReplacement = ChatTranscriptProjectionTag(
            snapshot: desired,
            presentationGeneration: 42,
            canonicalGeneration: 10,
            timelineGeneration: 21
        )
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: presentationReplacement,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .pending
        ))
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: displayedTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 8,
            entranceState: .pending
        ))
        #expect(!ChatEntranceGeometryAdmissionPolicy.admits(
            observation: observation,
            installedTag: displayedTag,
            installedContainsRenderedID: true,
            currentLayoutEpoch: 7,
            entranceState: .admitted
        ))
    }

    @Test("timeline projection closes one aggregate-only performance interval")
    func projectionSignpost() throws {
        let snapshot = try fixture(transcript: """
        [{"id":"user","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"user","content":[{"id":"text","type":"text","text":"Hello"}]}]
        """)
        let signposts = RecordingPerformanceSignposts()

        let timeline = ChatTranscriptPresentation.timeline(
            in: snapshot,
            performanceSignposts: signposts
        )

        #expect(timeline.items.count == 1)
        #expect(signposts.events() == [
            .begin(.chatProjection),
            .end(.chatProjection, .success, PerformanceMetrics(itemCount: 1)),
        ])
    }

    private func toolPresentation(_ id: String, startedAt: String? = nil) -> ChatToolPresentation {
        ChatToolPresentation(
            id: id,
            title: "read",
            subtitle: "Running",
            request: nil,
            response: nil,
            content: "",
            fallbackContent: nil,
            error: false,
            startedAt: startedAt,
            completedAt: nil,
            durationMs: nil,
            lastProgressAt: nil,
            progressSequence: nil
        )
    }

    private func message(_ value: String) throws -> TranscriptItem {
        try JSONDecoder.gateway.decode(TranscriptItem.self, from: Data(value.utf8))
    }

    private func transcript(_ value: String) throws -> [TranscriptItem] {
        try JSONDecoder.gateway.decode([TranscriptItem].self, from: Data(value.utf8))
    }

    private func tool(
        _ id: String,
        _ name: String,
        status: ToolExecutionState.Status = .running,
        startedAt: String,
        order: Int? = nil,
        output: String? = nil
    ) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: id,
            toolName: name,
            order: order,
            status: status,
            arguments: .object([:]),
            partialResult: nil,
            result: status == .running ? nil : .object(["ok": .bool(true)]),
            output: output,
            isError: status == .failed,
            startedAt: startedAt,
            updatedAt: startedAt,
            lastProgressAt: startedAt,
            completedAt: status == .running ? nil : startedAt,
            durationMs: status == .running ? nil : 0,
            progressSequence: 1
        )
    }

    private func fixture(transcript: String) throws -> SessionSnapshot {
        try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data("""
        {
          "sessionId":"session","runtimeGeneration":"generation","revision":1,"eventSequence":1,"phase":"idle","cwd":"/workspace",
          "model":{"provider":"openai-codex","id":"gpt-5.6-sol"},"thinkingLevel":"high","availableThinkingLevels":["off","high"],
          "stats":{"userMessages":1,"assistantMessages":0,"toolCalls":0,"toolResults":0,"totalMessages":1,"tokens":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0},"cost":0},
          "queued":{"steering":[],"followUp":[]},"transcript":\(transcript),"transcriptStart":0,"transcriptTotal":3,
          "toolExecutions":[],"extensionPresentation":{"version":2,"hostEpoch":"host","revision":0,"capabilities":[],"diagnostics":[],"semanticState":{"statuses":{},"working":{"visible":false},"widgets":[],"toolsExpanded":false,"editorRevision":0,"editorText":""},"surfaces":[],"pendingInteractions":[]},"diagnostics":[]
        }
        """.utf8))
    }
}
