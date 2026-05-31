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

// MARK: - Voice Notes Methods

struct VoiceNotesSaveParams: Encodable {
    let audioBase64: String
    let mimeType: String?
}

struct VoiceNotesSaveResult: Decodable {
    let success: Bool
    let filename: String
    let filepath: String
    let transcription: VoiceNoteTranscription
}

struct VoiceNoteTranscription: Decodable {
    let text: String
    let language: String
    let durationSeconds: Double
}

struct VoiceNotesListParams: Encodable {
    let limit: Int?
    let offset: Int?

    init(limit: Int? = nil, offset: Int? = nil) {
        self.limit = limit
        self.offset = offset
    }
}

struct VoiceNoteMetadata: Decodable, Identifiable {
    let filename: String
    let filepath: String
    let createdAt: String
    let durationSeconds: Double?
    let language: String?
    let preview: String
    let transcript: String

    var id: String { filename }

    /// Formatted date for display
    var formattedDate: String {
        DateParser.mediumDateTime(createdAt)
    }

    /// Formatted duration (e.g., "2:34")
    var formattedDuration: String {
        guard let duration = durationSeconds else { return "--:--" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct VoiceNotesListResult: Decodable {
    let notes: [VoiceNoteMetadata]
    let totalCount: Int
    let hasMore: Bool
}

struct VoiceNotesDeleteParams: Encodable {
    let filename: String
}

struct VoiceNotesDeleteResult: Decodable {
    let success: Bool
    let filename: String
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
