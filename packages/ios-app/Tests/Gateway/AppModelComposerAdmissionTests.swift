import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Composer Gateway capability admission", .serialized)
struct AppModelComposerAdmissionTests {
    @Test("only active command receipts block live composer admission", arguments: [
        "running", "waitingForInput", "completed", "failed", "interrupted", "outcomeUnknown"
    ])
    func commandReceiptAdmission(lifecycle: String) async throws {
        try await withHarness(supportsSkills: true) { model, _, target, scope in
            var snapshot = try #require(model.authoritativeSnapshot(for: target.sessionID))
            snapshot.transcript = try JSONDecoder.gateway.decode([TranscriptItem].self, from: Data("""
            [{"id":"command","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"customEntry","customType":"tron.chat-invocation.v1","semantic":{"version":1,"direction":"ambientStatus","contextEffect":"none","delivery":"stored","visibility":"visible","kind":"command","origin":{"kind":"extension","ownerId":"extension:test","title":"Test","confidence":"adapter"},"invocationId":"invocation","operationId":"operation","sequence":1,"lifecycle":"\(lifecycle)","resourceInvocation":{"source":"extension","name":"test","arguments":""}}}]
            """.utf8))
            snapshot.transcriptStart = 0
            snapshot.transcriptTotal = 1
            model.replaceHostedAuthoritativeSnapshot(snapshot)
            let permitsSend = !["running", "waitingForInput"].contains(lifecycle)
            #expect(model.admitsLiveSessionCommands(target) == permitsSend)
            #expect(model.admitsLiveSessionUploads(target))
            #expect(model.composerDrafts.text(for: scope) == "keep this draft")
        }
    }

    @Test("unsupported skills are rejected before draft and submission mutation", arguments: [false, true])
    func unsupportedSkillRetainsDraft(explicitInvocation: Bool) async throws {
        try await withHarness(supportsSkills: false) { model, socket, target, scope in
            let skill = CommandInfo(name: "skill:retained", description: nil, argumentHint: nil, source: .skill, sourcePath: nil)
            model.composerDrafts.selectResource(skill, for: scope)
            let revision = model.composerDrafts.revision(for: scope)
            let invocation = explicitInvocation
                ? ComposerResourceInvocation(source: .skill, name: "retained", arguments: "keep this draft") : nil
            do {
                _ = try model.beginComposerSubmission(target: target, resourceInvocation: invocation)
                Issue.record("Unsupported skill was admitted")
            } catch let error as GatewayFailure {
                #expect(error.code == "unsupported")
            }
            #expect(model.composerDrafts.text(for: scope) == "keep this draft")
            #expect(model.composerDrafts.revision(for: scope) == revision)
            #expect(model.composerDrafts.selectedResource(for: scope) == skill)
            #expect(!model.composerDrafts.hasPendingSubmission(target: target))
            #expect(await socket.sentFrames().count == 1)
        }
    }

    @Test("skill capability gates only skills, not ordinary prompts", arguments: [false, true])
    func supportedAdmission(supportsSkills: Bool) async throws {
        try await withHarness(supportsSkills: supportsSkills) { model, _, target, scope in
            let invocation = supportsSkills
                ? ComposerResourceInvocation(source: .skill, name: "retained", arguments: "keep this draft") : nil
            let submission = try model.beginComposerSubmission(target: target, resourceInvocation: invocation)
            #expect(submission.resourceInvocation == invocation)
            #expect(model.composerDrafts.hasPendingSubmission(target: target))
            #expect(model.composerDrafts.text(for: scope).isEmpty)
        }
    }

    private func withHarness(
        supportsSkills: Bool,
        operation: @escaping @MainActor @Sendable (AppModel, ScriptedGatewaySocket, SessionPresentationIdentity, ComposerDraftScope) async throws -> Void
    ) async throws {
        let suite = "AppModelComposerAdmissionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let model = AppModel(
            client: client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: root),
            composerDraftStore: ComposerDraftStore(root: root.appending(path: "drafts"))
        )
        let profile = GatewayProfile(id: "profile", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
        let capabilities: [JSONValue] = supportsSkills ? [.string("sessions.v1"), .string("skill-prompt.v1")] : [.string("sessions.v1")]
        do {
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("hello"), "gatewayVersion": .string("1.0.0"), "piVersion": .string("1.0.0"),
                "protocolVersion": .number(5), "minProtocolVersion": .number(5), "machineId": .string("machine"),
                "machineName": .string("Mac"), "gatewayChannel": .string("stable"), "capabilities": .array(capabilities),
            ])))
            try await model.connectHostedGateway(profile: profile, token: "token")
            let snapshot = try SessionScenarioBuilder(seed: 1_248).openingTail(targetEncodedBytes: 10_000)
            model.installHostedSubscribedSnapshot(snapshot)
            let target = try #require(model.mountedPresentationTarget)
            let scope = try #require(model.composerDrafts.scope(for: target))
            #expect(model.admitsLiveSessionCommands(target))
            model.composerDrafts.setText("keep this draft", for: scope)
            try await withTestWatchdog { try await operation(model, socket, target, scope) }
        } catch {
            await model.teardown()
            await client.close()
            throw error
        }
        await model.teardown()
        await client.close()
    }
}
