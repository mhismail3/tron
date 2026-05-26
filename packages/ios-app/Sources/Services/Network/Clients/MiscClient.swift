import Foundation

/// Client for miscellaneous engine capabilities.
/// Handles system, device token, memory, message, and log operations.
final class MiscClient: EngineDomainClient {

    // MARK: - System Methods

    func ping() async throws {
        _ = try requireTransport().requireConnection()

        let _: SystemPingResult = try await invokeRead(
            "system::ping",
            SystemPingParams(
                protocolVersion: 1,
                clientVersion: AppConstants.canonicalVersion
            )
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_info",
            EmptyParams()
        )
    }

    // MARK: - Update Checks

    /// Force an immediate GitHub Releases probe. Returns the latest release
    /// info (if any); the server caches upstream responses 60s to avoid API
    /// thrash.
    func checkForUpdates() async throws -> SystemCheckForUpdatesResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::check_for_updates",
            EmptyParams()
        )
    }

    /// Snapshot of the updater state + configured settings. Used by update
    /// status surfaces such as the Mac menu bar.
    func getUpdateStatus() async throws -> SystemUpdateStatusResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_update_status",
            EmptyParams()
        )
    }

    // MARK: - Message Methods

    /// Delete a message from a session.
    /// This appends a message.deleted event to the event log.
    /// The message will be filtered out during reconstruction (two-pass).
    func deleteMessage(
        _ sessionId: String,
        targetEventId: String,
        reason: String? = "user_request",
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> MessageDeleteResult {
        _ = try requireTransport().requireConnection()

        let params = MessageDeleteParams(sessionId: sessionId, targetEventId: targetEventId, reason: reason)
        logger.info("[DELETE] Sending delete request: sessionId=\(sessionId), targetEventId=\(targetEventId)", category: .session)

        let result: MessageDeleteResult = try await invokeWrite(
            "message::delete",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        logger.info("[DELETE] Delete succeeded: deletionEventId=\(result.deletionEventId), targetType=\(result.targetType)", category: .session)
        return result
    }

    // MARK: - Memory Methods

    /// Trigger manual memory retention — summarizes the session and appends to the memory log.
    func retainMemory(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws -> MemoryRetainResult {
        _ = try requireTransport().requireConnection()

        let params = MemoryRetainParams(sessionId: sessionId)
        return try await invokeWrite(
            "memory::retain",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

    // MARK: - Device Token Methods (Push Notifications)

    /// Register a device token for push notifications.
    ///
    /// Sends two pieces of routing metadata:
    /// - `bundleId` (from `Bundle.main.bundleIdentifier`) — so the relay
    ///   uses the right APNs topic per build (`com.tron.mobile` vs
    ///   `com.tron.mobile.beta`).
    /// - `environment` (from `APNsEnvironment.current()`) — parsed at
    ///   runtime from `embedded.mobileprovision`, so Xcode-dev-signed
    ///   release builds correctly report `sandbox` instead of lying
    ///   about being `production` via a `#if DEBUG` heuristic.
    func registerDeviceToken(
        _ deviceToken: String,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        _ = try requireTransport().requireConnection()

        let effectiveSessionId = sessionId ?? currentTransport?.currentSessionId
        let bundleId = Bundle.main.bundleIdentifier ?? "com.tron.mobile"
        if Bundle.main.bundleIdentifier == nil {
            logger.error("Bundle.main.bundleIdentifier is nil — falling back to com.tron.mobile", category: .notification)
        }
        let environment = APNsEnvironment.current()

        let params = DeviceTokenRegisterParams(
            deviceToken: deviceToken,
            sessionId: effectiveSessionId,
            workspaceId: workspaceId,
            environment: environment,
            bundleId: bundleId
        )

        let result: DeviceTokenRegisterResult = try await invokeWrite(
            "device::register",
            params,
            idempotencyKey: idempotencyKey,
            context: optionalSessionInvocationContext(effectiveSessionId)
        )

        logger.info(
            "Device token registered: id=\(result.id), created=\(result.created), bundle=\(bundleId), env=\(environment), session=\(effectiveSessionId ?? "nil")",
            category: .notification
        )
    }

    /// Unregister a device token
    func unregisterDeviceToken(_ deviceToken: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        let params = DeviceTokenUnregisterParams(deviceToken: deviceToken)
        let result: DeviceTokenUnregisterResult = try await invokeWrite(
            "device::unregister",
            params,
            idempotencyKey: idempotencyKey
        )

        if result.success {
            logger.info("Device token unregistered", category: .notification)
        }
    }

    // MARK: - Logs Methods

    /// Fetch recent server logs for an explicit user-generated diagnostics bundle.
    func recentLogs(limit: Int = 1000) async throws -> LogsRecentResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "logs::recent",
            LogsRecentParams(limit: min(max(limit, 1), 1000))
        )
    }

    /// Ingest structured client logs into the server database.
    func ingestLogs(entries: [ClientLogEntry], idempotencyKey: EngineIdempotencyKey) async throws -> LogsIngestResult {
        _ = try requireTransport().requireConnection()

        let params = LogsIngestParams(entries: entries)
        let result: LogsIngestResult = try await invokeWrite(
            "logs::ingest",
            params,
            idempotencyKey: idempotencyKey
        )

        return result
    }

    // MARK: - Diagnostics (debug / beta only)

    #if DEBUG || BETA
    /// Fetch a structured snapshot of server identity, session counts,
    /// and the full engine protocol method surface. Debug-only — the production
    /// binary has no UI that consumes it.
    func getDiagnostics() async throws -> SystemDiagnosticsResult {
        _ = try requireTransport().requireConnection()

        return try await invokeRead(
            "system::get_diagnostics",
            EmptyParams()
        )
    }
    #endif
}
