import Foundation

// MARK: - Config Payloads

/// Payload for config.model_switch event
/// Server: ConfigModelSwitchEvent.payload
struct ModelSwitchPayload {
    let previousModel: String
    let newModel: String
    let reason: String?

    init?(from payload: [String: AnyCodable]) {
        // Both `previousModel` and `newModel` are required — the server
        // always emits both. The prior `payload.string("model") ?? ""`
        // recovery path accepted a field that hasn't been emitted since
        // pre-beta and is now forbidden by the current-shape policy.
        guard
            let previousModel = payload.string("previousModel"),
            let newModel = payload.string("newModel")
        else {
            TronLogger.shared.warning(
                "config.model_switch event missing previousModel or newModel; dropping",
                category: .events
            )
            return nil
        }

        self.previousModel = previousModel
        self.newModel = newModel
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
