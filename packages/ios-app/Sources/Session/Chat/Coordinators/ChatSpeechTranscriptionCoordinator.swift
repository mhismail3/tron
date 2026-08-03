import Foundation

@MainActor
protocol ChatSpeechTranscriptionContext: AnyObject {
    var isRecording: Bool { get }
    var isProcessing: Bool { get }
    var isTranscribing: Bool { get set }
    var inputText: String { get set }

    func requireSpeechTranscriptionReady() async throws
    func startRecording() async throws
    func cancelRecording()
    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool)
    func transcribeCapturedAudio(data: Data, mimeType: String, fileName: String) async throws -> String
    func loadCapturedAudio(from url: URL) async throws -> Data
    func appendSpeechTranscriptionError(_ message: String)
}

/// Owns the prompt composer's bounded record → invoke → insert interaction.
///
/// Capture is a native client actuator. Speech recognition is always delegated
/// through the active `speech_transcription` worker selected by the engine.
@MainActor
final class ChatSpeechTranscriptionCoordinator {
    func toggleRecording(context: ChatSpeechTranscriptionContext) async {
        if context.isRecording {
            let (url, success) = context.stopRecording()
            await handleRecordingFinished(url: url, success: success, context: context)
        } else {
            await startRecording(context: context)
        }
    }

    private func startRecording(context: ChatSpeechTranscriptionContext) async {
        guard !context.isProcessing && !context.isTranscribing else { return }
        do {
            try Task.checkCancellation()
            try await context.requireSpeechTranscriptionReady()
            try Task.checkCancellation()
            try await context.startRecording()
            try Task.checkCancellation()
        } catch is CancellationError {
            context.cancelRecording()
        } catch {
            if Task.isCancelled {
                context.cancelRecording()
            } else {
                context.appendSpeechTranscriptionError(failureMessage(for: error))
            }
        }
    }

    func handleRecordingFinished(
        url: URL?,
        success: Bool,
        context: ChatSpeechTranscriptionContext
    ) async {
        guard success, let url else {
            if !Task.isCancelled {
                context.appendSpeechTranscriptionError("Recording failed.")
            }
            return
        }

        if Task.isCancelled {
            _ = try? await context.loadCapturedAudio(from: url)
            return
        }

        context.isTranscribing = true
        defer { context.isTranscribing = false }

        do {
            let audioData = try await context.loadCapturedAudio(from: url)
            try Task.checkCancellation()
            let result = try await context.transcribeCapturedAudio(
                data: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )
            try Task.checkCancellation()
            let transcript = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                context.appendSpeechTranscriptionError("No speech detected.")
                return
            }

            if context.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.inputText = transcript
            } else {
                context.inputText += "\n" + transcript
            }
        } catch is CancellationError {
            return
        } catch let error as CapturedAudioTooSmallError {
            if !Task.isCancelled {
                context.appendSpeechTranscriptionError(
                    "No speech detected. \(error.size) bytes captured."
                )
            }
        } catch {
            if !Task.isCancelled {
                context.appendSpeechTranscriptionError(failureMessage(for: error))
            }
        }
    }

    func mimeType(for url: URL) -> String {
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

    func failureMessage(for error: Error) -> String {
        if let availabilityError = error as? SpeechTranscriptionAvailabilityError {
            return availabilityError.localizedDescription
        }

        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("output")
            && description.localizedCaseInsensitiveContains("schema") {
            return "The speech worker returned an invalid result. Ask Tron to inspect and improve that worker."
        }
        return "Speech transcription failed: \(description)"
    }
}

struct CapturedAudioTooSmallError: Error {
    let size: Int
}

enum SpeechTranscriptionAvailabilityError: LocalizedError, Equatable {
    case noActiveWorker
    case invalidResult
    case workerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveWorker:
            return "Voice input needs a healthy speech transcription worker. Ask Tron to create or enable one, then try again."
        case .invalidResult:
            return "The speech worker completed without returning transcript text. Ask Tron to inspect and improve that worker."
        case .workerFailed(let message):
            return "The speech worker failed: \(message)"
        }
    }
}
