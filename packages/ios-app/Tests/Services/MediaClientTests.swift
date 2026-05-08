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
}
