import Foundation

/// Client for media-related RPC methods.
/// Handles transcription, voice notes, and browser streaming.
@MainActor
final class MediaClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Transcription Methods

    func transcribeAudio(
        audioData: Data,
        mimeType: String = "audio/m4a",
        fileName: String? = nil,
        transcriptionModelId: String? = nil,
        cleanupMode: String? = nil,
        language: String? = nil
    ) async throws -> TranscribeAudioResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = TranscribeAudioParams(
            sessionId: transport.currentSessionId,
            audioBase64: audioBase64,
            mimeType: mimeType,
            fileName: fileName,
            transcriptionModelId: transcriptionModelId,
            cleanupMode: cleanupMode,
            language: language,
            prompt: nil,
            task: nil
        )

        return try await ws.send(
            method: "transcribe.audio",
            params: params,
            timeout: 180.0
        )
    }

    func listTranscriptionModels() async throws -> TranscribeListModelsResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        return try await ws.send(
            method: "transcribe.listModels",
            params: EmptyParams()
        )
    }

    // MARK: - Voice Notes Methods

    /// Save a voice note with transcription
    func saveVoiceNote(
        audioData: Data,
        mimeType: String = "audio/m4a",
        fileName: String? = nil,
        transcriptionModelId: String? = nil
    ) async throws -> VoiceNotesSaveResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        // Encode audio to base64 off main thread
        let audioBase64 = await Task.detached(priority: .utility) {
            audioData.base64EncodedString()
        }.value

        let params = VoiceNotesSaveParams(
            audioBase64: audioBase64,
            mimeType: mimeType,
            fileName: fileName,
            transcriptionModelId: transcriptionModelId
        )

        return try await ws.send(
            method: "voiceNotes.save",
            params: params,
            timeout: 180.0  // 3 minutes for transcription
        )
    }

    /// List saved voice notes
    func listVoiceNotes(limit: Int = 50, offset: Int = 0) async throws -> VoiceNotesListResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = VoiceNotesListParams(limit: limit, offset: offset)
        return try await ws.send(method: "voiceNotes.list", params: params)
    }

    /// Delete a voice note
    func deleteVoiceNote(filename: String) async throws -> VoiceNotesDeleteResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = VoiceNotesDeleteParams(filename: filename)
        return try await ws.send(method: "voiceNotes.delete", params: params)
    }

    // MARK: - Browser Methods

    /// Start browser frame streaming for a session
    /// - Parameters:
    ///   - sessionId: The session to stream from
    ///   - quality: JPEG quality (0-100, default 60)
    ///   - maxWidth: Max frame width (default 1280)
    ///   - maxHeight: Max frame height (default 800)
    ///   - everyNthFrame: Skip frames for battery savings (default 1 = ~10 FPS)
    func startBrowserStream(
        sessionId: String,
        quality: Int = 60,
        maxWidth: Int = 1280,
        maxHeight: Int = 800,
        everyNthFrame: Int = 1
    ) async throws -> BrowserStartStreamResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = BrowserStartStreamParams(
            sessionId: sessionId,
            quality: quality,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            format: "jpeg",
            everyNthFrame: everyNthFrame
        )

        return try await ws.send(method: "browser.startStream", params: params)
    }

    /// Stop browser frame streaming for a session
    func stopBrowserStream(sessionId: String) async throws -> BrowserStopStreamResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = BrowserStopStreamParams(sessionId: sessionId)
        return try await ws.send(method: "browser.stopStream", params: params)
    }

    /// Get browser status for a session
    func getBrowserStatus(sessionId: String) async throws -> BrowserGetStatusResult {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let params = BrowserGetStatusParams(sessionId: sessionId)
        return try await ws.send(method: "browser.getStatus", params: params)
    }

    /// Get browser status for current session
    func getBrowserStatus() async throws -> BrowserGetStatusResult {
        guard let transport else { throw RPCClientError.noActiveSession }
        let (_, sessionId) = try transport.requireSession()
        return try await getBrowserStatus(sessionId: sessionId)
    }
}
