import Foundation
import Observation

struct WorkspaceChangeGroup: Identifiable, Equatable, Sendable {
    let title: String
    let rows: [SessionWorkspaceChange]
    var id: String { title }
}

struct WorkspaceHistoryRowPresentation: Identifiable, Equatable, Sendable {
    let commit: SessionWorkspaceCommit
    let graph: WorkspaceHistoryGraphRow
    let relativeTimestamp: String
    var id: String { commit.oid }
}

private struct WorkspaceChangeProjection: Sendable {
    let byPath: [String: SessionWorkspaceChange]
    let groups: [WorkspaceChangeGroup]

    init(changes: [SessionWorkspaceChange]) {
        byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { _, newest in newest })
        let definitions: [(String, @Sendable (SessionWorkspaceChange) -> Bool)] = [
            ("Conflicts", { $0.conflicted }),
            ("Staged", { !$0.conflicted && $0.staged }),
            ("Modified", { !$0.conflicted && !$0.staged && !$0.untracked }),
            ("Untracked", { $0.untracked }),
        ]
        groups = definitions.compactMap { title, includes in
            let rows = changes.filter(includes)
            return rows.isEmpty ? nil : WorkspaceChangeGroup(title: title, rows: rows)
        }
    }
}

private struct WorkspaceHistoryProjection: Sendable {
    let rows: [WorkspaceHistoryRowPresentation]
    let references: [String]

    init(commits: [SessionWorkspaceCommit], now: Date) {
        let graphRows = WorkspaceHistoryGraphLayout.rows(for: commits)
        rows = zip(commits, graphRows).map { commit, graph in
            WorkspaceHistoryRowPresentation(
                commit: commit,
                graph: graph,
                relativeTimestamp: GatewayTimestamp.relativeDescription(commit.authoredAt, relativeTo: now)
            )
        }
        references = Array(Set(commits.flatMap(\.decorations))).sorted()
    }
}

@MainActor
@Observable
final class WorkspaceInspectorOwner {
    static let maximumRetainedCommits = 400

    private(set) var inspection: SessionWorkspaceInspection?
    private(set) var directory: SessionWorkspaceDirectory?
    private(set) var commits: [SessionWorkspaceCommit] = []
    private(set) var changesByPath: [String: SessionWorkspaceChange] = [:]
    private(set) var changeGroups: [WorkspaceChangeGroup] = []
    private(set) var historyRows: [WorkspaceHistoryRowPresentation] = []
    private(set) var historyReferences: [String] = []
    private(set) var historyCursor: String?
    private(set) var historyRevision: String?
    private(set) var loadingInspection = false
    private(set) var loadingDirectory = false
    private(set) var loadingHistory = false
    var currentPath = ""
    var historyScope: SessionWorkspaceHistoryScope = .currentBranch

    private var inspectionError: String?
    private var directoryError: String?
    private var historyError: String?
    private var inspectionGeneration: UInt64 = 0
    private var directoryGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var inspectionTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    var errorMessage: String? { directoryError ?? historyError ?? inspectionError }
    var hasLoadedHistory: Bool { historyRevision != nil }

    func loadInitial(service: WorkspaceInspectionService, sessionID: String) async {
        async let inspectionLoad: Void = refreshInspection(service: service, sessionID: sessionID, initial: true)
        async let directoryLoad: Void = loadDirectory(service: service, sessionID: sessionID, path: currentPath)
        _ = await (inspectionLoad, directoryLoad)
    }

    func refreshInspection(
        service: WorkspaceInspectionService,
        sessionID: String,
        initial: Bool = false
    ) async {
        inspectionGeneration &+= 1
        let generation = inspectionGeneration
        inspectionTask?.cancel()
        loadingInspection = initial && inspection == nil
        let previousRepositoryIdentity = repositoryIdentity(inspection?.repository)
        inspectionTask = Task {
            defer {
                if inspectionGeneration == generation {
                    loadingInspection = false
                    inspectionTask = nil
                }
            }
            do {
                let value = try await service.inspect(sessionID: sessionID)
                guard inspectionGeneration == generation, !Task.isCancelled else { return }
                if inspection?.revision != value.revision {
                    let projection = await Task.detached(priority: .userInitiated) {
                        WorkspaceChangeProjection(changes: value.repository?.changes ?? [])
                    }.value
                    guard inspectionGeneration == generation, !Task.isCancelled else { return }
                    let nextIdentity = repositoryIdentity(value.repository)
                    inspection = value
                    changesByPath = projection.byPath
                    changeGroups = projection.groups
                    if previousRepositoryIdentity != nil, previousRepositoryIdentity != nextIdentity {
                        resetHistory()
                    }
                }
                if inspectionError != nil { inspectionError = nil }
            } catch is CancellationError {
                return
            } catch {
                guard inspectionGeneration == generation, !Task.isCancelled else { return }
                inspectionError = error.localizedDescription
            }
        }
        await inspectionTask?.value
    }

