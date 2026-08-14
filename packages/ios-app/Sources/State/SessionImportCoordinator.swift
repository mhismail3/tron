import Foundation

@MainActor
struct SessionImportFileAccess {
    let startAccessing: (URL) -> Bool
    let read: (URL) throws -> Data
    let stopAccessing: (URL) -> Void

    static let live = SessionImportFileAccess(
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        read: { try Data(contentsOf: $0, options: .mappedIfSafe) },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

typealias SessionImportUpload = @MainActor (
    _ name: String,
    _ mimeType: String,
    _ data: Data
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

        let isSecurityScoped = fileAccess.startAccessing(url)
        defer {
            if isSecurityScoped { fileAccess.stopAccessing(url) }
        }

        let data = try fileAccess.read(url)
        try require(admission)

        let uploadID = try await upload(
            url.lastPathComponent,
            "application/x-ndjson",
            data
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
