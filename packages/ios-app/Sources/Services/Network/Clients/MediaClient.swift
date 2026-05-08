import Foundation

/// Client for media-related engine capabilities.
/// Handles transcription, voice notes, and browser streaming.
final class MediaClient: EngineDomainClient {

    // MARK: - Transcription Methods

    func transcribeAudio(
        audioData: Data,
        mimeType: String = "audio/wav",
        fileName: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> TranscribeAudioResult {
        _ = try requireTransport().requireConnection()

        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = TranscribeAudioParams(
            sessionId: currentTransport?.currentSessionId,
            audioBase64: audioBase64,
            mimeType: mimeType,
            fileName: fileName
        )

        return try await invokeWrite(
            "transcription::audio",
            params,
            idempotencyKey: idempotencyKey,
            timeout: 360.0
        )
    }

    // MARK: - Voice Notes Methods

    /// Save a voice note with transcription
    func saveVoiceNote(
        audioData: Data,
        mimeType: String = "audio/wav",
        fileName: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> VoiceNotesSaveResult {
        _ = try requireTransport().requireConnection()

        // Encode audio to base64 off main thread
        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = VoiceNotesSaveParams(
            audioBase64: audioBase64,
            mimeType: mimeType,
            fileName: fileName
        )

        return try await invokeWrite(
            "voice_notes::save",
            params,
            idempotencyKey: idempotencyKey,
            timeout: 360.0
        )
    }

    /// List saved voice notes
    func listVoiceNotes(limit: Int = 50, offset: Int = 0) async throws -> VoiceNotesListResult {
        _ = try requireTransport().requireConnection()

        let params = VoiceNotesListParams(limit: limit, offset: offset)
        return try await invokeRead("voice_notes::list", params)
    }

    /// Delete a voice note
    func deleteVoiceNote(filename: String, idempotencyKey: EngineIdempotencyKey) async throws -> VoiceNotesDeleteResult {
        _ = try requireTransport().requireConnection()

        let params = VoiceNotesDeleteParams(filename: filename)
        return try await invokeWrite("voice_notes::delete", params, idempotencyKey: idempotencyKey)
    }

    // MARK: - Browser Methods

    /// Start browser frame streaming for a session
    /// - Parameters:
    ///   - sessionId: The session to stream from
    ///   - quality: JPEG quality (0-100, default 60)
    ///   - maxWidth: Max frame width (default 1280)
    ///   - maxHeight: Max frame height (default 960)
    ///   - everyNthFrame: Skip frames for battery savings (default 1 = ~10 FPS)
    func startBrowserStream(
        sessionId: String,
        quality: Int = 60,
        maxWidth: Int = 1280,
        maxHeight: Int = 960,
        everyNthFrame: Int = 1,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> BrowserStartStreamResult {
        _ = try requireTransport().requireConnection()

        let params = BrowserStartStreamParams(
            sessionId: sessionId,
            quality: quality,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            format: "jpeg",
            everyNthFrame: everyNthFrame
        )

        return try await invokeWrite("browser::start_stream", params, idempotencyKey: idempotencyKey)
    }

    /// Stop browser frame streaming for a session
    func stopBrowserStream(sessionId: String, idempotencyKey: EngineIdempotencyKey) async throws -> BrowserStopStreamResult {
        _ = try requireTransport().requireConnection()

        let params = BrowserStopStreamParams(sessionId: sessionId)
        return try await invokeWrite("browser::stop_stream", params, idempotencyKey: idempotencyKey)
    }

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
