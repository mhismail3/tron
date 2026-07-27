import CryptoKit
import Foundation

extension Notification.Name {
    /// Explicit user action from the Artifact Inbox into one identified chat draft.
    static let attachArtifactToDraft = Notification.Name("tron.attachArtifactToDraft")
}

/// App-local bridge for the explicit Attach to Draft action.
///
/// The target session is mandatory so multiple mounted chat views cannot all
/// consume the same artifact. The receiving chat remains the only writer of
/// its live draft state.
struct ArtifactDraftAttachmentRequest: Equatable, Sendable {
    let sessionId: String
    let attachment: Attachment
}

func shouldAttachArtifact(
    _ request: ArtifactDraftAttachmentRequest,
    to mountedSessionId: String,
    existingAttachmentIds: Set<UUID>
) -> Bool {
    request.sessionId == mountedSessionId
        && !existingAttachmentIds.contains(request.attachment.id)
}

struct MaterializedWorkerArtifact: Equatable, Sendable {
    let artifact: WorkerArtifactDTO
    let data: Data
    let fileURL: URL
}

actor WorkerArtifactFileCoordinator {
    private let rootURL: URL
    private var materializedURLReferences: [URL: Int] = [:]

    init(rootURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("TronArtifactPreviews", isDirectory: true)) {
        self.rootURL = rootURL
    }

    func materialize(_ artifact: WorkerArtifactDTO, data: Data) throws -> URL {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let extensionValue = URL(fileURLWithPath: artifact.displayName).pathExtension
        let digest = artifact.contentSha256
            .replacingOccurrences(of: "sha256:", with: "")
        let fileName = extensionValue.isEmpty
            ? digest
            : "\(digest).\(extensionValue)"
        let destination = rootURL.appendingPathComponent(fileName)
        if materializedURLReferences[destination] == nil {
            // Replace any previous-process remnant with the already verified
            // bytes before giving Quick Look or Share access to the path.
            try data.write(
                to: destination,
                options: [.atomic, .completeFileProtection]
            )
        }
        materializedURLReferences[destination, default: 0] += 1
        return destination
    }

    func remove(_ url: URL) {
        guard let references = materializedURLReferences[url] else { return }
        if references > 1 {
            materializedURLReferences[url] = references - 1
        } else {
            materializedURLReferences.removeValue(forKey: url)
            try? FileManager.default.removeItem(at: url)
        }
    }

    func removeAll() {
        for url in materializedURLReferences.keys {
            try? FileManager.default.removeItem(at: url)
        }
        materializedURLReferences.removeAll()
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@Observable
@MainActor
final class ArtifactInboxViewModel {
    private(set) var artifacts: [WorkerArtifactDTO] = []
    private(set) var storageAttention: WorkerArtifactStorageAttentionDTO?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private(set) var materialized: [String: MaterializedWorkerArtifact] = [:]
    private(set) var loadingArtifactId: String?
    private(set) var deletingArtifactId: String?
    private(set) var nextOffset: UInt64?

    @ObservationIgnored
    private let files: WorkerArtifactFileCoordinator
    @ObservationIgnored
    private var generation: UInt64 = 0
    @ObservationIgnored
    private var lifecycleGeneration: UInt64 = 0
    @ObservationIgnored
    private var deleteTask: Task<Void, Never>?

    init(files: WorkerArtifactFileCoordinator = WorkerArtifactFileCoordinator()) {
        self.files = files
    }

    func refresh(repository: any WorkerKernelRepository) async {
        generation &+= 1
        let ticket = generation
        isLoading = true
        errorMessage = nil
        do {
            let page = try await repository.artifactDeliveries(limit: 200, offset: 0)
            guard !Task.isCancelled, ticket == generation else { return }
            artifacts = page.artifacts
            storageAttention = page.storageAttention
            nextOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            guard ticket == generation else { return }
            errorMessage = error.localizedDescription
        }
        if ticket == generation {
            isLoading = false
        }
    }

    func loadMoreIfNeeded(
        current artifact: WorkerArtifactDTO,
        repository: any WorkerKernelRepository
    ) async {
        guard artifact.id == artifacts.last?.id,
              let offset = nextOffset,
              !isLoading,
              !isLoadingMore else {
            return
        }
        let ticket = generation
        isLoadingMore = true
        defer {
            if ticket == generation {
                isLoadingMore = false
            }
        }
        do {
            let page = try await repository.artifactDeliveries(limit: 200, offset: offset)
            guard !Task.isCancelled, ticket == generation else { return }
            guard page.nextOffset.map({ $0 > offset }) ?? true else {
                throw EngineConnectionError.invalidResponse
            }
            let existingIds = Set(artifacts.map(\.id))
            artifacts.append(contentsOf: page.artifacts.filter {
                !existingIds.contains($0.id)
            })
            storageAttention = page.storageAttention
            nextOffset = page.nextOffset
        } catch is CancellationError {
            return
        } catch {
            guard ticket == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func load(
        _ artifact: WorkerArtifactDTO,
        repository: any WorkerKernelRepository
    ) async {
        if materialized[artifact.id] != nil {
            return
        }
        let lifecycleTicket = lifecycleGeneration
        loadingArtifactId = artifact.id
        errorMessage = nil
        defer {
            if loadingArtifactId == artifact.id {
                loadingArtifactId = nil
            }
        }
        do {
            let response = try await repository.artifactContent(
                workerId: artifact.workerId,
                artifactId: artifact.artifactId
            )
            guard !Task.isCancelled,
                  lifecycleTicket == lifecycleGeneration else { return }
            guard response.artifact == artifact,
                  artifact.contentReference.kind == "artifact_content_reference",
                  artifact.contentReference.workerId == artifact.workerId,
                  artifact.contentReference.artifactId == artifact.artifactId,
                  artifact.contentReference.contentSha256 == artifact.contentSha256,
                  artifact.contentReference.sizeBytes == artifact.sizeBytes,
                  let data = Data(base64Encoded: response.data),
                  UInt64(data.count) == artifact.sizeBytes,
                  "sha256:\(SHA256.hash(data: data).hexString)" == artifact.contentSha256 else {
                throw EngineConnectionError.invalidResponse
            }
            let fileURL = try await files.materialize(artifact, data: data)
            guard !Task.isCancelled,
                  lifecycleTicket == lifecycleGeneration else {
                await files.remove(fileURL)
                return
            }
            materialized[artifact.id] = MaterializedWorkerArtifact(
                artifact: artifact,
                data: data,
                fileURL: fileURL
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(
        _ artifact: WorkerArtifactDTO,
        repository: any WorkerKernelRepository
    ) {
        deleteTask?.cancel()
        deletingArtifactId = artifact.id
        errorMessage = nil
        deleteTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await repository.deleteArtifact(
                    workerId: artifact.workerId,
                    artifactId: artifact.artifactId,
                    idempotencyKey: .userAction("artifact.delete.\(artifact.id)")
                )
                guard !Task.isCancelled,
                      response.workerId == artifact.workerId,
                      response.artifactId == artifact.artifactId else {
                    return
                }
                artifacts.removeAll { $0.id == artifact.id }
                if let cached = materialized.removeValue(forKey: artifact.id) {
                    await files.remove(cached.fileURL)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            if deletingArtifactId == artifact.id {
                deletingArtifactId = nil
            }
        }
    }

    func attachment(for artifact: WorkerArtifactDTO) -> Attachment? {
        guard let content = materialized[artifact.id] else { return nil }
        return Attachment(
            type: AttachmentType.from(mimeType: artifact.mediaType),
            data: content.data,
            mimeType: artifact.mediaType,
            fileName: artifact.displayName,
            originalSize: content.data.count
        )
    }

    func release(_ artifact: WorkerArtifactDTO) async {
        guard let cached = materialized.removeValue(forKey: artifact.id) else { return }
        await files.remove(cached.fileURL)
    }

    func clearError() {
        errorMessage = nil
    }

    func deactivate() {
        generation &+= 1
        lifecycleGeneration &+= 1
        deleteTask?.cancel()
        deleteTask = nil
        artifacts = []
        materialized = [:]
        nextOffset = nil
        isLoadingMore = false
        loadingArtifactId = nil
        deletingArtifactId = nil
        Task { [files] in
            await files.removeAll()
        }
    }
}

private extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
