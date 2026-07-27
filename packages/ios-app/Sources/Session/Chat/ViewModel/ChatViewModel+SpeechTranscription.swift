import Foundation

extension ChatViewModel: ChatSpeechTranscriptionContext {
    func requireSpeechTranscriptionReady() async throws {
        await refreshSpeechTranscriptionOwner()
        guard speechTranscriptionOwner != nil else {
            throw SpeechTranscriptionAvailabilityError.noActiveWorker
        }
    }

    func startRecording() async throws {
        try await micRecorder.startRecording()
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        micRecorder.stopRecording()
    }

    func cancelRecording() {
        speechTranscriptionTaskGeneration &+= 1
        speechTranscriptionTask?.cancel()
        speechTranscriptionTask = nil
        isTranscribing = false
        micRecorder.cancelRecording()
    }

    func transcribeCapturedAudio(
        data: Data,
        mimeType: String,
        fileName: String
    ) async throws -> String {
        guard let owner = speechTranscriptionOwner else {
            throw SpeechTranscriptionAvailabilityError.noActiveWorker
        }
        let result = try await services.workerKernel.invokeWorkerFromSession(
            workerId: owner.workerId,
            input: AnyCodable([
                "audioBase64": data.base64EncodedString(),
                "mimeType": mimeType,
                "fileName": fileName,
            ]),
            originSessionId: sessionId,
            idempotencyKey: .userAction("speech.transcription")
        )
        guard result.status == "completed" else {
            throw SpeechTranscriptionAvailabilityError.workerFailed(
                result.error ?? "Invocation ended with status \(result.status)."
            )
        }
        let output = try await services.workerKernel.resolvedWorkerResult(result)
        guard let transcript = output.dictionaryValue?["text"] as? String else {
            throw SpeechTranscriptionAvailabilityError.invalidResult
        }
        return transcript
    }

    func loadCapturedAudio(from url: URL) async throws -> Data {
        try await CapturedAudioFileLoader.shared.load(from: url)
    }

    func appendSpeechTranscriptionError(_ message: String) {
        appendLocalError(
            dedupKey: "speech.transcription.error",
            title: "Voice input failed",
            message: message
        )
    }

    func toggleRecording() {
        launchSpeechTranscriptionTask { viewModel in
            await viewModel.speechTranscriptionCoordinator.toggleRecording(context: viewModel)
        }
    }

    func handleRecordingFinished(url: URL?, success: Bool) {
        launchSpeechTranscriptionTask { viewModel in
            await viewModel.speechTranscriptionCoordinator.handleRecordingFinished(
                url: url,
                success: success,
                context: viewModel
            )
        }
    }

    func startSpeechTranscriptionMonitoring() {
        guard speechWorkerMonitorTask == nil else { return }
        let repository = services.workerKernel
        let connection = services.connection
        speechWorkerMonitorTaskGeneration &+= 1
        let generation = speechWorkerMonitorTaskGeneration
        speechWorkerMonitorTask = Task { @MainActor [weak self] in
            let invalidations = NotificationCenter.default.notifications(
                named: .workerLifecycleProjectionInvalidated
            )
            await self?.refreshSpeechTranscriptionOwner()
            do {
                try await repository.ensureWorkerEventSubscriptions()
            } catch {
                self?.logDebug(
                    "Speech worker lifecycle subscription deferred: \(error.localizedDescription)"
                )
                if self?.speechWorkerMonitorTaskGeneration == generation {
                    self?.speechWorkerMonitorTask = nil
                }
                return
            }
            for await _ in invalidations {
                guard !Task.isCancelled,
                      connection.connectionState.isConnected else {
                    break
                }
                // Resolve the weak owner per iteration. Unwrapping before the
                // sequence loop would retain every previously opened chat for
                // the lifetime of this connection.
                await self?.refreshSpeechTranscriptionOwner()
            }
            if !connection.connectionState.isConnected {
                self?.speechTranscriptionOwner = nil
            }
            if self?.speechWorkerMonitorTaskGeneration == generation {
                self?.speechWorkerMonitorTask = nil
            }
        }
    }

    func stopSpeechTranscriptionMonitoring() {
        speechWorkerMonitorTaskGeneration &+= 1
        speechWorkerMonitorTask?.cancel()
        speechWorkerMonitorTask = nil
        speechTranscriptionOwner = nil
    }

    func refreshSpeechTranscriptionOwner() async {
        guard services.connection.connectionState.isConnected else {
            speechTranscriptionOwner = nil
            return
        }
        do {
            let snapshot = try await services.workerKernel.engineSurfaceSnapshot(
                sessionId: nil,
                relevanceQuery: nil
            )
            speechTranscriptionOwner = snapshot.activeClientActions.first {
                $0.action == "speech_transcription"
            }
        } catch {
            logDebug("Speech worker availability refresh deferred: \(error.localizedDescription)")
        }
    }

    private func launchSpeechTranscriptionTask(
        _ operation: @escaping @Sendable @MainActor (ChatViewModel) async -> Void
    ) {
        guard speechTranscriptionTask == nil else { return }

        speechTranscriptionTaskGeneration &+= 1
        let generation = speechTranscriptionTaskGeneration
        speechTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await operation(self)
            if self.speechTranscriptionTaskGeneration == generation {
                self.speechTranscriptionTask = nil
            }
        }
    }
}

private actor CapturedAudioFileLoader {
    static let shared = CapturedAudioFileLoader()

    func load(from url: URL) throws -> Data {
        defer { try? FileManager.default.removeItem(at: url) }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if fileSize < 1_024 {
            throw CapturedAudioTooSmallError(size: fileSize)
        }
        return try Data(contentsOf: url)
    }
}
