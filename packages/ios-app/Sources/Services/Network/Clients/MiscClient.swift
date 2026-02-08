import Foundation

/// Client for miscellaneous RPC methods.
/// Handles system, skills, canvas, worktree, todo, device token, memory, and message operations.
@MainActor
final class MiscClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - System Methods

    func ping() async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let _: SystemPingResult = try await ws.send(
            method: "system.ping",
            params: EmptyParams()
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        return try await ws.send(
            method: "system.getInfo",
            params: EmptyParams()
        )
    }

    // MARK: - Message Methods

    /// Delete a message from a session.
    /// This appends a message.deleted event to the event log.
    /// The message will be filtered out during reconstruction (two-pass).
    func deleteMessage(_ sessionId: String, targetEventId: String, reason: String? = "user_request") async throws -> MessageDeleteResult {
        guard let transport else {
            logger.error("[DELETE] Cannot delete message - WebSocket not connected", category: .session)
            throw RPCClientError.connectionNotEstablished
        }
        let ws = try transport.requireConnection()

        let params = MessageDeleteParams(sessionId: sessionId, targetEventId: targetEventId, reason: reason)
        logger.info("[DELETE] Sending delete request: sessionId=\(sessionId), targetEventId=\(targetEventId)", category: .session)

        let result: MessageDeleteResult = try await ws.send(
            method: "message.delete",
            params: params
        )

        logger.info("[DELETE] Delete succeeded: deletionEventId=\(result.deletionEventId), targetType=\(result.targetType)", category: .session)
        return result
    }

    // MARK: - Memory Methods

    func searchMemory(
        query: String? = nil,
        type: String? = nil,
        source: String? = nil,
        limit: Int = 20
    ) async throws -> MemorySearchResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = MemorySearchParams(
            searchText: query,
            type: type,
            source: source,
            limit: limit
        )

        return try await ws.send(
            method: "memory.search",
            params: params
        )
    }

    func getHandoffs(workingDirectory: String? = nil, limit: Int = 10) async throws -> [Handoff] {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = HandoffsParams(workingDirectory: workingDirectory, limit: limit)
        let result: HandoffsResult = try await ws.send(
            method: "memory.getHandoffs",
            params: params
        )

        return result.handoffs
    }

    /// Get paginated ledger entries for a workspace
    func getLedgerEntries(
        workingDirectory: String,
        limit: Int? = nil,
        offset: Int? = nil,
        tags: [String]? = nil
    ) async throws -> MemoryGetLedgerResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = MemoryGetLedgerParams(
            workingDirectory: workingDirectory,
            limit: limit,
            offset: offset,
            tags: tags
        )

        return try await ws.send(
            method: "memory.getLedger",
            params: params
        )
    }

    // MARK: - Worktree Methods

    /// Get worktree status for a session
    func getWorktreeStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = WorktreeGetStatusParams(sessionId: sessionId)
        return try await ws.send(method: "worktree.getStatus", params: params)
    }

    /// Get worktree status for current session
    func getWorktreeStatus() async throws -> WorktreeGetStatusResult {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (_, sessionId) = try transport.requireSession()
        return try await getWorktreeStatus(sessionId: sessionId)
    }

    /// Commit changes in a session's worktree
    func commitWorktree(sessionId: String, message: String) async throws -> WorktreeCommitResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = WorktreeCommitParams(sessionId: sessionId, message: message)
        let result: WorktreeCommitResult = try await ws.send(method: "worktree.commit", params: params)

        if result.success {
            logger.info("Committed worktree changes: \(result.commitHash ?? "unknown")", category: .session)
        }

        return result
    }

    /// Commit changes in current session's worktree
    func commitWorktree(message: String) async throws -> WorktreeCommitResult {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (_, sessionId) = try transport.requireSession()
        return try await commitWorktree(sessionId: sessionId, message: message)
    }

    /// Merge a session's worktree to a target branch
    func mergeWorktree(
        sessionId: String,
        targetBranch: String,
        strategy: String? = nil
    ) async throws -> WorktreeMergeResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = WorktreeMergeParams(
            sessionId: sessionId,
            targetBranch: targetBranch,
            strategy: strategy
        )
        let result: WorktreeMergeResult = try await ws.send(method: "worktree.merge", params: params)

        if result.success {
            logger.info("Merged worktree to \(targetBranch): \(result.mergeCommit ?? "unknown")", category: .session)
        }

        return result
    }

    /// Merge current session's worktree to a target branch
    func mergeWorktree(targetBranch: String, strategy: String? = nil) async throws -> WorktreeMergeResult {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (_, sessionId) = try transport.requireSession()
        return try await mergeWorktree(sessionId: sessionId, targetBranch: targetBranch, strategy: strategy)
    }

    /// List all worktrees
    func listWorktrees() async throws -> [WorktreeListItem] {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let result: WorktreeListResult = try await ws.send(
            method: "worktree.list",
            params: EmptyParams()
        )

        return result.worktrees
    }

    // MARK: - Skill Methods

    /// List available skills
    func listSkills(sessionId: String? = nil, source: String? = nil) async throws -> SkillListResponse {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SkillListParams(
            sessionId: sessionId ?? transport.currentSessionId,
            source: source
        )
        return try await ws.send(method: "skill.list", params: params)
    }

    /// Get a skill by name
    func getSkill(name: String, sessionId: String? = nil) async throws -> SkillGetResponse {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SkillGetParams(
            sessionId: sessionId ?? transport.currentSessionId,
            name: name
        )
        return try await ws.send(method: "skill.get", params: params)
    }

    /// Refresh skills cache
    func refreshSkills(sessionId: String? = nil) async throws -> SkillRefreshResponse {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SkillRefreshParams(sessionId: sessionId ?? transport.currentSessionId)
        return try await ws.send(method: "skill.refresh", params: params)
    }

    /// Remove a skill from session context
    func removeSkill(sessionId: String, skillName: String) async throws -> SkillRemoveResponse {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = SkillRemoveParams(sessionId: sessionId, skillName: skillName)
        return try await ws.send(method: "skill.remove", params: params)
    }

    // MARK: - Canvas Methods

    /// Get a persisted canvas artifact from the server
    func getCanvas(canvasId: String) async throws -> CanvasGetResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = CanvasGetParams(canvasId: canvasId)
        return try await ws.send(method: "canvas.get", params: params)
    }

    // MARK: - Todo Methods

    /// Get todos for a session
    func listTodos(sessionId: String? = nil) async throws -> TodoListResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let sid: String
        if let sessionId {
            sid = sessionId
        } else {
            let (_, currentSessionId) = try transport.requireSession()
            sid = currentSessionId
        }

        let params = TodoListParams(sessionId: sid)
        return try await ws.send(method: "todo.list", params: params)
    }

    /// Get backlogged tasks for a workspace
    func getBacklog(workspaceId: String, includeRestored: Bool? = nil, limit: Int? = nil) async throws -> TodoGetBacklogResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = TodoGetBacklogParams(
            workspaceId: workspaceId,
            includeRestored: includeRestored,
            limit: limit
        )
        return try await ws.send(method: "todo.getBacklog", params: params)
    }

    /// Restore tasks from backlog to a session
    func restoreFromBacklog(sessionId: String? = nil, taskIds: [String]) async throws -> TodoRestoreResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let sid: String
        if let sessionId {
            sid = sessionId
        } else {
            let (_, currentSessionId) = try transport.requireSession()
            sid = currentSessionId
        }

        let params = TodoRestoreParams(sessionId: sid, taskIds: taskIds)
        return try await ws.send(method: "todo.restore", params: params)
    }

    /// Get count of unrestored backlogged tasks for a workspace
    func getBacklogCount(workspaceId: String) async throws -> Int {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = TodoGetBacklogCountParams(workspaceId: workspaceId)
        let result: TodoGetBacklogCountResult = try await ws.send(method: "todo.getBacklogCount", params: params)
        return result.count
    }

    // MARK: - Device Token Methods (Push Notifications)

    /// Check if this is a production build (for APNS environment)
    private var isProductionBuild: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// Register a device token for push notifications
    func registerDeviceToken(_ deviceToken: String, sessionId: String? = nil, workspaceId: String? = nil) async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let effectiveSessionId = sessionId ?? transport.currentSessionId

        let params = DeviceTokenRegisterParams(
            deviceToken: deviceToken,
            sessionId: effectiveSessionId,
            workspaceId: workspaceId,
            environment: isProductionBuild ? "production" : "sandbox"
        )

        let result: DeviceTokenRegisterResult = try await ws.send(
            method: "device.register",
            params: params
        )

        logger.info("Device token registered: id=\(result.id), created=\(result.created)", category: .notification)
    }

    /// Unregister a device token
    func unregisterDeviceToken(_ deviceToken: String) async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = DeviceTokenUnregisterParams(deviceToken: deviceToken)
        let result: DeviceTokenUnregisterResult = try await ws.send(
            method: "device.unregister",
            params: params
        )

        if result.success {
            logger.info("Device token unregistered", category: .notification)
        }
    }

    // MARK: - Sandbox Methods

    /// List all tracked containers with live status
    func listContainers() async throws -> SandboxListResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        return try await ws.send(
            method: "sandbox.listContainers",
            params: EmptyParams()
        )
    }

    // MARK: - Logs Methods

    /// Export logs to server filesystem at $HOME/.tron/artifacts/ios-logs/
    func exportLogs(content: String, filename: String? = nil) async throws -> LogsExportResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = LogsExportParams(content: content, filename: filename)
        let result: LogsExportResult = try await ws.send(
            method: "logs.export",
            params: params
        )

        logger.info("Logs exported to server: \(result.path) (\(result.bytesWritten) bytes)", category: .general)
        return result
    }
}
