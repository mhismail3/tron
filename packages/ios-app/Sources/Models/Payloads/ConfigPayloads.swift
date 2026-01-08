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
