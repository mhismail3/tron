import Foundation

@MainActor
protocol ChatTranscriptionContext: LoggingContext {
    var isRecording: Bool { get }
    var isProcessing: Bool { get }
    var isTranscribing: Bool { get set }
    var inputText: String { get set }
    var maxRecordingDuration: TimeInterval { get }

    func requireTranscriptionReady() async throws
    func startRecording() async throws
    func cancelRecording()
    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool)
    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String
    func loadAudioData(from url: URL) async throws -> Data
    func appendTranscriptionError(_ message: String)
}

@MainActor
final class ChatTranscriptionCoordinator {
    func toggleRecording(context: ChatTranscriptionContext) async {
        if context.isRecording {
            let (url, success) = context.stopRecording()
            await handleRecordingFinished(url: url, success: success, context: context)
        } else {
            await startRecording(context: context)
        }
    }

    private func startRecording(context: ChatTranscriptionContext) async {
        guard !context.isProcessing && !context.isTranscribing else { return }
        do {
            try Task.checkCancellation()
            try await context.requireTranscriptionReady()
            try Task.checkCancellation()
            try await context.startRecording()
            try Task.checkCancellation()
        } catch is CancellationError {
            context.cancelRecording()
            return
        } catch {
            if Task.isCancelled {
                context.cancelRecording()
                return
            }
            context.appendTranscriptionError(transcriptionFailureMessage(for: error))
        }
    }

    func handleRecordingFinished(url: URL?, success: Bool, context: ChatTranscriptionContext) async {
        guard success, let url else {
            if !Task.isCancelled {
                context.appendTranscriptionError("Recording failed.")
            }
            return
        }

        if Task.isCancelled {
            _ = try? await context.loadAudioData(from: url)
            return
        }

        context.isTranscribing = true
        defer { context.isTranscribing = false }

        do {
            let audioData = try await context.loadAudioData(from: url)
            try Task.checkCancellation()
            let result = try await context.transcribeAudio(
                data: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )
            try Task.checkCancellation()
            let transcript = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                context.appendTranscriptionError("No speech detected.")
                return
            }

            if context.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.inputText = transcript
            } else {
                context.inputText += "\n" + transcript
            }
        } catch is CancellationError {
            return
        } catch let error as AudioFileTooSmallError {
            if !Task.isCancelled {
                context.appendTranscriptionError("No speech detected. \(error.size) bytes captured.")
            }
        } catch {
            if !Task.isCancelled {
                context.appendTranscriptionError(transcriptionFailureMessage(for: error))
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

    func transcriptionFailureMessage(for error: Error) -> String {
        if let availabilityError = error as? ChatTranscriptionAvailabilityError {
            return availabilityError.localizedDescription
        }

        let description = error.localizedDescription
        let folded = description.lowercased()
        if folded.contains("function not found")
            || folded.contains("transcription::audio")
            || folded.contains("transcription::list_models") {
            return "Voice input is not available on this Mac server yet. Restart Tron Server with the latest build, then try again."
        }

        if folded.contains("transcription disabled") {
            return "Local transcription is off. Enable Local transcription in Settings, restart Tron Server, then try again."
        }

        if folded.contains("transcription engine not loaded") {
            return "Local transcription is enabled but the model is not loaded. Restart Tron Server to load the local model, then try again."
        }

        if folded.contains("transcription not available") {
            return "Local transcription is not available right now. Restart Tron Server and try again."
        }

        return "Transcription failed: \(description)"
    }
}

struct AudioFileTooSmallError: Error {
    let size: Int
}

enum ChatTranscriptionAvailabilityError: LocalizedError, Equatable {
    case noModel
    case disabled
    case loading(String?)
    case failed(String?)
    case engineNotLoaded

    var errorDescription: String? {
        switch self {
        case .noModel:
            return "No local transcription model is registered on this Mac server."
        case .disabled:
            return "Local transcription is off. Enable Local transcription in Settings, restart Tron Server, then try again."
        case .loading(let message):
            return message ?? "Local transcription is still loading the model. Wait a moment, then try again."
        case .failed(let message):
            if let message, !message.isEmpty {
                return "Local transcription failed to load: \(message)"
            }
            return "Local transcription failed to load. Restart Tron Server to retry."
        case .engineNotLoaded:
            return "Local transcription is enabled but the model is not loaded. Restart Tron Server to load the local model, then try again."
        }
    }
}
