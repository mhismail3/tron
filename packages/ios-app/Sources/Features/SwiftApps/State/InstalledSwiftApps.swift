import Foundation
import Observation
import TronMobileCore

/// The Gateway-bound installed-app catalog and its retained sessions. Reads are
/// disposable and fenced to the latest request; accepted writes belong to a
/// session, not to a sheet or its task cancellation.
@MainActor @Observable
final class InstalledSwiftApps {
    struct Ports {
        let list: @MainActor (String) async throws -> InstalledSwiftAppList
        let open: @MainActor (String, String) async throws -> InstalledSwiftAppSnapshot
        let commit: @MainActor (String, InstalledSwiftAppCommit) async throws -> InstalledSwiftAppAcknowledgement
        let rename: @MainActor (String, String, String) async throws -> InstalledSwiftAppManifest
        let reset: @MainActor (String, String, Int) async throws -> Void
        let remove: @MainActor (String, String, String?) async throws -> Void
        let state: @MainActor (String, String) async throws -> Int
    }

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var apps: [InstalledSwiftAppManifest] = []
    var isEmpty: Bool { apps.isEmpty }
    private(set) var phase: Phase = .idle
    /// Bumped when a retained session is dropped, so rows showing its status refresh.
    private(set) var revision = 0
    @ObservationIgnored private let ports: Ports
    @ObservationIgnored private var sessions: [UUID: InstalledSwiftAppSession] = [:]
    @ObservationIgnored private var requests: [String: UUID] = [:]
    @ObservationIgnored private var listRequest: UUID?
    @ObservationIgnored var onFailure: ((Error) -> Void)?

    init(ports: Ports) { self.ports = ports }

    /// A disposable read of the Gateway's catalog. A later request or sheet
    /// dismissal supersedes it; a failure keeps the last list visible.
    func reload(profileID: String) async {
        let request = UUID()
        listRequest = request
        if isEmpty { phase = .loading }
        do {
            let loaded = try await ports.list(profileID)
            guard listRequest == request else { return }
            guard loaded.apps.count <= 200, Set(loaded.apps.map(\.id)).count == loaded.apps.count else {
                throw InstalledSwiftAppFailure("The Gateway returned an invalid app list.")
            }
            apps = loaded.apps
            phase = .loaded
        } catch is CancellationError {
            if listRequest == request, isEmpty { phase = .idle }
        } catch {
            guard listRequest == request else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// The only way to give up accepted-but-unsaved work, and only on request: the
    /// retained session (with its failure) is dropped so the next open reads the Gateway.
    func discardUnsaved(appID: String, profileID: String) {
        sessions = sessions.filter { !matches($0.value, appID: appID, profileID: profileID) }
        revision &+= 1
    }

    func hasUnsavedChanges(appID: String, profileID: String) -> Bool {
        _ = revision

        return retained(appID: appID, profileID: profileID) != nil
    }

    func open(appID: String, profileID: String,
              prepare: ((InstalledSwiftAppSession) throws -> Void)? = nil) async throws -> InstalledSwiftAppSession {
        let key = key(profileID, appID)
        if let retained = retained(appID: appID, profileID: profileID) { return retained }
        try makeRoom()
        guard requests[key] != nil || requests.count < 200 else { throw InstalledSwiftAppFailure("Too many app reads are in progress.") }
        let request = UUID()
        requests[key] = request
        defer { if requests[key] == request { requests.removeValue(forKey: key) } }
        let snapshot = try await ports.open(profileID, appID).admitted(appID: appID)
        guard !Task.isCancelled, requests[key] == request else { throw CancellationError() }
        // A write accepted during this await owns this identity. A disposable
        // load cannot replace its unsaved projection with an older snapshot.
        if let retained = retained(appID: appID, profileID: profileID) { return retained }
        try makeRoom()
        let session = try InstalledSwiftAppSession(snapshot: snapshot, profileID: profileID,
            commit: { [ports] command in try await ports.commit(profileID, command) },
            onFailure: { [weak self] error in self?.onFailure?(error) })
        // Runtime admission belongs before publication: a failed refresh cannot
        // orphan the still-presented writer. Presented versions remain owned
        // until their views close, even if another reader opens the same app.
        try prepare?(session)
        sessions[session.id] = session
        return session
    }

    func rename(appID: String, profileID: String, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 80, !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw InstalledSwiftAppFailure("A name is 1–80 characters on one line.")
        }
        try requireNoUnsaved(appID: appID, profileID: profileID)
        let manifest = try await ports.rename(profileID, appID, trimmed)
        try requireNoUnsaved(appID: appID, profileID: profileID)
        guard manifest.id == appID else { throw InstalledSwiftAppFailure("The rename result named another app.") }
        retireClean(appID: appID, profileID: profileID)
        replace(manifest)
    }

    /// Clearing data discards unsent changes only after the owner has been told
    /// there are none; unsaved or failed writes block the destructive action.
    func resetData(appID: String, profileID: String) async throws {
        try requireNoUnsaved(appID: appID, profileID: profileID)
        let revision = try await ports.state(profileID, appID)
        try requireNoUnsaved(appID: appID, profileID: profileID)
        try await ports.reset(profileID, appID, revision)
        try requireNoUnsaved(appID: appID, profileID: profileID)
        retireClean(appID: appID, profileID: profileID)
    }

    func remove(appID: String, profileID: String) async throws {
        try requireNoUnsaved(appID: appID, profileID: profileID)
        try await ports.remove(profileID, appID, apps.first(where: { $0.id == appID })?.instanceId)
        retireClean(appID: appID, profileID: profileID)
        apps.removeAll { $0.id == appID }
    }

    private func matches(_ session: InstalledSwiftAppSession, appID: String, profileID: String) -> Bool {
        session.profileID == profileID && session.snapshot.app.id == appID
    }

    private func retained(appID: String, profileID: String) -> InstalledSwiftAppSession? {
        sessions.values.first { matches($0, appID: appID, profileID: profileID) && $0.hasUnsavedChanges }
    }

    private func retireClean(appID: String, profileID: String) {
        sessions = sessions.filter {
            !matches($0.value, appID: appID, profileID: profileID) || $0.value.hasUnsavedChanges || $0.value.isPresented
        }
    }

    private func makeRoom() throws {
        guard sessions.count >= 200 else { return }
        sessions = sessions.filter { $0.value.hasUnsavedChanges || $0.value.isPresented }
        guard sessions.count < 200 else { throw InstalledSwiftAppFailure("Too many apps are open or have unsaved changes. Close them or resolve their writes first.") }
    }

    private func requireNoUnsaved(appID: String, profileID: String) throws {
        guard !hasUnsavedChanges(appID: appID, profileID: profileID) else {
            throw InstalledSwiftAppFailure("This app has changes that are not saved yet. Open it and resolve them first.")
        }
    }

    private func replace(_ manifest: InstalledSwiftAppManifest) {
        if let index = apps.firstIndex(where: { $0.id == manifest.id }) { apps[index] = manifest }
    }

    private func key(_ profileID: String, _ appID: String) -> String { "\(profileID)/\(appID)" }
}

@MainActor @Observable
final class InstalledSwiftAppSession {
    let id = UUID()
    private var presentations = Set<UUID>()
    var isPresented: Bool { !presentations.isEmpty }
    func present(_ id: UUID) { presentations.insert(id) }
    func dismiss(_ id: UUID) { presentations.remove(id) }

