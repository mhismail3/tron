import Foundation

/// Client for miscellaneous RPC methods.
/// Handles system, device token, memory, message, and log operations.
final class MiscClient: RPCDomainClient {

    // MARK: - System Methods

    func ping() async throws {
        let ws = try requireTransport().requireConnection()

        let _: SystemPingResult = try await ws.send(
            method: "system.ping",
            params: EmptyParams()
        )
    }

    func getSystemInfo() async throws -> SystemInfoResult {
        let ws = try requireTransport().requireConnection()

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
        let ws = try requireTransport().requireConnection()

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

    /// Trigger manual memory retention — summarizes the session and appends to the memory log.
    func retainMemory(sessionId: String) async throws -> MemoryRetainResult {
        let ws = try requireTransport().requireConnection()

        let params = MemoryRetainParams(sessionId: sessionId)
        return try await ws.send(method: "memory.retain", params: params)
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
    func registerDeviceToken(_ deviceToken: String, sessionId: String? = nil, workspaceId: String? = nil) async throws {
        let ws = try requireTransport().requireConnection()

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

        let result: DeviceTokenRegisterResult = try await ws.send(
            method: "device.register",
            params: params
        )

        logger.info(
            "Device token registered: id=\(result.id), created=\(result.created), bundle=\(bundleId), env=\(environment), session=\(effectiveSessionId ?? "nil")",
            category: .notification
        )
    }

    /// Unregister a device token
    func unregisterDeviceToken(_ deviceToken: String) async throws {
        let ws = try requireTransport().requireConnection()

        let params = DeviceTokenUnregisterParams(deviceToken: deviceToken)
        let result: DeviceTokenUnregisterResult = try await ws.send(
            method: "device.unregister",
            params: params
        )

        if result.success {
            logger.info("Device token unregistered", category: .notification)
        }
    }

    #if DEBUG || BETA
    // MARK: - Logs Methods

    /// Ingest structured client logs into the server database.
    func ingestLogs(entries: [ClientLogEntry]) async throws -> LogsIngestResult {
        let ws = try requireTransport().requireConnection()

        let params = LogsIngestParams(entries: entries)
        let result: LogsIngestResult = try await ws.send(
            method: "logs.ingest",
            params: params
        )

        logger.info("Ingested \(result.inserted) log entries into server database", category: .general)
        return result
    }
    #endif
}
