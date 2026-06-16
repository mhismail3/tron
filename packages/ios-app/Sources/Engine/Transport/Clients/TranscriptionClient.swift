import Foundation

final class TranscriptionClient: EngineDomainClient {
    func transcribeAudio(
        audioData: Data,
        mimeType: String = "audio/wav",
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> TranscribeAudioResult {
        _ = try requireTransport().requireConnection()

        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = TranscribeAudioParams(
            sessionId: currentTransport?.currentSessionId,
            audioBase64: audioBase64,
            mimeType: mimeType
        )

        return try await invokeWrite(
            "transcription::audio",
            params,
            idempotencyKey: idempotencyKey,
            context: optionalSessionInvocationContext(params.sessionId),
            timeout: 360.0
        )
    }

    func listModels() async throws -> TranscriptionModelsResult {
        _ = try requireTransport().requireConnection()
        return try await invokeRead("transcription::list_models", EmptyParams())
    }

    func downloadModel(idempotencyKey: EngineIdempotencyKey) async throws -> TranscriptionDownloadModelResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "transcription::download_model",
            EmptyParams(),
            idempotencyKey: idempotencyKey,
            timeout: 360.0
        )
    }
}
