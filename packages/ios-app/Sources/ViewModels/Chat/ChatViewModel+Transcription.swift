import Foundation

// MARK: - TranscriptionContext Conformance

extension ChatViewModel: TranscriptionContext {
    var maxRecordingDuration: TimeInterval { 120 }

    func startRecording() async throws {
        try await audioRecorder.startRecording(maxDuration: maxRecordingDuration)
    }

    func stopRecording() {
        audioRecorder.stopRecording()
    }

    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String {
        let result = try await rpcClient.media.transcribeAudio(
            audioData: data,
            mimeType: mimeType,
            fileName: fileName
        )
        return result.text
    }

    func loadAudioData(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) { () throws -> Data in
            defer { try? FileManager.default.removeItem(at: url) }
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
            if fileSize < 1024 {
                throw AudioFileTooSmallError(size: fileSize)
            }
            return try Data(contentsOf: url)
        }.value
    }

    func appendTranscriptionFailedNotification() {
        messages.append(.transcriptionFailed())
    }

    func appendNoSpeechDetectedNotification() {
        messages.append(.transcriptionNoSpeech())
    }
}

// MARK: - Voice Transcription Methods

extension ChatViewModel {

    /// Toggle voice recording on/off
    func toggleRecording() {
        Task {
            await transcriptionCoordinator.toggleRecording(context: self)
        }
    }

    /// Handle recording finished callback from AudioRecorder
    func handleRecordingFinished(url: URL?, success: Bool) async {
        await transcriptionCoordinator.handleRecordingFinished(url: url, success: success, context: self)
    }
}
