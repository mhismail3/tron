import Foundation

/// Lightweight model for displaying thinking blocks in the UI
/// Full content is NOT stored here - loaded on demand into ThinkingState.loadedFullContent
struct ThinkingBlock: Identifiable {
    let id: UUID
    let eventId: String
    let turnNumber: Int
    let preview: String
    let characterCount: Int
    let model: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        eventId: String,
        turnNumber: Int,
        preview: String,
        characterCount: Int,
        model: String?,
        timestamp: Date
    ) {
        self.id = id
        self.eventId = eventId
        self.turnNumber = turnNumber
        self.preview = preview
        self.characterCount = characterCount
        self.model = model
        self.timestamp = timestamp
    }

    /// Initialize from a ThinkingCompletePayload and event ID
    init(from payload: ThinkingCompletePayload, eventId: String) {
        self.id = UUID()
        self.eventId = eventId
        self.turnNumber = payload.turnNumber
        self.preview = payload.preview
        self.characterCount = payload.characterCount
        self.model = payload.model
        self.timestamp = payload.timestamp
    }

    /// Formatted timestamp for display
    var formattedTimestamp: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: timestamp, relativeTo: Date())
    }

    /// Short model name for display
    var shortModelName: String? {
        model?.shortModelName
    }
}
