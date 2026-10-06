import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import TronMobileCore
@testable import TronMobile

/// Scripted Gateway boundary coverage for the Entry Detail's summary/take flows:
/// immediate summary receipts and job queries, conflict details, explicit retry
/// against the latest revision, and visibility of K4's owned tag-job state. These
/// tests do not replace mounted-view interaction coverage.
@MainActor
final class KnowledgeDetailInteractionTests: XCTestCase {
    func testSummaryStartIsImmediateAndReceiptCanBeQueriedAndReplayed() async throws {
        let fixture = ProcessSheetGatewayFixture()
        let (model, cleanup) = try makeModel(fixture)
        addTeardownBlock { await cleanup() }
        try await fixture.connect(model: model, capabilities: ["knowledge.v1", KnowledgeLibraryCapability.libraryRows, "knowledge-curation.v1"])

        let record = sourceRecord()
        let job = KnowledgeCurationJob(commandId: "summary-command", operation: "summary", sourceId: record.id, status: "running", startedAt: "2026-01-01T00:00:00Z", finishedAt: nil, revisionId: nil, code: nil, reason: nil)
        let start = Task { try await model.knowledge.summarize(sourceID: record.id, expectedRevision: record.revisionId, commandID: job.commandId) }
        try await fixture.waitForRequest(at: 1)
        let first = try await request(at: 1, method: "knowledge.source.summarize", socket: fixture.socket)
        XCTAssertEqual(first.objectValue?["params"]?.objectValue?["commandId"], .string(job.commandId))
        try await fixture.respond(at: 1, method: "knowledge.source.summarize", result: try JSONValue.encode(KnowledgeSourceSummaryStart(job: job, record: record)))
        let startedJob = try await start.value.job
        XCTAssertEqual(startedJob.status, "running")

        // A replacement detail asks for job state instead of relying on the
        // original start response remaining in presentation-local state.
        let reopen = Task { try await model.knowledge.curationJobs(sourceID: record.id) }
        try await fixture.waitForRequest(at: 2)
        try await fixture.respond(at: 2, method: "knowledge.curation.jobs", result: try JSONValue.encode(KnowledgeCurationJobsResponse(jobs: [job], running: 1, failed: 0)))
        let reopened = try await reopen.value
        XCTAssertEqual(reopened.jobs.first?.status, "running")

        // A repeated start reuses its command ID and returns the same job receipt.
        let duplicate = Task { try await model.knowledge.summarize(sourceID: record.id, expectedRevision: record.revisionId, commandID: job.commandId) }
        try await fixture.waitForRequest(at: 3)
        let repeated = try await request(at: 3, method: "knowledge.source.summarize", socket: fixture.socket)
        XCTAssertEqual(repeated.objectValue?["params"]?.objectValue?["commandId"], .string(job.commandId))
        try await fixture.respond(at: 3, method: "knowledge.source.summarize", result: try JSONValue.encode(KnowledgeSourceSummaryStart(job: job, record: record)))
        let duplicateStart = try await duplicate.value
        XCTAssertEqual(duplicateStart.job.commandId, job.commandId)

        let done = KnowledgeCurationJob(commandId: job.commandId, operation: "summary", sourceId: record.id, status: "done", startedAt: job.startedAt, finishedAt: "2026-01-01T00:00:01Z", revisionId: "revision-summary", code: nil, reason: nil)
        let resumed = Task { try await model.knowledge.curationJobs(sourceID: record.id) }
        try await fixture.waitForRequest(at: 4)
        try await fixture.respond(at: 4, method: "knowledge.curation.jobs", result: try JSONValue.encode(KnowledgeCurationJobsResponse(jobs: [done], running: 0, failed: 0)))
        let resumedJobs = try await resumed.value
        XCTAssertEqual(resumedJobs.jobs.first?.revisionId, "revision-summary")
    }

