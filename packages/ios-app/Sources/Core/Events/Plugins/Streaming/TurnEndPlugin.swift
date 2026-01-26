import Foundation

/// Plugin for handling turn end events.
/// These events signal the completion of an agent turn with usage statistics.
enum TurnEndPlugin: EventPlugin {
    static let eventType = "agent.turn_end"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload?

        struct DataPayload: Decodable, Sendable {
            let turn: Int?
            let turnNumber: Int?
            let duration: Int?
            let tokenUsage: TokenUsage?
            let normalizedUsage: NormalizedTokenUsage?
            let stopReason: String?
            let cost: Double?
            let contextLimit: Int?

            enum CodingKeys: String, CodingKey {
                case turn, turnNumber, duration, tokenUsage, normalizedUsage, stopReason, cost, contextLimit
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                turn = try container.decodeIfPresent(Int.self, forKey: .turn)
                turnNumber = try container.decodeIfPresent(Int.self, forKey: .turnNumber)
                duration = try container.decodeIfPresent(Int.self, forKey: .duration)
                tokenUsage = try container.decodeIfPresent(TokenUsage.self, forKey: .tokenUsage)
                normalizedUsage = try container.decodeIfPresent(NormalizedTokenUsage.self, forKey: .normalizedUsage)
                stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
                contextLimit = try container.decodeIfPresent(Int.self, forKey: .contextLimit)

                // Handle cost as either Double or String
                if let costDouble = try? container.decodeIfPresent(Double.self, forKey: .cost) {
                    cost = costDouble
                } else if let costString = try? container.decodeIfPresent(String.self, forKey: .cost),
                          let costValue = Double(costString) {
                    cost = costValue
                } else {
                    cost = nil
                }
            }

            /// Unified turn number accessor (handles both field names).
            var number: Int { turn ?? turnNumber ?? 1 }
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let turnNumber: Int
        let duration: Int?
        let tokenUsage: TokenUsage?
        let normalizedUsage: NormalizedTokenUsage?
        let stopReason: String?
        let cost: Double?
        let contextLimit: Int?
    }

    // MARK: - Protocol Implementation

    static func transform(_ event: EventData) -> (any EventResult)? {
        guard let data = event.data else {
            return Result(
                turnNumber: 1,
                duration: nil,
                tokenUsage: nil,
                normalizedUsage: nil,
                stopReason: nil,
                cost: nil,
                contextLimit: nil
            )
        }
        return Result(
            turnNumber: data.number,
            duration: data.duration,
            tokenUsage: data.tokenUsage,
            normalizedUsage: data.normalizedUsage,
            stopReason: data.stopReason,
            cost: data.cost,
            contextLimit: data.contextLimit
        )
    }
}
