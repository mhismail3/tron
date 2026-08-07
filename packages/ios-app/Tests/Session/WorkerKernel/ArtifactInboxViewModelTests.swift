import CryptoKit
import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Artifact Inbox View Model Tests")
struct ArtifactInboxViewModelTests {
    @Test("Refresh projects durable artifacts and total database pressure")
    func refreshProjectsArtifactInbox() async throws {
        let fixture = fixtureArtifact()
        let repository = ArtifactRepositoryStub(
            page: WorkerArtifactPageDTO(
                artifacts: [fixture],
                returned: 1,
                total: 1,
                nextOffset: nil,
                storageAttention: WorkerArtifactStorageAttentionDTO(
                    state: "attention",
                    artifactBytes: fixture.sizeBytes,
                    databaseBytes: 450_000_000,
                    databaseBudgetBytes: 536_870_912,
                    overBudget: false,
                    message: "Storage needs attention."
                )
            ),
            content: WorkerArtifactContentDTO(
                artifact: fixture,
                data: "aGVsbG8="
            )
        )
        let model = ArtifactInboxViewModel()

        await model.refresh(repository: repository)

        #expect(model.artifacts == [fixture])
        #expect(model.storageAttention?.requiresAttention == true)
        #expect(model.storageAttention?.databaseBytes == 450_000_000)
    }

    @Test("Exact content is hash verified and becomes a normal draft attachment")
    func contentBecomesAttachment() async throws {
        let fixture = fixtureArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = WorkerArtifactFileCoordinator(rootURL: root)
        let repository = ArtifactRepositoryStub(
            page: emptyPage(),
            content: WorkerArtifactContentDTO(
                artifact: fixture,
                data: "aGVsbG8="
            )
        )
        let model = ArtifactInboxViewModel(files: files)

        await model.load(fixture, repository: repository)

        let materialized = try #require(model.materialized[fixture.id])
        #expect(materialized.data == Data("hello".utf8))
        #expect(FileManager.default.fileExists(atPath: materialized.fileURL.path))
        #expect(materialized.fileURL.lastPathComponent == fixture.displayName)
        let attachment = try #require(model.attachment(for: fixture))
        #expect(attachment.type == .document)
        #expect(attachment.mimeType == "text/markdown")
        #expect(attachment.fileName == "report.md")
        #expect(attachment.data == Data("hello".utf8))

        await model.release(fixture)
        #expect(model.materialized[fixture.id] == nil)
        #expect(!FileManager.default.fileExists(atPath: materialized.fileURL.path))
    }

    @Test("Corrupt content never enters preview or draft state")
    func corruptContentIsRejected() async throws {
        let fixture = fixtureArtifact()
        let repository = ArtifactRepositoryStub(
            page: emptyPage(),
            content: WorkerArtifactContentDTO(
                artifact: fixture,
                data: "dGFtcGVyZWQ="
            )
        )
        let model = ArtifactInboxViewModel()

        await model.load(fixture, repository: repository)

        #expect(model.materialized[fixture.id] == nil)
        #expect(model.attachment(for: fixture) == nil)
        #expect(model.errorMessage != nil)
    }

