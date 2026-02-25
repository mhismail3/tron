import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MediaClient Tests")
struct MediaClientTests {

    @Test("transcribeAudio throws when transport is nil")
    func transcribeNoTransport() async {
        let client: MediaClient = {
            let transport = MockRPCTransport()
            return MediaClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.transcribeAudio(audioData: Data())
        }
    }

    @Test("transcribeAudio throws when webSocket is nil")
    func transcribeNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MediaClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.transcribeAudio(audioData: Data())
        }
    }

    @Test("listTranscriptionModels throws when transport is nil")
    func listModelsNoTransport() async {
        let client: MediaClient = {
            let transport = MockRPCTransport()
            return MediaClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listTranscriptionModels()
        }
    }

    @Test("saveVoiceNote throws when transport is nil")
    func saveVoiceNoteNoTransport() async {
        let client: MediaClient = {
            let transport = MockRPCTransport()
            return MediaClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.saveVoiceNote(audioData: Data())
        }
    }

    @Test("listVoiceNotes throws when transport is nil")
    func listVoiceNotesNoTransport() async {
        let client: MediaClient = {
            let transport = MockRPCTransport()
            return MediaClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listVoiceNotes()
        }
    }

    @Test("deleteVoiceNote throws when transport is nil")
    func deleteVoiceNoteNoTransport() async {
        let client: MediaClient = {
            let transport = MockRPCTransport()
            return MediaClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.deleteVoiceNote(filename: "test.m4a")
        }
    }

    @Test("getBrowserStatus with sessionId throws when transport is nil")
    func browserStatusNoTransport() async {
        let client: MediaClient = {
            let transport = MockRPCTransport()
            return MediaClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getBrowserStatus(sessionId: "test-session")
        }
    }
}