    func testTakeConflictReturnsCurrentTextRetryRevisionAndTagJobStatus() async throws {
        let fixture = ProcessSheetGatewayFixture()
        let (model, cleanup) = try makeModel(fixture)
        addTeardownBlock { await cleanup() }
        try await fixture.connect(model: model, capabilities: ["knowledge.v1", KnowledgeLibraryCapability.libraryRows, "knowledge-curation.v1"])

        let record = sourceRecord()
        var localDraft = "Do not drop this draft"
        let conflictTask = Task { try await model.knowledge.saveTake(sourceID: record.id, expectedRevision: record.revisionId, text: localDraft, commandID: "take-conflict") }
        try await fixture.waitForRequest(at: 1)
        let conflictRequest = try await request(at: 1, method: "knowledge.source.take", socket: fixture.socket)
        XCTAssertEqual(conflictRequest.objectValue?["params"]?.objectValue?["text"], .string(localDraft))
        let requestID = try XCTUnwrap(conflictRequest.objectValue?["id"]?.stringValue)
        await fixture.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(requestID), "ok": .bool(false),
            "error": .object(["code": .string("conflict"), "message": .string("Source revision changed"), "retryable": .bool(false),
                              "details": .object(["currentRevision": .string("revision-remote"), "currentTake": .string("Remote current take")])]),
        ])))
        do { _ = try await conflictTask.value; XCTFail("Expected stale revision conflict") }
        catch let failure as GatewayFailure {
            XCTAssertEqual(failure.code, "conflict")
            XCTAssertEqual(failure.details?.objectValue?["currentTake"]?.stringValue, "Remote current take")
        }
        XCTAssertEqual(localDraft, "Do not drop this draft", "the test caller retains its draft while inspecting the conflict")

        // A deliberate retry uses a fresh command ID and current exact revision.
        localDraft = "Do not drop this draft"
        let saved = KnowledgeRecord(schemaVersion: 1, id: record.id, revisionId: "revision-saved", kind: .source, scope: record.scope,
                                    createdAt: record.createdAt, updatedAt: record.updatedAt, provenance: record.provenance, temporal: nil,
                                    relations: [], content: .source(sourceContent(take: localDraft)))
        let retry = Task { try await model.knowledge.saveTake(sourceID: record.id, expectedRevision: "revision-remote", text: localDraft, commandID: "take-retry") }
        try await fixture.waitForRequest(at: 2)
        let retryRequest = try await request(at: 2, method: "knowledge.source.take", socket: fixture.socket)
        XCTAssertEqual(retryRequest.objectValue?["params"]?.objectValue?["expectedRevision"], .string("revision-remote"))
        try await fixture.respond(at: 2, method: "knowledge.source.take", result: try JSONValue.encode(KnowledgeMutationResult(record: saved, stateRevision: 3)))
        let retryResult = try await retry.value
        XCTAssertEqual(retryResult.record.revisionId, "revision-saved")

        // K4 job status, not a client-side timer, is the signal for tag progress.
        let tagJob = KnowledgeCurationJob(commandId: "tag-after-take", operation: "tags", sourceId: record.id, status: "running", startedAt: "2026-01-01T00:00:02Z", finishedAt: nil, revisionId: nil, code: nil, reason: nil)
        let jobs = Task { try await model.knowledge.curationJobs(sourceID: record.id) }
        try await fixture.waitForRequest(at: 3)
        try await fixture.respond(at: 3, method: "knowledge.curation.jobs", result: try JSONValue.encode(KnowledgeCurationJobsResponse(jobs: [tagJob], running: 1, failed: 0)))
        let runningTagJobs = try await jobs.value
        XCTAssertEqual(runningTagJobs.jobs.first?.operation, "tags")

        let staleRow = Task { try await model.knowledge.sourceRows(ids: [record.id]) }
        try await fixture.waitForRequest(at: 4)
        let stalePage = try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: [KnowledgeRowFixture.rowJSON(id: record.id, revisionId: "revision-saved", tagsStale: true)]).utf8))
        try await fixture.respond(at: 4, method: "knowledge.list", result: stalePage)
        let stalePageResult = try await staleRow.value
        XCTAssertTrue(stalePageResult.rows.first?.tagsStale ?? false)

        let completeTagJob = KnowledgeCurationJob(commandId: tagJob.commandId, operation: "tags", sourceId: record.id, status: "done", startedAt: tagJob.startedAt, finishedAt: "2026-01-01T00:00:03Z", revisionId: "revision-tagged", code: nil, reason: nil)
        let completedJobs = Task { try await model.knowledge.curationJobs(sourceID: record.id) }
        try await fixture.waitForRequest(at: 5)
        try await fixture.respond(at: 5, method: "knowledge.curation.jobs", result: try JSONValue.encode(KnowledgeCurationJobsResponse(jobs: [completeTagJob], running: 0, failed: 0)))
        let completedJobResponse = try await completedJobs.value
        XCTAssertEqual(completedJobResponse.jobs.first?.status, "done")

        let freshRow = Task { try await model.knowledge.sourceRows(ids: [record.id]) }
        try await fixture.waitForRequest(at: 6)
        let freshPage = try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: [KnowledgeRowFixture.rowJSON(id: record.id, revisionId: "revision-tagged", tagsStale: false, tags: [("updated-tag", "Updated tag")])]).utf8))
        try await fixture.respond(at: 6, method: "knowledge.list", result: freshPage)
        let freshPageResult = try await freshRow.value
        let row = try XCTUnwrap(freshPageResult.rows.first)
        XCTAssertFalse(row.tagsStale)
        XCTAssertEqual(row.tags?.first?.label, "Updated tag")
    }

    func testTypingDuringAcceptedTakeSaveSchedulesLatestDraftAgainstReturnedRevision() async throws {
        let fixture = ProcessSheetGatewayFixture()
        let (model, cleanup) = try makeModel(fixture)
        addTeardownBlock { await cleanup() }
        try await fixture.connect(model: model, capabilities: ["knowledge.v1", KnowledgeLibraryCapability.libraryRows, "knowledge-curation.v1"])

        let record = sourceRecord(take: "Original take")
        try await withHostedDetail(record: record, model: model) { controller in
            // Drain the detail's initial bounded status, row, and job reads.
            for index in 1...3 {
                try await fixture.waitForRequest(at: index)
                let sent = await fixture.socket.sentFrames()
                let request = try JSONDecoder.gateway.decode(JSONValue.self, from: sent[index])
                let method = try XCTUnwrap(request.objectValue?["method"]?.stringValue)
                switch method {
                case "knowledge.status":
                    try await fixture.respond(at: index, method: method, result: try JSONValue.encode(self.knowledgeStatus()))
                case "knowledge.list":
                    try await fixture.respond(at: index, method: method, result: try self.rowPage(record))
                case "knowledge.curation.jobs":
                    try await fixture.respond(at: index, method: method, result: try JSONValue.encode(KnowledgeCurationJobsResponse(jobs: [], running: 0, failed: 0)))
                default:
                    XCTFail("Unexpected initial detail request: \(method)")
                }
            }

            let editor = try await self.waitForTextEditor(in: controller.view)
            editor.text = "First draft"
            editor.delegate?.textViewDidChange?(editor)
            try await fixture.waitForRequest(at: 4)
            let firstRequest = try await self.request(at: 4, method: "knowledge.source.take", socket: fixture.socket)
            XCTAssertEqual(firstRequest.objectValue?["params"]?.objectValue?["text"], .string("First draft"))

            // Type while the first accepted mutation is still awaiting its receipt.
            editor.text = "Latest draft"
            editor.delegate?.textViewDidChange?(editor)
            try await Task.sleep(for: .milliseconds(750))
            let firstSaved = self.sourceRecord(revision: "revision-take-1", take: "First draft")
            try await fixture.respond(at: 4, method: "knowledge.source.take", result: try JSONValue.encode(KnowledgeMutationResult(record: firstSaved, stateRevision: 2)))

            var latestTakeIndex: Int?
            for index in 5..<12 {
                try await fixture.waitForRequest(at: index)
                let sent = await fixture.socket.sentFrames()
                let request = try JSONDecoder.gateway.decode(JSONValue.self, from: sent[index])
                let method = try XCTUnwrap(request.objectValue?["method"]?.stringValue)
                if method == "knowledge.source.take",
                   request.objectValue?["params"]?.objectValue?["text"] == .string("Latest draft") {
                    latestTakeIndex = index
                    XCTAssertEqual(request.objectValue?["params"]?.objectValue?["expectedRevision"], .string("revision-take-1"))
                    break
                }
                switch method {
                case "knowledge.list":
                    try await fixture.respond(at: index, method: method, result: try self.rowPage(firstSaved))
                case "knowledge.curation.jobs":
                    try await fixture.respond(at: index, method: method, result: try JSONValue.encode(KnowledgeCurationJobsResponse(jobs: [], running: 0, failed: 0)))
                default:
                    XCTFail("Unexpected request before latest take save: \(method)")
                }
            }
            let secondIndex = try XCTUnwrap(latestTakeIndex, "the latest edit must be retried after the in-flight receipt settles")
            let secondSaved = self.sourceRecord(revision: "revision-take-2", take: "Latest draft")
            try await fixture.respond(at: secondIndex, method: "knowledge.source.take", result: try JSONValue.encode(KnowledgeMutationResult(record: secondSaved, stateRevision: 3)))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editor.text, "Latest draft", "receipt reconciliation must not reset the actively edited TextEditor")
        }
    }

    private func withHostedDetail(
        record: KnowledgeRecord,
        model: AppModel,
        inspect: (UIViewController) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Entry Detail mounted")
        let origin = model.knowledgePresentationIdentity
        let detail = NavigationStack {
            KnowledgeDetailView(record: record, origin: origin, onChanged: {}, onOpenDraft: { _ in }, onOpenSession: { _, _ in })
        }
        .environment(model)
        .environment(\.tronPresentationActivity, .active)
        let host = UIHostingController(rootView: KnowledgeDetailSheetFixture(content: detail.onAppear { appeared.fulfill() }))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await awaitHostedEvents([appeared])
        let controller = try XCTUnwrap(host.presentedViewController)
        controller.view.layoutIfNeeded()
        var failure: Error?
        do { try await inspect(controller) } catch { failure = error }
        await withCheckedContinuation { continuation in host.dismiss(animated: false) { continuation.resume() } }
        if let failure { throw failure }
    }

    private func makeModel(_ fixture: ProcessSheetGatewayFixture) throws -> (AppModel, @MainActor @Sendable () async -> Void) {
        let name = "KnowledgeDetailInteractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(try JSONEncoder.gateway.encode([fixture.profile]), forKey: "gatewayProfiles.v1")
        defaults.set(fixture.profile.id, forKey: "selectedGateway.v1")
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: name)
        let model = AppModel(client: fixture.client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: cacheRoot))
        let cleanup: @MainActor @Sendable () async -> Void = {
            await model.teardown(); await fixture.client.close()
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        return (model, cleanup)
    }

    private func request(at index: Int, method: String, socket: ScriptedGatewaySocket) async throws -> JSONValue {
        let frames = await socket.sentFrames()
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: frames[index])
        XCTAssertEqual(frame.objectValue?["method"]?.stringValue, method)
        return frame
    }

    private func sourceRecord(revision: String = "revision-source", take: String? = nil) -> KnowledgeRecord {
        KnowledgeRecord(schemaVersion: 1, id: "source-fixture", revisionId: revision, kind: .source, scope: .research,
                        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                        provenance: KnowledgeProvenance(actor: .user, source: nil, sessionId: nil, branchId: nil, invocationId: nil, evidence: []),
                        temporal: nil, relations: [], content: .source(sourceContent(take: take)))
    }

    private func rowPage(_ record: KnowledgeRecord) throws -> JSONValue {
        try JSONDecoder.gateway.decode(JSONValue.self, from: Data(KnowledgeRowFixture.pageJSON(rows: [KnowledgeRowFixture.rowJSON(id: record.id, revisionId: record.revisionId, hasTake: true, tagsStale: false)]).utf8))
    }

    private func knowledgeStatus() -> KnowledgeStatus {
        let vocabulary = KnowledgeTagVocabulary(revision: 1, tags: [], guidelines: "")
        let config = KnowledgeConfig(schemaVersion: 1, revision: 1,
                                     eligibility: KnowledgeEligibility(allSessions: nil, sessionIds: [], projectIds: [], excludedSessionIds: [], excludedProjectIds: []),
                                     observation: KnowledgeObservationLimits(enabled: false, model: nil, maxInputChars: 6_000, maxOutputChars: 2_000, timeoutMs: 12_000, maxAttempts: 1),
                                     maximumSearchResults: 10, currentInterests: [], tagVocabulary: vocabulary)
        let coverage = KnowledgeCoverageSummary(observedCount: 0, emptyCount: 0, excludedCount: 0, pendingCount: 0, failedCount: 0, unavailableCount: 0, remainingCount: 0)
        return KnowledgeStatus(available: true, state: "ready", stateRevision: 1, recordCount: 1, coverageCount: 0, coverage: coverage, suppressedCount: 0, pendingCleanupCount: 0, config: config, observationConfigured: false, detail: nil)
    }

    private func waitForTextEditor(in root: UIView) async throws -> UITextView {
        for _ in 0..<100 {
            if let editor = views(of: UITextView.self, in: root).first { return editor }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GatewayFailure(code: "test_editor_missing", message: "Entry Detail TextEditor was not mounted", retryable: false, details: nil)
    }

    private func views<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }

    private func sourceContent(take: String? = nil) -> KnowledgeSourceContent {
        KnowledgeSourceContent(title: "Synthetic source", uri: "https://example.test", text: "Saved evidence", object: nil,
                               mediaType: "text/html", captureDisposition: .complete, annotations: nil,
                               sourcePublishedAt: nil, sourceSavedAt: "2026-01-01T00:00:00Z", capturedAt: "2026-01-01T00:00:00Z",
                               origin: nil, origins: nil, identity: nil, assessment: nil,
                               contentSummary: nil, admission: nil,
                               take: take.map { KnowledgeSourceTake(text: $0, confirmed: true, updatedAt: "2026-01-01T00:00:02Z") })
    }
}

@MainActor
private struct KnowledgeDetailSheetFixture<Content: View>: View {
    let content: Content
    @State private var presented = true

    var body: some View {
        Color.clear.sheet(isPresented: $presented) { content }
    }
}
