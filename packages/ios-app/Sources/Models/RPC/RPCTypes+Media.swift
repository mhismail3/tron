import Foundation

// MARK: - Browser Methods

/// Start browser stream for a session
struct BrowserStartStreamParams: Encodable {
    let sessionId: String
    let quality: Int?
    let maxWidth: Int?
    let maxHeight: Int?
    let format: String?
    let everyNthFrame: Int?

    init(
        sessionId: String,
        quality: Int? = 60,
        maxWidth: Int? = 1280,
        maxHeight: Int? = 800,
        format: String? = "jpeg",
        everyNthFrame: Int? = 1
    ) {
        self.sessionId = sessionId
        self.quality = quality
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.format = format
        self.everyNthFrame = everyNthFrame
    }
}

struct BrowserStartStreamResult: Decodable {
    let success: Bool
    let error: String?
}

/// Stop browser stream for a session
struct BrowserStopStreamParams: Encodable {
    let sessionId: String
}

struct BrowserStopStreamResult: Decodable {
    let success: Bool
    let error: String?
}

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

/// Browser frame event data (received via WebSocket events)
/// Server sends: { type: "browser.frame", sessionId, timestamp, data: { sessionId, data, frameId, timestamp, metadata } }
struct BrowserFrameEvent: Decodable {
    let type: String
    let sessionId: String?
    let timestamp: String?
    let data: BrowserFrameData

    struct BrowserFrameData: Decodable {
        let sessionId: String
        /// Base64-encoded frame data (JPEG or PNG)
        let data: String
        /// Frame sequence number
        let frameId: Int
        /// Timestamp when frame was captured (milliseconds)
        let timestamp: Double
        /// Optional frame metadata
        let metadata: BrowserFrameMetadata?
    }

    /// Convenience accessors for nested data
    var frameData: String { data.data }
    var frameId: Int { data.frameId }
    var frameTimestamp: Double { data.timestamp }
    var frameSessionId: String { data.sessionId }
    var metadata: BrowserFrameMetadata? { data.metadata }
}

struct BrowserFrameMetadata: Decodable {
    let offsetTop: Double?
    let pageScaleFactor: Double?
    let deviceWidth: Double?
    let deviceHeight: Double?
    let scrollOffsetX: Double?
    let scrollOffsetY: Double?
}

// MARK: - Voice Notes Methods

struct VoiceNotesSaveParams: Encodable {
    let audioBase64: String
    let mimeType: String?
    let fileName: String?
    let transcriptionModelId: String?
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        // Fallback: try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: createdAt) {
            let displayFormatter = DateFormatter()
            displayFormatter.dateStyle = .medium
            displayFormatter.timeStyle = .short
            return displayFormatter.string(from: date)
        }
        return createdAt
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
    let fileName: String?
    let transcriptionModelId: String?
    let cleanupMode: String?
    let language: String?
    let prompt: String?
    let task: String?
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

struct TranscriptionModelInfo: Decodable, Identifiable {
    let id: String
    let label: String
    let description: String?
}

struct TranscribeListModelsResult: Decodable {
    let models: [TranscriptionModelInfo]
    let defaultModelId: String?
}