    @Test("Attach to Draft targets exactly one mounted session and deduplicates")
    func attachmentRequestIsSessionScoped() {
        let attachment = Attachment(
            id: UUID(),
            type: .document,
            data: Data("hello".utf8),
            mimeType: "text/plain",
            fileName: "note.txt"
        )
        let request = ArtifactDraftAttachmentRequest(
            sessionId: "session-a",
            attachment: attachment
        )

        #expect(shouldAttachArtifact(
            request,
            to: "session-a",
            existingAttachmentIds: []
        ))
        #expect(!shouldAttachArtifact(
            request,
            to: "session-b",
            existingAttachmentIds: []
        ))
        #expect(!shouldAttachArtifact(
            request,
            to: "session-a",
            existingAttachmentIds: [attachment.id]
        ))
    }

    @Test("Mismatched content-reference identity never reaches native file custody")
    func mismatchedContentReferenceIsRejected() async throws {
        let fixture = fixtureArtifact(referenceArtifactId: "different-artifact")
        let repository = ArtifactRepositoryStub(
            page: emptyPage(),
            content: WorkerArtifactContentDTO(
                artifact: fixture,
                data: "aGVsbG8="
            )
        )
        let model = ArtifactInboxViewModel()

        await model.load(fixture, repository: repository)

        #expect(model.materialized[fixture.id] == nil)
        #expect(model.errorMessage != nil)
    }

    @Test("Shared content keeps its preview file until the final owner releases it")
    func sharedPreviewContentIsReferenceCounted() async throws {
        let fixture = fixtureArtifact()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = WorkerArtifactFileCoordinator(rootURL: root)
        let data = Data("hello".utf8)
        let staleURL = try await files.materialize(fixture, data: data)
        await files.remove(staleURL)
        try FileManager.default.createDirectory(
            at: staleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: staleURL)

        let firstURL = try await files.materialize(fixture, data: data)
        let secondURL = try await files.materialize(fixture, data: data)

        #expect(firstURL == secondURL)
        #expect(try Data(contentsOf: firstURL) == data)
        await files.remove(firstURL)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        await files.remove(secondURL)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test("Equal content in distinct artifacts has independent preview custody")
    func equalContentArtifactsDoNotShareCleanupOwnership() async throws {
        let first = fixtureArtifact(
            artifactId: "report-1",
            displayName: "first.md"
        )
        let second = fixtureArtifact(
            artifactId: "report-2",
            displayName: "second.md"
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = WorkerArtifactFileCoordinator(rootURL: root)
        let data = Data("hello".utf8)

        let firstURL = try await files.materialize(first, data: data)
        let secondURL = try await files.materialize(second, data: data)

        #expect(firstURL != secondURL)
        #expect(firstURL.lastPathComponent == "first.md")
        #expect(secondURL.lastPathComponent == "second.md")
        await files.remove(firstURL)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(try Data(contentsOf: secondURL) == data)
        await files.remove(secondURL)
    }

    @Test("Artifact pages append once when the final visible row is reached")
    func paginationAppendsUniqueArtifacts() async throws {
        let first = fixtureArtifact()
        let second = fixtureArtifact(artifactId: "report-2")
        let firstPage = WorkerArtifactPageDTO(
            artifacts: [first],
            returned: 1,
            total: 2,
            nextOffset: 1,
            storageAttention: normalAttention()
        )
        let secondPage = WorkerArtifactPageDTO(
            artifacts: [second],
            returned: 1,
            total: 2,
            nextOffset: nil,
            storageAttention: normalAttention()
        )
        let repository = ArtifactRepositoryStub(
            page: firstPage,
            content: WorkerArtifactContentDTO(artifact: first, data: "aGVsbG8="),
            additionalPages: [1: secondPage]
        )
        let model = ArtifactInboxViewModel()

        await model.refresh(repository: repository)
        await model.loadMoreIfNeeded(current: first, repository: repository)

        #expect(model.artifacts == [first, second])
        #expect(model.nextOffset == nil)
    }

    @Test("Delete is explicit and removes only the selected artifact")
    func explicitDeleteReconcilesInbox() async throws {
        let fixture = fixtureArtifact()
        let repository = ArtifactRepositoryStub(
            page: WorkerArtifactPageDTO(
                artifacts: [fixture],
                returned: 1,
                total: 1,
                nextOffset: nil,
                storageAttention: normalAttention()
            ),
            content: WorkerArtifactContentDTO(
                artifact: fixture,
                data: "aGVsbG8="
            )
        )
        let model = ArtifactInboxViewModel()
        await model.refresh(repository: repository)

        let deleted = await model.delete(fixture, repository: repository)

        #expect(deleted)
        #expect(model.artifacts.isEmpty)
        #expect(repository.deletedArtifactIds == [fixture.id])
    }

    @Test("Failed deletion keeps the artifact and exposes a retryable error")
    func failedDeleteKeepsArtifactVisible() async throws {
        let fixture = fixtureArtifact()
        let repository = ArtifactRepositoryStub(
            page: WorkerArtifactPageDTO(
                artifacts: [fixture],
                returned: 1,
                total: 1,
                nextOffset: nil,
                storageAttention: normalAttention()
            ),
            content: WorkerArtifactContentDTO(
                artifact: fixture,
                data: "aGVsbG8="
            ),
            deleteError: EngineConnectionError.notConnected
        )
        let model = ArtifactInboxViewModel()
        await model.refresh(repository: repository)

        let deleted = await model.delete(fixture, repository: repository)

        #expect(!deleted)
        #expect(model.artifacts == [fixture])
        #expect(model.errorMessage != nil)
        #expect(model.deletingArtifactId == nil)
    }

    @Test("Markdown uses native Tron rendering while binary files use Quick Look")
    func previewContentSelectsCohesiveRenderer() {
        #expect(
            ArtifactPreviewContent.resolve(
                mediaType: "text/markdown; charset=utf-8",
                displayName: "report.md",
                data: Data("# Report".utf8)
            ) == .markdown("# Report")
        )
        #expect(
            ArtifactPreviewContent.resolve(
                mediaType: "application/json",
                displayName: "report.json",
                data: Data("{\"ok\":true}".utf8)
            ) == .text("{\"ok\":true}", monospaced: true)
        )
        #expect(
            ArtifactPreviewContent.resolve(
                mediaType: "application/pdf",
                displayName: "report.pdf",
                data: Data([0x25, 0x50, 0x44, 0x46])
            ) == .quickLook
        )
    }

    @Test("Large Markdown remains complete selectable text without rich block expansion")
    func largeMarkdownUsesBoundedTextRenderer() {
        let text = String(
            repeating: "# Heading\nBody\n",
            count: ArtifactPreviewContent.maximumRichMarkdownBytes / 10
        )

        #expect(
            ArtifactPreviewContent.resolve(
                mediaType: "text/markdown",
                displayName: "large.md",
                data: Data(text.utf8)
            ) == .text(text, monospaced: false)
        )
    }

    private func fixtureArtifact(
        artifactId: String = "report-1",
        referenceArtifactId: String? = nil,
        displayName: String = "report.md"
    ) -> WorkerArtifactDTO {
        let data = Data("hello".utf8)
        let hash = "sha256:" + SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return WorkerArtifactDTO(
            workerId: "document-artifact",
            artifactId: artifactId,
            displayName: displayName,
            mediaType: "text/markdown",
            sizeBytes: UInt64(data.count),
            contentSha256: hash,
            contentReference: WorkerArtifactContentReferenceDTO(
                kind: "artifact_content_reference",
                workerId: "document-artifact",
                artifactId: referenceArtifactId ?? artifactId,
                contentSha256: hash,
                sizeBytes: UInt64(data.count)
            ),
            sourceInvocationId: "worker_run_1",
            sourceWorkerVersion: "v1",
            traceId: "trace-1",
            createdAt: "2026-07-27T08:00:00Z"
        )
    }

    private func normalAttention() -> WorkerArtifactStorageAttentionDTO {
        WorkerArtifactStorageAttentionDTO(
            state: "normal",
            artifactBytes: 0,
            databaseBytes: 1,
            databaseBudgetBytes: 536_870_912,
            overBudget: false,
            message: nil
        )
    }

    private func emptyPage() -> WorkerArtifactPageDTO {
        WorkerArtifactPageDTO(
            artifacts: [],
            returned: 0,
            total: 0,
            nextOffset: nil,
            storageAttention: normalAttention()
        )
    }
}

