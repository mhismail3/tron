import Foundation

@MainActor
protocol ChatTranscriptionContext: LoggingContext {
    var isRecording: Bool { get }
    var isProcessing: Bool { get }
    var isTranscribing: Bool { get set }
    var inputText: String { get set }
    var maxRecordingDuration: TimeInterval { get }

    func startRecording() async throws
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
            try await context.startRecording()
        } catch {
            context.showError(error.localizedDescription)
        }
    }

    func handleRecordingFinished(url: URL?, success: Bool, context: ChatTranscriptionContext) async {
        guard success, let url else {
            context.appendTranscriptionError("Recording failed.")
            return
        }

        context.isTranscribing = true
        defer { context.isTranscribing = false }

        do {
            let audioData = try await context.loadAudioData(from: url)
            let result = try await context.transcribeAudio(
                data: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )
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
        } catch let error as AudioFileTooSmallError {
            context.appendTranscriptionError("No speech detected. \(error.size) bytes captured.")
        } catch {
            context.appendTranscriptionError("Transcription failed: \(error.localizedDescription)")
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
}

struct AudioFileTooSmallError: Error {
    let size: Int
}
