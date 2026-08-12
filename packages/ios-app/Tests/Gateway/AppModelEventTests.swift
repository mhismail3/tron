import Foundation
import Testing
@testable import TronMobile

private final class EventFixtureBundleMarker {}

@Suite("Authoritative gateway event projection")
@MainActor
struct AppModelEventTests {
    @Test("onboarding waits for launch credential resolution")
    func onboardingLaunchResolution() {
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: false,
            connectionState: .unpaired,
            setupComplete: true
        ))
        #expect(!OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: true
        ))
        #expect(OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .unpaired,
            setupComplete: true
        ))
        #expect(OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: true,
            connectionState: .connected,
            setupComplete: false
        ))
    }

    @Test("portable tool and extension events update native session state in sequence")
    func portableSessionEvents() async throws {
        let snapshot = try loadSnapshot()
        let model = AppModel()
        model.selectedSessionID = snapshot.sessionId
        model.snapshots[snapshot.sessionId] = snapshot

        let completedTool: JSONValue = .object([
            "toolCallId": .string("live-tool"), "toolName": .string("bash"), "status": .string("completed"),
            "arguments": .object(["command": .string("build")]), "result": .object(["content": .string("done")]),
            "isError": .bool(false), "startedAt": .string("2026-01-01T00:00:10Z"), "updatedAt": .string("2026-01-01T00:00:12Z"),
        ])
        await model.handle(event(topic: "session.toolProgress", snapshot: snapshot, sequence: 88, data: completedTool))
        #expect(model.selectedSnapshot?.toolExecutions.first?.status == .completed)

        let interactions: JSONValue = .array([
            .object(["id": .string("confirm"), "method": .string("confirm"), "title": .string("Proceed?"), "message": .string("Check")]),
        ])
        await model.handle(event(topic: "session.interactions", snapshot: snapshot, sequence: 89, data: interactions))
        #expect(model.selectedSnapshot?.extensionUI.pendingInteractions.first?.method == .confirm)

        let editor: JSONValue = .object([
            "action": .string("set"), "text": .string("replacement"), "fullText": .string("replacement"), "revision": .number(4),
        ])
        await model.handle(event(topic: "session.editorText", snapshot: snapshot, sequence: 90, data: editor))
        #expect(model.editorRequest?.fullText == "replacement")
        #expect(model.selectedSnapshot?.eventSequence == 90)
    }

    @Test("configured default model is preferred over catalog order")
    func configuredDefaultModel() async {
        let model = AppModel()
        model.models = [
            ModelSummary(provider: "openai-codex", id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark", reasoning: true, input: ["text"], contextWindow: 1, maxTokens: 1, available: true),
            ModelSummary(provider: "openai-codex", id: "gpt-5.6-sol", name: "GPT-5.6 Sol", reasoning: true, input: ["text"], contextWindow: 1, maxTokens: 1, available: true),
        ]
        model.settings = .object([
            "effective": .object([
                "defaultModel": .object(["provider": .string("openai-codex"), "id": .string("gpt-5.6-sol")]),
            ]),
        ])

        #expect(model.configuredDefaultModel?.id == "gpt-5.6-sol")
        #expect(model.preferredAvailableModel?.id == "gpt-5.6-sol")
    }

    @Test("OAuth URL and device-code notifications are retained for native presentation")
    func authEvents() async {
        let model = AppModel()
        await model.handle(GatewayEvent(
            type: "event", topic: "auth.event", sessionId: nil,
            payload: .object([
                "operationId": .string("auth-operation"),
                "event": .object([
                    "type": .string("device_code"), "userCode": .string("ABCD-EFGH"),
                    "verificationUri": .string("https://example.invalid/device"), "expiresInSeconds": .number(600),
                ]),
            ])
        ))
        #expect(model.authEvent?.kind == .deviceCode)
        #expect(model.authEvent?.userCode == "ABCD-EFGH")
    }

    private func event(topic: String, snapshot: SessionSnapshot, sequence: Int, data: JSONValue) -> GatewayEvent {
        GatewayEvent(type: "event", topic: topic, sessionId: snapshot.sessionId, payload: .object([
            "runtimeGeneration": .string(snapshot.runtimeGeneration),
            "eventSequence": .number(Double(sequence)),
            "revision": .number(Double(snapshot.revision + sequence)),
            "data": data,
        ]))
    }

    private func loadSnapshot() throws -> SessionSnapshot {
        let bundle = Bundle(for: EventFixtureBundleMarker.self)
        let url = bundle.url(forResource: "session-snapshot-v2", withExtension: "json")
            ?? bundle.url(forResource: "session-snapshot-v2", withExtension: "json", subdirectory: "protocol-fixtures")
        return try JSONDecoder.gateway.decode(SessionSnapshot.self, from: Data(contentsOf: #require(url)))
    }
}