    func loadDirectory(
        service: WorkspaceInspectionService,
        sessionID: String,
        path: String
    ) async {
        directoryGeneration &+= 1
        let generation = directoryGeneration
        directoryTask?.cancel()
        loadingDirectory = directory == nil
        directoryTask = Task {
            defer {
                if directoryGeneration == generation {
                    loadingDirectory = false
                    directoryTask = nil
                }
            }
            do {
                let value = try await service.list(sessionID: sessionID, path: path)
                guard directoryGeneration == generation, !Task.isCancelled else { return }
                currentPath = path
                directory = value
                if directoryError != nil { directoryError = nil }
            } catch is CancellationError {
                return
            } catch {
                guard directoryGeneration == generation, !Task.isCancelled else { return }
                directoryError = error.localizedDescription
            }
        }
        await directoryTask?.value
    }

    func reloadCurrentDirectory(service: WorkspaceInspectionService, sessionID: String) async {
        await loadDirectory(service: service, sessionID: sessionID, path: currentPath)
    }

    func selectHistoryScope(
        _ scope: SessionWorkspaceHistoryScope,
        service: WorkspaceInspectionService,
        sessionID: String
    ) async {
        guard historyScope != scope || !hasLoadedHistory else { return }
        historyScope = scope
        resetHistory()
        await loadHistory(service: service, sessionID: sessionID, append: false)
    }

    func loadHistory(
        service: WorkspaceInspectionService,
        sessionID: String,
        append: Bool
    ) async {
        guard historyTask == nil else { return }
        if append, historyCursor == nil { return }
        historyGeneration &+= 1
        let generation = historyGeneration
        historyTask?.cancel()
        loadingHistory = !hasLoadedHistory
        let scope = historyScope
        let cursor = append ? historyCursor : nil
        historyTask = Task {
            defer {
                if historyGeneration == generation {
                    loadingHistory = false
                    historyTask = nil
                }
            }
            do {
                let page = try await service.history(
                    sessionID: sessionID,
                    scope: scope,
                    cursor: cursor
                )
                guard historyGeneration == generation,
                      historyScope == scope,
                      !Task.isCancelled else { return }
                var nextCommits: [SessionWorkspaceCommit]
                if append, historyRevision == page.revision {
                    let existing = Set(commits.map(\.oid))
                    nextCommits = commits + page.commits.filter { !existing.contains($0.oid) }
                } else {
                    nextCommits = page.commits
                }
                if nextCommits.count > Self.maximumRetainedCommits {
                    nextCommits = Array(nextCommits.prefix(Self.maximumRetainedCommits))
                }
                let projection = await Task.detached(priority: .userInitiated) {
                    WorkspaceHistoryProjection(commits: nextCommits, now: .now)
                }.value
                guard historyGeneration == generation,
                      historyScope == scope,
                      !Task.isCancelled else { return }
                commits = nextCommits
                historyRows = projection.rows
                historyReferences = projection.references
                historyRevision = page.revision
                historyCursor = nextCommits.count < Self.maximumRetainedCommits ? page.nextCursor : nil
                if historyError != nil { historyError = nil }
            } catch is CancellationError {
                return
            } catch {
                guard historyGeneration == generation, historyScope == scope, !Task.isCancelled else { return }
                if append, (error as? GatewayFailure)?.retryable == true {
                    resetHistory()
                }
                historyError = error.localizedDescription
            }
        }
        await historyTask?.value
    }

    func resetHistory() {
        historyGeneration &+= 1
        historyTask?.cancel()
        historyTask = nil
        commits = []
        historyRows = []
        historyReferences = []
        historyCursor = nil
        historyRevision = nil
        historyError = nil
        loadingHistory = false
    }

    func cancel() {
        inspectionGeneration &+= 1
        directoryGeneration &+= 1
        historyGeneration &+= 1
        inspectionTask?.cancel()
        directoryTask?.cancel()
        historyTask?.cancel()
        inspectionTask = nil
        directoryTask = nil
        historyTask = nil
        loadingInspection = false
        loadingDirectory = false
        loadingHistory = false
    }

    private func repositoryIdentity(_ repository: SessionWorkspaceRepository?) -> String? {
        repository.map { "\($0.root):\($0.head ?? "unborn"):\($0.branch ?? "detached")" }
    }
}
