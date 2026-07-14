import Foundation

/// Protocol for model client operations.
/// Provides the transport seam used by `DefaultModelRepository`.
@MainActor
protocol ModelClientProtocol {
    func list() async throws -> [ModelInfo]
    func switchModel(
        _ sessionId: String,
        model: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ModelSwitchResult
    func setReasoningLevel(
        _ sessionId: String,
        level: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ReasoningLevelResult
}

/// Client for model-related engine capabilities.
/// Thinly maps model operations onto engine capabilities.
final class ModelClient: EngineDomainClient, ModelClientProtocol {

    // MARK: - Model Methods

    func switchModel(
        _ sessionId: String,
        model: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ModelSwitchResult {
        _ = try requireTransport().requireConnection()

        let params = ModelSwitchParams(sessionId: sessionId, model: model)
        let result: ModelSwitchResult = try await invokeWrite(
            "model::switch",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )

        if currentTransport?.currentSessionId == sessionId {
            currentTransport?.setCurrentModel(result.newModel)
        }

        logger.info("Switched model from \(result.previousModel) to \(result.newModel)", category: .session)
        return result
    }

    /// List available models from the engine.
    func list() async throws -> [ModelInfo] {
        _ = try requireTransport().requireConnection()

        let result: ModelListResult = try await invokeRead(
            "model::list",
            EmptyParams()
        )

        return result.models
    }

    // MARK: - Reasoning Level

    func setReasoningLevel(
        _ sessionId: String,
        level: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> ReasoningLevelResult {
        _ = try requireTransport().requireConnection()

        let params = ReasoningLevelParams(sessionId: sessionId, level: level)
        return try await invokeWrite(
            "config::set_reasoning_level",
            params,
            idempotencyKey: idempotencyKey,
            context: sessionInvocationContext(sessionId)
        )
    }

}
