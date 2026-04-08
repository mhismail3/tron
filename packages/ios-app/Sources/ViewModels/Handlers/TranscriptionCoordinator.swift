import Foundation

private let log = TronLogger.shared

/// Protocol defining the context required by TranscriptionCoordinator.
///
/// This protocol allows TranscriptionCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with audio recording and transcription.
///
/// Inherits from:
/// - LoggingContext: Logging and error display
@MainActor
protocol TranscriptionContext: LoggingContext {
    /// Whether audio is currently being recorded
    var isRecording: Bool { get }

    /// Whether the agent is currently processing (read-only for transcription)
    var isProcessing: Bool { get }

    /// Whether transcription is currently in progress
    var isTranscribing: Bool { get set }

    /// The current input text field contents
    var inputText: String { get set }

    /// Maximum recording duration in seconds
    var maxRecordingDuration: TimeInterval { get }

    /// Start audio recording
    func startRecording() async throws

    /// Stop audio recording and return the recorded file
    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool)

    /// Transcribe audio data
    /// - Parameters:
    ///   - data: The audio data to transcribe
    ///   - mimeType: The MIME type of the audio
    ///   - fileName: The original file name
    /// - Returns: The transcribed text
    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String

    /// Load audio data from a file URL
    /// - Parameter url: The URL of the audio file
    /// - Returns: The audio data
    /// - Throws: AudioFileTooSmallError if file is < 1KB
    func loadAudioData(from url: URL) async throws -> Data

    /// Show transcription failed notification in chat
    func appendTranscriptionFailedNotification()

    /// Show no speech detected notification in chat
    func appendNoSpeechDetectedNotification()
}

/// Coordinates voice recording and transcription for ChatViewModel.
///
/// Responsibilities:
/// - Toggling recording on/off
/// - Processing completed recordings
/// - Transcribing audio to text
/// - Handling transcription errors and edge cases
/// - Updating input text with transcription results
///
/// This coordinator extracts transcription handling logic from ChatViewModel+Transcription.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class TranscriptionCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Recording Control

    /// Toggle audio recording on/off.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func toggleRecording(context: TranscriptionContext) async {
        log.info("[Transcription] toggleRecording — isRecording=\(context.isRecording)", category: .audio)
        if context.isRecording {
            let (url, success) = context.stopRecording()
            await handleRecordingFinished(url: url, success: success, context: context)
        } else {
            await startRecording(context: context)
        }
    }

    /// Start audio recording if conditions allow.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    private func startRecording(context: TranscriptionContext) async {
        // Don't start if already processing or transcribing
        guard !context.isProcessing && !context.isTranscribing else {
            log.debug("[Transcription] startRecording blocked — processing=\(context.isProcessing), transcribing=\(context.isTranscribing)", category: .audio)
            return
        }

        do {
            try await context.startRecording()
            log.info("[Transcription] recording started (max \(context.maxRecordingDuration)s)", category: .audio)
        } catch {
            log.error("[Transcription] startRecording failed: \(error.localizedDescription)", category: .audio)
            context.appendTranscriptionFailedNotification()
        }
    }

    // MARK: - Recording Finished Handling

    /// Handle a completed recording.
    ///
    /// - Parameters:
    ///   - url: The URL of the recorded audio file (nil if recording failed)
    ///   - success: Whether the recording completed successfully
    ///   - context: The context providing access to state and dependencies
    func handleRecordingFinished(url: URL?, success: Bool, context: TranscriptionContext) async {
        let t0 = CFAbsoluteTimeGetCurrent()
        log.info("[Transcription] handleRecordingFinished — success=\(success), hasURL=\(url != nil), file=\(url?.lastPathComponent ?? "nil")", category: .audio)

        guard success, let url = url else {
            log.warning("[Transcription] recording failed — showing notification", category: .audio)
            context.appendTranscriptionFailedNotification()
            return
        }

        context.isTranscribing = true
        defer { context.isTranscribing = false }

        do {
            // Load and validate audio data
            let tLoad = CFAbsoluteTimeGetCurrent()
            let audioData = try await context.loadAudioData(from: url)
            let loadMs = (CFAbsoluteTimeGetCurrent() - tLoad) * 1000
            log.info("[Transcription] audio loaded — \(audioData.count) bytes (\(String(format: "%.1f", Double(audioData.count) / 1024))KB) in \(String(format: "%.1f", loadMs))ms, mimeType=\(mimeType(for: url))", category: .audio)

            // Transcribe the audio
            let tTranscribe = CFAbsoluteTimeGetCurrent()
            let result = try await context.transcribeAudio(
                data: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )
            let transcribeMs = (CFAbsoluteTimeGetCurrent() - tTranscribe) * 1000
            let totalMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

            let transcript = result.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("[Transcription] SERVER RETURNED — transcribeRPC=\(String(format: "%.0f", transcribeMs))ms, totalPipeline=\(String(format: "%.0f", totalMs))ms, rawLen=\(result.count), trimmedLen=\(transcript.count), text=\"\(String(transcript.prefix(100)))\"", category: .audio)

            guard !transcript.isEmpty else {
                log.warning("[Transcription] empty transcript after trim — showing noSpeech", category: .audio)
                context.appendNoSpeechDetectedNotification()
                return
            }

            // Update input text
            if context.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.inputText = transcript
            } else {
                context.inputText += "\n" + transcript
            }

            log.info("[Transcription] complete — \(transcript.count) chars inserted", category: .audio)

        } catch let error as AudioFileTooSmallError {
            log.error("[Transcription] audio too small: \(error.size) bytes — showing noSpeech", category: .audio)
            context.appendNoSpeechDetectedNotification()
        } catch {
            if isNoSpeechDetectedError(error) {
                log.info("[Transcription] server returned noSpeech: \(error.localizedDescription)", category: .audio)
                context.appendNoSpeechDetectedNotification()
                return
            }
            log.error("[Transcription] transcription failed: \(error.localizedDescription)", category: .audio)
            context.appendTranscriptionFailedNotification()
        }
    }

    // MARK: - Utilities

    /// Determine the MIME type for an audio file URL.
    ///
    /// - Parameter url: The URL of the audio file
    /// - Returns: The MIME type string
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

    /// Check if an error indicates no speech was detected.
    ///
    /// - Parameter error: The error to check
    /// - Returns: `true` if the error indicates no speech
    func isNoSpeechDetectedError(_ error: Error) -> Bool {
        let message: String
        if let rpcError = error as? RPCError {
            message = rpcError.message
        } else {
            message = error.localizedDescription
        }
        let normalized = message.lowercased()
        return normalized.contains("no speech") || normalized.contains("no text")
    }
}

/// Error thrown when an audio file is too small to contain meaningful speech.
struct AudioFileTooSmallError: Error {
    let size: Int
}
