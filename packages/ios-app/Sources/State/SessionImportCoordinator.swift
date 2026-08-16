import Foundation

enum SessionImportPolicy {
    static let maximumBytes = 25 * 1_048_576
}

@MainActor
struct SessionImportFileAccess {
    let startAccessing: (URL) -> Bool
    let size: (URL) throws -> Int
    let copy: (URL, URL, Int) async throws -> Void
    let stopAccessing: (URL) -> Void

    static let live = SessionImportFileAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        size: { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0 else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            return size
        },
        copy: { source, destination, expectedSize in
            do {
                try await BoundedFileCopy.copy(
                    from: source,
                    to: destination,
                    expectedSize: expectedSize
                )
            } catch BoundedFileCopyError.changedSize {
                throw GatewayFailure(
                    code: "invalid_request",
                    message: "The session import changed size while it was being read.",
                    retryable: false,
                    details: nil
                )
            }
        },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

typealias SessionImportUpload = @MainActor (
    _ name: String,
    _ mimeType: String,
    _ fileURL: URL,
    _ byteCount: Int
) async throws -> String

/// Owns the local-file-to-upload import pipeline while the Gateway remains the
/// sole owner of the resulting canonical session.
@MainActor
final class SessionImportCoordinator {
    struct ImportedSession {
        let sessionID: String
        let profileID: String
        fileprivate let lifecycleAdmission: GatewayLifecycleCoordinator.Admission
        var lifecycleGeneration: Int { lifecycleAdmission.generation }
    }

    private struct Admission {
        let lifecycle: GatewayLifecycleCoordinator.Admission
        let profileID: String
    }

    private struct StagedFile {
        let directory: URL
        let file: URL
        let byteCount: Int
    }

    private let lifecycle: GatewayLifecycleCoordinator
    private let mutations: SessionMutationService
    private let fileAccess: SessionImportFileAccess
    private let upload: SessionImportUpload

    init(
        lifecycle: GatewayLifecycleCoordinator,
        mutations: SessionMutationService,
        fileAccess: SessionImportFileAccess = .live,
        upload: @escaping SessionImportUpload
    ) {
        self.lifecycle = lifecycle
        self.mutations = mutations
        self.fileAccess = fileAccess
        self.upload = upload
    }

    func importSession(from url: URL, cwd: String) async throws -> ImportedSession {
        guard let lifecycleAdmission = lifecycle.generationAdmission,
              let profileID = lifecycle.profiles.selected?.id else {
            throw CancellationError()
        }
        let admission = Admission(
            lifecycle: lifecycleAdmission,
            profileID: profileID
        )
        try require(admission)

        let staged = try await stageImportFile(from: url)
        defer { try? FileManager.default.removeItem(at: staged.directory) }
        try require(admission)

        let uploadID = try await upload(
            url.lastPathComponent,
            "application/x-ndjson",
            staged.file,
            staged.byteCount
        )
        try require(admission)

        let sessionID = try await mutations.importSession(uploadID: uploadID, cwd: cwd)
        try require(admission)
        return ImportedSession(
            sessionID: sessionID,
            profileID: admission.profileID,
            lifecycleAdmission: admission.lifecycle
        )
    }

    private func stageImportFile(from source: URL) async throws -> StagedFile {
        let isSecurityScoped = fileAccess.startAccessing(source)
        defer {
            if isSecurityScoped { fileAccess.stopAccessing(source) }
        }
        let size = try fileAccess.size(source)
        guard size > 0, size <= SessionImportPolicy.maximumBytes else {
            throw GatewayFailure(
                code: "invalid_request",
                message: "Session imports must contain 1 byte through 25 MiB.",
                retryable: false,
                details: nil
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tron-session-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [
                    .posixPermissions: 0o700,
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
            let staged = directory.appending(path: "session.jsonl", directoryHint: .notDirectory)
            try await fileAccess.copy(source, staged, size)
            let values = try staged.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, values.fileSize == size else {
                throw GatewayFailure(
                    code: "invalid_request",
                    message: "The session import changed size while it was being read.",
                    retryable: false,
                    details: nil
                )
            }
            return StagedFile(directory: directory, file: staged, byteCount: size)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func requireCurrent(_ imported: ImportedSession) throws {
        try require(Admission(
            lifecycle: imported.lifecycleAdmission,
            profileID: imported.profileID
        ))
    }

    private func require(_ admission: Admission) throws {
        try lifecycle.require(admission.lifecycle)
        guard lifecycle.profiles.selected?.id == admission.profileID else {
            throw CancellationError()
        }
    }
}
