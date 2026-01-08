import Foundation

// MARK: - Voice Transcription

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
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? 0
            if fileSize < 1024 {
                logger.error("Recorded audio too small (\(fileSize) bytes)", category: .chat)
                try? FileManager.default.removeItem(at: url)
                appendTranscriptionFailedNotification()
                return
            }

            let audioData = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)

            let result = try await rpcClient.transcribeAudio(
                audioData: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )

            let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                appendTranscriptionFailedNotification()
                return
            }

            if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = transcript
            } else {
                inputText += "\n" + transcript
            }
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription)", category: .chat)
            appendTranscriptionFailedNotification()
        }
    }

    private func appendTranscriptionFailedNotification() {
        messages.append(.transcriptionFailed())
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
