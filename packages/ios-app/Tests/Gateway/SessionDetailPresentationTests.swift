import Foundation
import Observation
import Synchronization
import SwiftUI
import Testing
import UIKit
@testable import TronMobile

@Suite("Independent session detail facts", .serialized)
@MainActor
struct SessionDetailPresentationTests {
    @Test("real progress advances authority without notifying semantic detail observers")
    func realProgressKeepsSemanticObserversQuiet() async throws {
        try await withModel { model in
            var snapshot = try SessionScenarioBuilder(seed: 8_610).openingTail(targetEncodedBytes: 4_096)
            snapshot.streaming = nil
            model.installHostedSubscribedSnapshot(snapshot)
            let changed = Mutex(false)
            withObservationTracking {
                _ = model.sessionContextPresentation(for: snapshot.sessionId)
                _ = model.sessionHistoryPresentation(for: snapshot.sessionId)
                _ = model.sessionProcessPresentation(for: snapshot.sessionId)
                _ = model.sessionQueuePresentation(for: snapshot.sessionId)
                _ = model.sessionToolDetailSource(for: snapshot.sessionId)
            } onChange: { changed.withLock { $0 = true } }
            let message = try decodeTranscriptFixture(TranscriptItem.self, from: Data("""
            {"id":"progress","parentId":null,"timestamp":"2026-01-01T00:00:00Z","kind":"message","role":"assistant","content":[{"id":"text","type":"text","text":"ordinary streaming text"}]}
            """.utf8))
            await model.handle(event("session.progress", snapshot: snapshot, data: .object([
                "message": try JSONValue.encode(message),
            ])))
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.revision == snapshot.revision + 1)
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.streaming == message)
            #expect(!changed.withLock { $0 })
        }
    }

    @Test("visible tool facts advance independently of a suspended transcript installation")
    func liveToolProgressDoesNotNeedCoveredInstallation() async throws {
        try await withTestWatchdog { @MainActor in
            try await withModel { model in
                var snapshot = try SessionScenarioBuilder(seed: 8_611).openingTail(targetEncodedBytes: 4_096)
                snapshot.phase = .running
                snapshot.streaming = nil
                snapshot.toolExecutions = [tool(output: "before", sequence: 1)]
                snapshot.activeToolSegmentId = nil
                model.installHostedSubscribedSnapshot(snapshot)
                let transcript = ChatTranscriptPresentationStore()
                let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
                #expect(transcript.submit(snapshot: snapshot, tag: tag))
                let installed = try await transcript.waitForInstall(of: tag)
                let retained = try #require(installed.resolveToolDetails(callIDs: ["detail-call"]))
                transcript.suspendPendingWork()
                let changed = Mutex(false)
                withObservationTracking {
                    _ = model.sessionToolDetailSource(for: snapshot.sessionId)
                } onChange: { changed.withLock { $0 = true } }
                await model.handle(event("session.toolProgress", snapshot: snapshot,
                    data: try JSONValue.encode(tool(output: "latest output", sequence: 2))))
                let source = try #require(model.sessionToolDetailSource(for: snapshot.sessionId))
                let details = ChatTranscriptProjectionKernel.detailTools(retained: retained, source: source)
                #expect(changed.withLock { $0 })
                #expect(details.first?.content == "latest output")
                #expect(transcript.installed?.tag == tag)
                #expect(transcript.installed?.resolveToolDetails(callIDs: ["detail-call"])?.first?.content == "before")
                #expect(model.sessionToolDetailSource(for: "another-session") == nil)
            }
        }
    }

    @Test("mounted live detail retains an offline read but retires a replaced runtime")
    func mountedDetailRuntimeLifetime() async throws {
        try await withTestWatchdog { @MainActor in
            try await withModel { model in
                var snapshot = try SessionScenarioBuilder(seed: 8_612).openingTail(targetEncodedBytes: 4_096)
                snapshot.phase = .running
                snapshot.toolExecutions = [tool(output: "last complete output", sequence: 1)]
                model.installHostedAuthoritativeSnapshot(snapshot)
                let transcript = ChatTranscriptPresentationStore()
                let tag = ChatTranscriptProjectionTag(snapshot: snapshot, presentationGeneration: 1)
                #expect(transcript.submit(snapshot: snapshot, tag: tag))
                let installed = try await transcript.waitForInstall(of: tag)
                let tools = try #require(installed.resolveToolDetails(callIDs: ["detail-call"]))
                let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                let previous = scene.windows.first(where: \.isKeyWindow)
                var dismissals = 0
                var appeared = false
                let content = LiveToolRunDetails(
                    initial: ToolRunResolvedState(installationTag: tag, run: ChatToolRunPresentation(tools: tools), tools: tools),
                    detent: .constant(.medium), onDismiss: { dismissals += 1 }
                ).environment(model).onAppear { appeared = true }
                let host = UIHostingController(rootView: content)
                let window = UIWindow(windowScene: scene)
                window.frame = scene.coordinateSpace.bounds
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                for _ in 0..<30 {
                    if appeared { break }
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                #expect(appeared)
                model.installHostedSnapshotWithoutPresentation(snapshot)
                for _ in 0..<3 { try await DisplayFrameScheduler.displayLink.nextFrame() }
                #expect(dismissals == 0)
                snapshot.runtimeGeneration = "replacement-runtime"
                model.installHostedAuthoritativeSnapshot(snapshot)
                for _ in 0..<30 {
                    if dismissals > 0 { break }
                    try await DisplayFrameScheduler.displayLink.nextFrame()
                }
                #expect(dismissals == 1)
            }
        }
    }

    private func event(_ topic: String, snapshot: SessionSnapshot, data: JSONValue) -> GatewayEvent {
        GatewayEvent(type: "event", topic: topic, sessionId: snapshot.sessionId, payload: .object([
            "runtimeGeneration": .string(snapshot.runtimeGeneration),
            "eventSequence": .number(Double(snapshot.eventSequence + 1)),
            "revision": .number(Double(snapshot.revision + 1)), "data": data,
        ]))
    }

    private func tool(output: String, sequence: Int) -> ToolExecutionState {
        ToolExecutionState(
            toolCallId: "detail-call", toolName: "read", order: 0, status: .running,
            arguments: .object(["path": .string("README.md")]), partialResult: nil,
            result: nil, output: output, isError: false,
            startedAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            lastProgressAt: "2026-01-01T00:00:01Z", completedAt: nil,
            durationMs: nil, progressSequence: sequence, toolSegmentId: nil, groupId: nil,
            groupIndex: nil, groupCount: nil, groupFinalized: nil
        )
    }

    private func withModel(_ body: (AppModel) async throws -> Void) async throws {
        let name = "SessionDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appending(path: name)
        let model = AppModel(profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: root))
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await body(model)
            await model.teardown()
        } catch {
            await model.teardown()
            throw error
        }
    }
}
