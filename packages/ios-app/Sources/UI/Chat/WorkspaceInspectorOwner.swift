import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceInspectorOwner {
    private(set) var inspection: SessionWorkspaceInspection?
    private(set) var directory: SessionWorkspaceDirectory?
    private(set) var commits: [SessionWorkspaceCommit] = []
    private(set) var historyCursor: String?
    private(set) var historyRevision: String?
    private(set) var loadingInspection = false
    private(set) var loadingDirectory = false
    private(set) var loadingHistory = false
    private(set) var refreshing = false
    private(set) var errorMessage: String?
    var currentPath = ""
    var historyScope: SessionWorkspaceHistoryScope = .currentBranch

    private var inspectionGeneration: UInt64 = 0
    private var directoryGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private var inspectionTask: Task<Void, Never>?
    private var directoryTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    func loadInitial(service: WorkspaceInspectionService, sessionID: String) async {
        await refreshInspection(service: service, sessionID: sessionID, initial: true)
        guard !Task.isCancelled else { return }
        await loadDirectory(service: service, sessionID: sessionID, path: currentPath)
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
        refreshing = !loadingInspection
        let previousRepositoryIdentity = inspection?.repository.map { "\($0.root):\($0.head ?? "unborn"): \($0.branch ?? "detached")" }
        inspectionTask = Task {
            do {
                let value = try await service.inspect(sessionID: sessionID)
                guard self.inspectionGeneration == generation, !Task.isCancelled else { return }
                let nextIdentity = value.repository.map { "\($0.root):\($0.head ?? "unborn"): \($0.branch ?? "detached")" }
                inspection = value
                errorMessage = nil
                if previousRepositoryIdentity != nil, previousRepositoryIdentity != nextIdentity {
                    resetHistory()
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.inspectionGeneration == generation, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            guard self.inspectionGeneration == generation else { return }
            loadingInspection = false
            refreshing = false
            inspectionTask = nil
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
        currentPath = path
        directoryTask = Task {
            do {
                let value = try await service.list(sessionID: sessionID, path: path)
                guard self.directoryGeneration == generation,
                      self.currentPath == path,
                      !Task.isCancelled else { return }
                directory = value
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.directoryGeneration == generation, self.currentPath == path else { return }
                errorMessage = error.localizedDescription
            }
            guard self.directoryGeneration == generation else { return }
            loadingDirectory = false
            directoryTask = nil
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
        guard historyScope != scope || commits.isEmpty else { return }
        historyScope = scope
        resetHistory()
        await loadHistory(service: service, sessionID: sessionID, append: false)
    }

    func loadHistory(
        service: WorkspaceInspectionService,
        sessionID: String,
        append: Bool
    ) async {
        guard !loadingHistory else { return }
        if append, historyCursor == nil { return }
        historyGeneration &+= 1
        let generation = historyGeneration
        historyTask?.cancel()
        loadingHistory = true
        let scope = historyScope
        let cursor = append ? historyCursor : nil
        historyTask = Task {
            do {
                let page = try await service.history(
                    sessionID: sessionID,
                    scope: scope,
                    cursor: cursor
                )
                guard self.historyGeneration == generation,
                      self.historyScope == scope,
                      !Task.isCancelled else { return }
                if append, historyRevision == page.revision {
                    let existing = Set(commits.map(\.oid))
                    commits.append(contentsOf: page.commits.filter { !existing.contains($0.oid) })
                } else {
                    commits = page.commits
                }
                historyRevision = page.revision
                historyCursor = page.nextCursor
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard self.historyGeneration == generation, self.historyScope == scope else { return }
                if append, (error as? GatewayFailure)?.retryable == true {
                    resetHistory()
                }
                errorMessage = error.localizedDescription
            }
            guard self.historyGeneration == generation else { return }
            loadingHistory = false
            historyTask = nil
        }
        await historyTask?.value
    }

    func resetHistory() {
        historyGeneration &+= 1
        historyTask?.cancel()
        historyTask = nil
        commits = []
        historyCursor = nil
        historyRevision = nil
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
        refreshing = false
    }
}
