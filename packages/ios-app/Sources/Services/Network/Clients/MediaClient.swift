import Foundation

/// Client for media-related engine capabilities.
/// Handles prompt transcription and browser status.
final class MediaClient: EngineDomainClient {

    // MARK: - Transcription Methods

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

    // MARK: - Browser Methods

    /// Get browser status for a session
    func getBrowserStatus(sessionId: String) async throws -> BrowserGetStatusResult {
        _ = try requireTransport().requireConnection()

        let params = BrowserGetStatusParams(sessionId: sessionId)
        return try await invokeRead("browser::get_status", params)
    }

    /// Get browser status for current session
    func getBrowserStatus() async throws -> BrowserGetStatusResult {
        let (_, sessionId) = try requireTransport().requireSession()
        return try await getBrowserStatus(sessionId: sessionId)
    }
}
