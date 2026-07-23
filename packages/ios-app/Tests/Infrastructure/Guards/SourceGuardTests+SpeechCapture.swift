import Foundation
import Testing

extension SourceGuardTests {
    @Test("Speech capture stays native while recognition stays worker-owned")
    func speechCaptureStaysNativeWhileRecognitionStaysWorkerOwned() throws {
        let root = iosAppRoot()
        let capturePaths = [
            "Sources/Support/Foundation/Audio/ComposerMicCaptureEngine.swift",
            "Sources/Support/Foundation/Audio/ComposerMicRecorder.swift",
            "Sources/Session/Chat/Coordinators/ChatSpeechTranscriptionCoordinator.swift",
            "Sources/Session/Chat/ViewModel/ChatViewModel+SpeechTranscription.swift",
            "Sources/UI/Chat/Composer/RecordingLevelWaveform.swift",
        ]
        let combined = try capturePaths.map { relativePath in
            try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        for fragment in [
            "AVAudioEngine",
            "requestRecordPermission",
            "writeWAVFile",
            "RecordingLevelWaveform",
            "invokeWorkerFromSession",
            "\"audioBase64\"",
            "\"mimeType\"",
            "\"fileName\"",
            "\"text\"",
            "\"speech_transcription\"",
        ] {
            #expect(combined.contains(fragment), "speech capture boundary requires `\(fragment)`")
        }

        for removedSurface in [
            "TranscriptionClient",
            "transcription::audio",
            "transcription::list_models",
            "transcription::download_model",
        ] {
            #expect(
                !combined.contains(removedSurface),
                "native capture must not restore fixed recognition surface `\(removedSurface)`"
            )
        }
    }
}
