import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MediaClient Tests")
struct MediaClientTests {

    @Test("transcribeAudio throws when engineConnection is nil")
    func transcribeNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MediaClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.transcribeAudio(
                audioData: Data(),
                idempotencyKey: .userAction("transcription.audio.test")
            )
        }
    }

    @Test("transcribeAudio sends only transcription::audio contract fields")
    func transcribePayloadMatchesEngineContract() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.currentSessionId = "session-a"
        transport.writeHandler = { _, _, _, _ in
            TranscribeAudioResult(
                text: "hello",
                rawText: "hello",
                language: "en",
                durationSeconds: 1.0,
                processingTimeMs: 10,
                model: "test",
                device: "cpu",
                computeType: "int8",
                cleanupMode: "normal"
            )
        }
        let client = MediaClient(transport: transport)

        _ = try await client.transcribeAudio(
            audioData: Data([1, 2, 3]),
            mimeType: "audio/wav",
            idempotencyKey: .userAction("transcription.audio.test")
        )
        let payload = try #require(transport.lastWritePayload as? TranscribeAudioParams)
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(payload)
        ) as? [String: Any]

        #expect(transport.lastWriteFunctionId == "transcription::audio")
        #expect(encoded?["sessionId"] as? String == "session-a")
        #expect(encoded?["audioBase64"] as? String == Data([1, 2, 3]).base64EncodedString())
        #expect(encoded?["mimeType"] as? String == "audio/wav")
        #expect(encoded?["fileName"] == nil)
    }
}
