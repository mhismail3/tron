import Foundation

/// Plugin for handling session.created events.
/// These events carry new session metadata for real-time dashboard sync across devices.
enum SessionCreatedPlugin: EventPlugin {
    static let eventType = "session.created"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let sessionId: String?
            let workingDirectory: String?
            let model: String?
            let title: String?
            let messageCount: Int?
            let inputTokens: Int?
            let outputTokens: Int?
            let lastTurnInputTokens: Int?
            let cacheReadTokens: Int?
            let cacheCreationTokens: Int?
            let cost: Double?
            let lastActivity: String?
            let isActive: Bool?
            let parentSessionId: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let sessionId: String
        let workingDirectory: String?
        let model: String?
        let title: String?
        let messageCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let lastTurnInputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let cost: Double
        let lastActivity: String
        let isActive: Bool
        let parentSessionId: String?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let sid = event.sessionId ?? event.data?.sessionId else { return nil }
        return Result(
            sessionId: sid,
            workingDirectory: event.data?.workingDirectory,
            model: event.data?.model,
            title: event.data?.title,
            messageCount: event.data?.messageCount ?? 0,
            inputTokens: event.data?.inputTokens ?? 0,
            outputTokens: event.data?.outputTokens ?? 0,
            lastTurnInputTokens: event.data?.lastTurnInputTokens ?? 0,
            cacheReadTokens: event.data?.cacheReadTokens ?? 0,
            cacheCreationTokens: event.data?.cacheCreationTokens ?? 0,
            cost: event.data?.cost ?? 0,
            lastActivity: event.data?.lastActivity ?? event.timestamp ?? ISO8601DateFormatter().string(from: Date()),
            isActive: event.data?.isActive ?? true,
            parentSessionId: event.data?.parentSessionId
        )
    }
}