@MainActor
final class ArtifactRepositoryStub: WorkerKernelRepository {
    let pages: [UInt64: WorkerArtifactPageDTO]
    let content: WorkerArtifactContentDTO
    let deleteError: Error?
    private(set) var deletedArtifactIds: [String] = []

    init(
        page: WorkerArtifactPageDTO,
        content: WorkerArtifactContentDTO,
        additionalPages: [UInt64: WorkerArtifactPageDTO] = [:],
        deleteError: Error? = nil
    ) {
        var pages = additionalPages
        pages[0] = page
        self.pages = pages
        self.content = content
        self.deleteError = deleteError
    }

    func artifactDeliveries(
        limit: UInt16,
        offset: UInt64
    ) async throws -> WorkerArtifactPageDTO {
        #expect(limit == 200)
        guard let page = pages[offset] else {
            throw EngineConnectionError.invalidResponse
        }
        return page
    }

    func artifactContent(
        workerId: String,
        artifactId: String
    ) async throws -> WorkerArtifactContentDTO {
        #expect(workerId == content.artifact.workerId)
        #expect(artifactId == content.artifact.artifactId)
        return content
    }

    func deleteArtifact(
        workerId: String,
        artifactId: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerArtifactDeleteDTO {
        if let deleteError { throw deleteError }
        deletedArtifactIds.append("\(workerId):\(artifactId)")
        return WorkerArtifactDeleteDTO(
            workerId: workerId,
            artifactId: artifactId,
            deleted: true
        )
    }

    func engineSurfaceSnapshot(
        sessionId _: String?,
        relevanceQuery _: String?
    ) async throws -> EngineIntrospectionSnapshotDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workers(includeRetired _: Bool) async throws -> WorkerListResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func inspectWorker(_: String) async throws -> WorkerInspectResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workerRuns(
        workerId _: String?,
        originSessionId _: String?,
        limit _: UInt64,
        offset _: UInt64?
    ) async throws -> WorkerRunsResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func workerInbox(
        workerId _: String?,
        limit _: UInt64,
        offset _: UInt64?,
        attentionOnly _: Bool
    ) async throws -> WorkerInboxResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func invokeWorker(
        workerId _: String,
        input _: AnyCodable,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func invokeWorkerFromSession(
        workerId _: String,
        input _: AnyCodable,
        originSessionId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func enqueueWorker(
        workerId _: String,
        input _: AnyCodable,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func cancelWorkerInvocation(
        invocationId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func awaitWorkerInvocation(
        invocationId _: String,
        timeoutSeconds _: UInt8
    ) async throws -> WorkerAwaitResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func retryWorkerInvocation(
        invocationId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerInvocationDTO {
        throw EngineConnectionError.invalidResponse
    }

    func setWorkerEnabled(
        _: Bool,
        workerId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        throw EngineConnectionError.invalidResponse
    }

    func stopWorker(
        workerId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        throw EngineConnectionError.invalidResponse
    }

    func rollbackWorker(
        workerId _: String,
        version _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerRollbackResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func retireWorker(
        workerId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerSummaryDTO {
        throw EngineConnectionError.invalidResponse
    }

    func purgeWorker(
        workerId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerPurgeResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func setWorkersStopped(
        _: Bool,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerStopAllResultDTO {
        throw EngineConnectionError.invalidResponse
    }

    func rotateWorkerWebhook(
        workerId _: String,
        triggerId _: String,
        idempotencyKey _: EngineIdempotencyKey
    ) async throws -> WorkerWebhookCredentialDTO {
        throw EngineConnectionError.invalidResponse
    }

    func ensureWorkerEventSubscriptions() async throws {}
}
