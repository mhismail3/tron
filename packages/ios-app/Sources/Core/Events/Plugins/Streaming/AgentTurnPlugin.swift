import Foundation

/// Plugin for handling agent turn events.
/// These events contain the full message history with tool content blocks for a turn.
enum AgentTurnPlugin: EventPlugin {
    static let eventType = "agent.turn"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let messages: [TurnMessage]
            let turn: Int?
            let turnNumber: Int?

            var number: Int { turn ?? turnNumber ?? 1 }
        }
    }

    /// Message in an agent turn
    struct TurnMessage: Decodable, Sendable {
        let role: String
        let content: TurnContent

        enum CodingKeys: String, CodingKey {
            case role, content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(String.self, forKey: .role)

            // Content can be a string OR an array of content blocks
            if let stringContent = try? container.decode(String.self, forKey: .content) {
                content = .text(stringContent)
            } else if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = .blocks(blocks)
            } else {
                content = .text("")
            }
        }
    }

    /// Content in a turn message
    enum TurnContent: Sendable {
        case text(String)
        case blocks([ContentBlock])

        var textContent: String? {
            switch self {
            case .text(let str): return str
            case .blocks(let blocks):
                return blocks.compactMap { block -> String? in
                    if case .text(let text) = block { return text }
                    return nil
                }.joined()
            }
        }

        var allBlocks: [ContentBlock] {
            switch self {
            case .text(let str): return [.text(str)]
            case .blocks(let blocks): return blocks
            }
        }
    }

    /// Content block in a turn message
    enum ContentBlock: Decodable, Sendable {
        case text(String)
        case toolUse(id: String, name: String, input: [String: AnyCodable])
        case toolResult(toolUseId: String, content: String, isError: Bool)
        case thinking(text: String)
        case unknown

        enum CodingKeys: String, CodingKey {
            case type, text, id, name, input, toolUseId = "tool_use_id", content, isError = "is_error", thinking
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)

            switch type {
            case "text":
                let text = try container.decode(String.self, forKey: .text)
                self = .text(text)

            case "tool_use":
                let id = try container.decode(String.self, forKey: .id)
                let name = try container.decode(String.self, forKey: .name)
                let input = try container.decodeIfPresent([String: AnyCodable].self, forKey: .input) ?? [:]
                self = .toolUse(id: id, name: name, input: input)

            case "tool_result":
                let toolUseId = try container.decode(String.self, forKey: .toolUseId)
                let content: String
                if let str = try? container.decode(String.self, forKey: .content) {
                    content = str
                } else if let arr = try? container.decode([ContentPart].self, forKey: .content) {
                    content = arr.compactMap { $0.text }.joined()
                } else {
                    content = ""
                }
                let isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
                self = .toolResult(toolUseId: toolUseId, content: content, isError: isError)

            case "thinking":
                let text = try container.decodeIfPresent(String.self, forKey: .thinking) ?? ""
                self = .thinking(text: text)

            default:
                self = .unknown
            }
        }

        struct ContentPart: Decodable, Sendable {
            let type: String?
            let text: String?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let messages: [TurnMessage]
        let turnNumber: Int

        /// Extract all tool uses from assistant messages.
        var toolUses: [(id: String, name: String, input: [String: AnyCodable])] {
            messages.filter { $0.role == "assistant" }.flatMap { msg -> [(id: String, name: String, input: [String: AnyCodable])] in
                msg.content.allBlocks.compactMap { block in
                    if case .toolUse(let id, let name, let input) = block {
                        return (id, name, input)
                    }
                    return nil
                }
            }
        }

        /// Extract all tool results from user messages.
        var toolResults: [(toolUseId: String, content: String, isError: Bool)] {
            messages.filter { $0.role == "user" }.flatMap { msg -> [(toolUseId: String, content: String, isError: Bool)] in
                msg.content.allBlocks.compactMap { block in
                    if case .toolResult(let toolUseId, let content, let isError) = block {
                        return (toolUseId, content, isError)
                    }
                    return nil
                }
            }
        }
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            messages: event.data.messages,
            turnNumber: event.data.number
        )
    }
}