    let snapshot: InstalledSwiftAppSnapshot
    let profileID: String
    private(set) var entries: [String: Data]
    private(set) var revision: Int
    private(set) var failure: String?
    private(set) var pending: InstalledSwiftAppCommit?
    private var dirty: [String: Data] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let commit: @MainActor (InstalledSwiftAppCommit) async throws -> InstalledSwiftAppAcknowledgement
    @ObservationIgnored private let onFailure: (Error) -> Void

    var hasUnsavedChanges: Bool { pending != nil || !dirty.isEmpty || failure != nil }

    init(snapshot: InstalledSwiftAppSnapshot, profileID: String,
         commit: @escaping @MainActor (InstalledSwiftAppCommit) async throws -> InstalledSwiftAppAcknowledgement,
         onFailure: @escaping (Error) -> Void) throws {
        self.snapshot = snapshot
        self.profileID = profileID
        self.entries = try Dictionary(uniqueKeysWithValues: snapshot.state.entries.map { ($0.key, try JSONEncoder.gateway.encode($0.value)) })
        self.revision = snapshot.state.revision
        self.commit = commit
        self.onFailure = onFailure
    }

    /// The engine already admits JSON and whole-state bounds before calling
    /// this port. Coalesce only unsent key values; a dispatched command remains
    /// immutable under its stable command ID until its receipt settles.
    func accept(_ writes: [String: Data]) {
        for (key, value) in writes {
            entries[key] = value
            dirty[key] = value
        }
        guard task == nil, failure == nil, !dirty.isEmpty else { return }
        task = Task { [self] in await drain() }
    }

    /// Await existing work, never cancel or replay it on presentation changes.
    func settle() async { await task?.value }

    private func drain() async {
        defer { task = nil }
        while !dirty.isEmpty {
            let keys = Array(dirty.keys.sorted().prefix(256))
            do {
                let batch = try keys.map { key in
                    guard let data = dirty[key] else { throw InstalledSwiftAppFailure("A pending value is missing.") }
                    return InstalledSwiftAppEntry(key: key, value: try JSONDecoder.gateway.decode(JSONValue.self, from: data))
                }
                let command = InstalledSwiftAppCommit(commandId: UUID().uuidString.lowercased(), appId: snapshot.app.id,
                    expectedRevision: revision, expectedSourceRevision: snapshot.app.revision, expectedInstanceId: snapshot.app.instanceId, set: batch)
                pending = command
                for key in keys { dirty.removeValue(forKey: key) }
                let result = try await commit(command)
                guard result.appId == snapshot.app.id, result.revision == revision + 1 else {
                    throw InstalledSwiftAppFailure("The save outcome could not be verified. Do not submit a replacement.")
                }
                revision = result.revision
                pending = nil
            } catch {
                // Both the exact command and newer dirty values remain owned.
                // No automatic reload/retry may discard or double-apply them.
                let message = "Changes are not saved. \(error.localizedDescription)"
                failure = message
                onFailure(InstalledSwiftAppFailure("\(snapshot.app.name): \(message)"))
                return
            }
        }
    }
}
