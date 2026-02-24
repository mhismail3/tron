import Foundation

/// Client for cron scheduling RPC methods.
@MainActor
final class CronClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Job Management

    /// List cron jobs with optional filters.
    func listJobs(enabled: Bool? = nil, tags: [String]? = nil, workspaceId: String? = nil) async throws -> CronListResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronListParams(enabled: enabled, tags: tags, workspaceId: workspaceId)
        return try await ws.send(method: "cron.list", params: params)
    }

    /// Get a single job with runtime state and recent runs.
    func getJob(jobId: String) async throws -> CronGetResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronGetParams(jobId: jobId)
        return try await ws.send(method: "cron.get", params: params)
    }

    /// Create a new cron job.
    func createJob(_ job: CronCreateJobParams) async throws -> CronCreateResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronCreateParams(job: job)
        return try await ws.send(method: "cron.create", params: params)
    }

    /// Partial-update an existing cron job.
    func updateJob(
        jobId: String,
        name: String? = nil,
        description: String? = nil,
        enabled: Bool? = nil,
        schedule: CronScheduleDTO? = nil,
        payload: CronPayloadDTO? = nil,
        delivery: [CronDeliveryDTO]? = nil,
        overlapPolicy: String? = nil,
        misfirePolicy: String? = nil,
        maxRetries: Int? = nil,
        autoDisableAfter: Int? = nil,
        tags: [String]? = nil,
        workspaceId: String? = nil
    ) async throws -> CronUpdateResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronUpdateParams(
            jobId: jobId,
            name: name,
            description: description,
            enabled: enabled,
            schedule: schedule,
            payload: payload,
            delivery: delivery,
            overlapPolicy: overlapPolicy,
            misfirePolicy: misfirePolicy,
            maxRetries: maxRetries,
            autoDisableAfter: autoDisableAfter,
            tags: tags,
            workspaceId: workspaceId
        )
        return try await ws.send(method: "cron.update", params: params)
    }

    /// Delete a cron job (preserves run history).
    func deleteJob(jobId: String) async throws -> CronDeleteResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronDeleteParams(jobId: jobId)
        return try await ws.send(method: "cron.delete", params: params)
    }

    /// Trigger immediate execution of a job.
    func triggerJob(jobId: String) async throws -> CronRunResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronRunParams(jobId: jobId)
        return try await ws.send(method: "cron.run", params: params)
    }

    // MARK: - Status & History

    /// Get scheduler health and status.
    func getStatus() async throws -> CronStatusResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        return try await ws.send(method: "cron.status", params: EmptyParams())
    }

    /// Get paginated run history for a job.
    func getRuns(jobId: String, limit: Int? = nil, offset: Int? = nil, status: String? = nil) async throws -> CronGetRunsResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()
        let params = CronGetRunsParams(jobId: jobId, limit: limit, offset: offset, status: status)
        return try await ws.send(method: "cron.getRuns", params: params)
    }
}
