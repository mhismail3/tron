import Foundation
import Observation
import TronMobileCore

/// Gateway-bound installed apps. Reads are disposable; accepted action writes
/// belong to the retained session, not to a sheet or its task cancellation.
@MainActor
final class InstalledSwiftApps {
    typealias Open = @MainActor (String, String) async throws -> InstalledSwiftAppSnapshot
    typealias Commit = @MainActor (String, InstalledSwiftAppCommit) async throws -> InstalledSwiftAppAcknowledgement
    private let load: Open
    private let commit: Commit
    private var sessions: [String: InstalledSwiftAppSession] = [:]
    private var requests: [String: UUID] = [:]
    var onFailure: ((Error) -> Void)?

    init(open: @escaping Open, commit: @escaping Commit) {
        self.load = open
        self.commit = commit
    }

    func open(appID: String, profileID: String) async throws -> InstalledSwiftAppSession {
        let key = "\(profileID)/\(appID)"
        if let retained = sessions[key], retained.hasUnsavedChanges { return retained }
        if sessions[key] == nil, sessions.count >= 200 {
            // Clean projections may be discarded, never accepted/failed work.
            sessions = sessions.filter { $0.value.hasUnsavedChanges }
            guard sessions.count < 200 else { throw InstalledSwiftAppFailure("Too many apps have unsaved changes. Resolve them before opening another app.") }
        }
        guard requests[key] != nil || requests.count < 200 else { throw InstalledSwiftAppFailure("Too many app reads are in progress.") }
        let request = UUID()
        requests[key] = request
        defer { if requests[key] == request { requests.removeValue(forKey: key) } }
        let snapshot = try await load(profileID, appID).admitted(appID: appID)
        guard !Task.isCancelled, requests[key] == request else { throw CancellationError() }
        // A write accepted during this await owns this identity. A disposable
        // load cannot replace its unsaved projection with an older snapshot.
        if let retained = sessions[key], retained.hasUnsavedChanges { return retained }
        let session = try InstalledSwiftAppSession(snapshot: snapshot, profileID: profileID,
            commit: { [commit] command in try await commit(profileID, command) },
            onFailure: { [weak self] error in self?.onFailure?(error) })
        sessions[key] = session
        requests.removeValue(forKey: key)
        return session
    }
}

@MainActor @Observable
final class InstalledSwiftAppSession {
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
                    expectedRevision: revision, expectedSourceRevision: snapshot.app.revision, set: batch)
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
