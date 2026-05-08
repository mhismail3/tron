import Foundation

/// Client for cron scheduling engine capabilities.
final class CronClient: EngineDomainClient {

    // MARK: - Job Management

    /// List cron jobs with optional filters.
    func listJobs(enabled: Bool? = nil, tags: [String]? = nil, workspaceId: String? = nil) async throws -> CronListResult {
        _ = try requireTransport().requireConnection()
        let params = CronListParams(enabled: enabled, tags: tags, workspaceId: workspaceId)
        return try await invokeRead("cron::list", params)
    }

    /// Get a single job with runtime state and recent runs.
    func getJob(jobId: String) async throws -> CronGetResult {
        _ = try requireTransport().requireConnection()
        let params = CronGetParams(jobId: jobId)
        return try await invokeRead("cron::get", params)
    }

    /// Create a new cron job.
    func createJob(_ job: CronCreateJobParams, idempotencyKey: EngineIdempotencyKey) async throws -> CronCreateResult {
        _ = try requireTransport().requireConnection()
        let params = CronCreateParams(job: job)
        return try await invokeWrite("cron::create", params, idempotencyKey: idempotencyKey)
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
        workspaceId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> CronUpdateResult {
        _ = try requireTransport().requireConnection()
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
        return try await invokeWrite("cron::update", params, idempotencyKey: idempotencyKey)
    }

    /// Delete a cron job (preserves run history).
    func deleteJob(jobId: String, idempotencyKey: EngineIdempotencyKey) async throws -> CronDeleteResult {
        _ = try requireTransport().requireConnection()
        let params = CronDeleteParams(jobId: jobId)
        return try await invokeWrite("cron::delete", params, idempotencyKey: idempotencyKey)
    }

    /// Trigger immediate execution of a job.
    func triggerJob(jobId: String, idempotencyKey: EngineIdempotencyKey) async throws -> CronRunResult {
        _ = try requireTransport().requireConnection()
        let params = CronRunParams(jobId: jobId)
        return try await invokeWrite("cron::run", params, idempotencyKey: idempotencyKey)
    }

    // MARK: - Status & History

    /// Get scheduler health and status.
    func getStatus() async throws -> CronStatusResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead("cron::status", EmptyParams())
    }

    /// Get paginated run history for a job.
    func getRuns(jobId: String, limit: Int? = nil, offset: Int? = nil, status: String? = nil) async throws -> CronGetRunsResult {
        _ = try requireTransport().requireConnection()
        let params = CronGetRunsParams(jobId: jobId, limit: limit, offset: offset, status: status)
        return try await invokeRead("cron::get_runs", params)
    }
}
