import Foundation

// MARK: - Config Payloads

/// Payload for config.model_switch event
/// Server: ConfigModelSwitchEvent.payload
struct ModelSwitchPayload {
    let previousModel: String
    let newModel: String
    let reason: String?

    init?(from payload: [String: AnyCodable]) {
        guard let previousModel = payload.string("previousModel") else {
            return nil
        }

        self.previousModel = previousModel
        self.newModel = payload.string("newModel")
            ?? payload.string("model") ?? ""
        self.reason = payload.string("reason")
    }
}

/// Payload for config.prompt_update event
/// Server: ConfigPromptUpdateEvent.payload
struct ConfigPromptUpdatePayload {
    let previousHash: String?
    let newHash: String
    let contentBlobId: String?

    init?(from payload: [String: AnyCodable]) {
        guard let newHash = payload.string("newHash") else {
            return nil
        }
        self.previousHash = payload.string("previousHash")
        self.newHash = newHash
        self.contentBlobId = payload.string("contentBlobId")
    }
}

/// Payload for config.reasoning_level event
/// Server: ConfigReasoningLevelEvent.payload
struct ReasoningLevelPayload {
    let previousLevel: String?
    let newLevel: String?

    init(from payload: [String: AnyCodable]) {
        self.previousLevel = payload.string("previousLevel")
        self.newLevel = payload.string("newLevel")
    }
}

/// Payload for message.deleted event
/// Server: MessageDeletedEvent.payload
struct MessageDeletedPayload {
    let targetEventId: String
    let targetType: String
    let targetTurn: Int?
    let reason: String?

    init?(from payload: [String: AnyCodable]) {
        guard let targetEventId = payload.string("targetEventId"),
              let targetType = payload.string("targetType") else {
            return nil
        }
        self.targetEventId = targetEventId
        self.targetType = targetType
        self.targetTurn = payload.int("targetTurn")
        self.reason = payload.string("reason")
    }
}

// MARK: - Notification Payloads

/// Payload for notification.interrupted event
struct InterruptedPayload {
    let timestamp: String?
    let turn: Int?

    init(from payload: [String: AnyCodable]) {
        self.timestamp = payload.string("timestamp")
        self.turn = payload.int("turn")
    }
}
