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
        transcriptionTaskGeneration += 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
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
        try await ChatTranscriptionAudioFileLoader.shared.load(from: url)
    }

    func appendTranscriptionError(_ message: String) {
        appendLocalError(dedupKey: "transcription.error", title: "Voice input failed", message: message)
    }

    func toggleRecording() {
        launchTranscriptionTask { viewModel in
            await viewModel.transcriptionCoordinator.toggleRecording(context: viewModel)
        }
    }

    func handleRecordingFinished(url: URL?, success: Bool) async {
        launchTranscriptionTask { viewModel in
            await viewModel.transcriptionCoordinator.handleRecordingFinished(
                url: url,
                success: success,
                context: viewModel
            )
        }
    }

    private func launchTranscriptionTask(
        _ operation: @escaping @Sendable @MainActor (ChatViewModel) async -> Void
    ) {
        guard transcriptionTask == nil else { return }

        transcriptionTaskGeneration += 1
        let generation = transcriptionTaskGeneration
        transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)
            if self.transcriptionTaskGeneration == generation {
                self.transcriptionTask = nil
            }
        }
    }
}

private actor ChatTranscriptionAudioFileLoader {
    static let shared = ChatTranscriptionAudioFileLoader()

    func load(from url: URL) throws -> Data {
        defer { try? FileManager.default.removeItem(at: url) }
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
        if fileSize < 1024 {
            throw AudioFileTooSmallError(size: fileSize)
        }
        return try Data(contentsOf: url)
    }
}
