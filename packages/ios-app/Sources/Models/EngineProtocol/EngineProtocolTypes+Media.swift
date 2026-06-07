import Foundation

// MARK: - Browser Methods

/// Get browser status for a session
struct BrowserGetStatusParams: Encodable {
    let sessionId: String
}

struct BrowserGetStatusResult: Decodable {
    var hasBrowser: Bool
    var isStreaming: Bool
    var currentUrl: String?

    init(hasBrowser: Bool, isStreaming: Bool, currentUrl: String?) {
        self.hasBrowser = hasBrowser
        self.isStreaming = isStreaming
        self.currentUrl = currentUrl
    }
}

// MARK: - Transcription Methods

struct TranscribeAudioParams: Encodable {
    let sessionId: String?
    let audioBase64: String
    let mimeType: String?
}

struct TranscribeAudioResult: Decodable {
    let text: String
    let rawText: String
    let language: String
    let durationSeconds: Double
    let processingTimeMs: Int
    let model: String
    let device: String
    let computeType: String
    let cleanupMode: String
}
