import Foundation
import Testing
@testable import TronMobile

struct EngineProtocolTypesTranscriptionTests {
    @Test("Transcription model decodes runtime readiness state")
    func transcriptionModelDecodesRuntimeReadinessState() throws {
        let json = """
        {
          "models": [
            {
              "id": "parakeet-tdt-0.6b-v3",
              "name": "Parakeet TDT 0.6B v3",
              "size": "600M",
              "language": "en",
              "default": true,
              "enabled": true,
              "cached": false,
              "engineLoaded": false,
              "state": "loading",
              "message": "Local transcription model is loading."
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(TranscriptionModelsResult.self, from: json)

        #expect(result.models.first?.state == "loading")
        #expect(result.models.first?.message == "Local transcription model is loading.")
    }

    @Test("Transcription model remains compatible with old server payloads")
    func transcriptionModelDecodesWithoutRuntimeReadinessState() throws {
        let json = """
        {
          "models": [
            {
              "id": "parakeet-tdt-0.6b-v3",
              "name": "Parakeet TDT 0.6B v3",
              "size": "600M",
              "language": "en",
              "default": true,
              "enabled": true,
              "cached": true,
              "engineLoaded": true
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(TranscriptionModelsResult.self, from: json)

        #expect(result.models.first?.state == nil)
        #expect(result.models.first?.message == nil)
    }
}
