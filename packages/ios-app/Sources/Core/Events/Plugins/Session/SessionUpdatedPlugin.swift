import Foundation

/// Plugin for handling session.updated events.
/// These events carry updated session metadata (tokens, cost, title, previews)
/// for real-time dashboard sync across devices.
enum SessionUpdatedPlugin: EventPlugin {
    static let eventType = "session.updated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sessionId: String?
            let title: String?
            let model: String?
            let messageCount: Int?
            let inputTokens: Int?
            let outputTokens: Int?
            let lastTurnInputTokens: Int?
            let cacheReadTokens: Int?
            let cacheCreationTokens: Int?
            let cost: Double?
            let lastActivity: String?
            let isActive: Bool?
            let lastUserPrompt: String?
            let lastAssistantResponse: String?
            let parentSessionId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let sessionId: String
        let title: String?
        let model: String?
        let messageCount: Int?
        let inputTokens: Int?
        let outputTokens: Int?
        let lastTurnInputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
        let cost: Double?
        let lastActivity: String?
        let isActive: Bool?
        let lastUserPrompt: String?
        let lastAssistantResponse: String?
        let parentSessionId: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let sid = event.sessionId ?? event.data?.sessionId else { return nil }
        return Result(
            sessionId: sid,
            title: event.data?.title,
            model: event.data?.model,
            messageCount: event.data?.messageCount,
            inputTokens: event.data?.inputTokens,
            outputTokens: event.data?.outputTokens,
            lastTurnInputTokens: event.data?.lastTurnInputTokens,
            cacheReadTokens: event.data?.cacheReadTokens,
            cacheCreationTokens: event.data?.cacheCreationTokens,
            cost: event.data?.cost,
            lastActivity: event.data?.lastActivity,
            isActive: event.data?.isActive,
            lastUserPrompt: event.data?.lastUserPrompt,
            lastAssistantResponse: event.data?.lastAssistantResponse,
            parentSessionId: event.data?.parentSessionId
        )
    }
}
