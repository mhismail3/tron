import Foundation

// MARK: - Voice Transcription

private enum AudioProcessingError: Error {
    case tooSmall(Int)
}

extension ChatViewModel {

    func toggleRecording() {
        if isRecording {
            audioRecorder.stopRecording()
        } else {
            Task {
                await startRecording()
            }
        }
    }

    private func startRecording() async {
        guard !isProcessing && !isTranscribing else { return }
        do {
            try await audioRecorder.startRecording(maxDuration: maxRecordingDuration)
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)", category: .chat)
            appendTranscriptionFailedNotification()
        }
    }

    func handleRecordingFinished(url: URL?, success: Bool) async {
        guard success, let url else {
            appendTranscriptionFailedNotification()
            return
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            let audioData = try await Task.detached(priority: .utility) { () throws -> Data in
                defer { try? FileManager.default.removeItem(at: url) }
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
                if fileSize < 1024 {
                    throw AudioProcessingError.tooSmall(fileSize)
                }
                return try Data(contentsOf: url)
            }.value

            let result = try await rpcClient.media.transcribeAudio(
                audioData: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )

            let transcript = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                appendNoSpeechDetectedNotification()
                return
            }

            if inputText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                inputText = transcript
            } else {
                inputText += "\n" + transcript
            }
        } catch AudioProcessingError.tooSmall(let fileSize) {
            logger.error("Recorded audio too small (\(fileSize) bytes)", category: .chat)
            appendNoSpeechDetectedNotification()
        } catch {
            if isNoSpeechDetectedError(error) {
                logger.info("No speech detected in transcription: \(error.localizedDescription)", category: .chat)
                appendNoSpeechDetectedNotification()
                return
            }
            logger.error("Transcription failed: \(error.localizedDescription)", category: .chat)
            appendTranscriptionFailedNotification()
        }
    }

    private func appendTranscriptionFailedNotification() {
        messages.append(.transcriptionFailed())
    }

    private func appendNoSpeechDetectedNotification() {
        messages.append(.transcriptionNoSpeech())
    }

    private func isNoSpeechDetectedError(_ error: Error) -> Bool {
        let message: String
        if let rpcError = error as? RPCError {
            message = rpcError.message
        } else {
            message = error.localizedDescription
        }
        let normalized = message.lowercased()
        return normalized.contains("no speech") || normalized.contains("no text")
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "m4a":
            return "audio/m4a"
        case "caf":
            return "audio/x-caf"
        default:
            return "application/octet-stream"
        }
    }
}
