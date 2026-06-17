import Foundation

extension ChatViewModel: ChatTranscriptionContext {
    var isProcessing: Bool { agentPhase.isProcessing }

    var maxRecordingDuration: TimeInterval { 300 }

    func requireTranscriptionReady() async throws {
        let models = try await services.transcription.listModels().models
        guard let model = models.first(where: \.default) ?? models.first else {
            throw ChatTranscriptionAvailabilityError.noModel
        }
        guard model.enabled else {
            throw ChatTranscriptionAvailabilityError.disabled
        }
        guard model.engineLoaded else {
            if model.state == "loading" {
                throw ChatTranscriptionAvailabilityError.loading(model.message)
            }
            if model.state == "failed" {
                throw ChatTranscriptionAvailabilityError.failed(model.message)
            }
            throw ChatTranscriptionAvailabilityError.engineNotLoaded
        }
    }

    func startRecording() async throws {
        try await micRecorder.startRecording(maxDuration: maxRecordingDuration)
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        micRecorder.stopRecording()
    }

    func cancelRecording() {
        micRecorder.cancelRecording()
    }

    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String {
        let result = try await services.transcription.transcribeAudio(
            data: data,
            mimeType: mimeType,
            idempotencyKey: .userAction("transcription.audio")
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

    func appendTranscriptionError(_ message: String) {
        appendLocalError(dedupKey: "transcription.error", title: "Voice input failed", message: message)
    }

    func toggleRecording() {
        Task {
            await transcriptionCoordinator.toggleRecording(context: self)
        }
    }

    func handleRecordingFinished(url: URL?, success: Bool) async {
        await transcriptionCoordinator.handleRecordingFinished(url: url, success: success, context: self)
    }
}
