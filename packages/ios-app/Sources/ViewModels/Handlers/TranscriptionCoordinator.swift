import Foundation

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

    /// Stop audio recording
    func stopRecording()

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
        if context.isRecording {
            context.stopRecording()
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
            context.logDebug("Cannot start recording - processing=\(context.isProcessing), transcribing=\(context.isTranscribing)")
            return
        }

        do {
            try await context.startRecording()
            context.logInfo("Started audio recording (max \(context.maxRecordingDuration)s)")
        } catch {
            context.logError("Failed to start recording: \(error.localizedDescription)")
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
        guard success, let url = url else {
            context.appendTranscriptionFailedNotification()
            return
        }

        context.isTranscribing = true
        defer { context.isTranscribing = false }

        do {
            // Load and validate audio data
            let audioData = try await context.loadAudioData(from: url)

            // Transcribe the audio
            let result = try await context.transcribeAudio(
                data: audioData,
                mimeType: mimeType(for: url),
                fileName: url.lastPathComponent
            )

            let transcript = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                context.appendNoSpeechDetectedNotification()
                return
            }

            // Update input text
            if context.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.inputText = transcript
            } else {
                context.inputText += "\n" + transcript
            }

            context.logInfo("Transcription complete: \(transcript.count) characters")

        } catch let error as AudioFileTooSmallError {
            context.logError("Recorded audio too small (\(error.size) bytes)")
            context.appendNoSpeechDetectedNotification()
        } catch {
            if isNoSpeechDetectedError(error) {
                context.logInfo("No speech detected in transcription: \(error.localizedDescription)")
                context.appendNoSpeechDetectedNotification()
                return
            }
            context.logError("Transcription failed: \(error.localizedDescription)")
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
