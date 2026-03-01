import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MediaClient Tests")
struct MediaClientTests {

    @Test("transcribeAudio throws when webSocket is nil")
    func transcribeNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MediaClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.transcribeAudio(audioData: Data())
        }
    }
}
