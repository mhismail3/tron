import Foundation

struct TranscribeAudioParams: Encodable {
    let sessionId: String?
    let audioBase64: String
    let mimeType: String
}

struct TranscribeAudioResult: Decodable, Equatable {
    let text: String
    let rawText: String
    let language: String
    let durationSeconds: Double
    let processingTimeMs: UInt64
    let model: String
    let device: String
    let computeType: String
    let cleanupMode: String
}

struct TranscriptionModelsResult: Decodable, Equatable {
    let models: [TranscriptionModel]
}

struct TranscriptionModel: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let size: String
    let language: String
    let `default`: Bool
    let enabled: Bool
    let cached: Bool
    let engineLoaded: Bool
    let state: String?
    let message: String?
}

struct TranscriptionDownloadModelResult: Decodable, Equatable {
    let started: Bool
    let reason: String
    let message: String?
}
