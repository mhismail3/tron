import Foundation

/// Plugin for handling tool end events.
/// These events signal the completion of a tool invocation with results.
///
/// Note: Uses custom parsing to handle output as either String or [ContentBlock] array.
enum ToolEndPlugin: EventPlugin {
    static let eventType = "agent.tool_end"

    // MARK: - Event Data

    struct EventData: Decodable, Sendable {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let toolCallId: String
            let toolName: String?
            let success: Bool
            let result: String?
            let output: String?
            let error: String?
            let durationMs: Int?
            let duration: Int?
            let details: ToolDetails?

            enum CodingKeys: String, CodingKey {
                case toolCallId, toolName, success, result, output, error, durationMs, duration, details
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                toolCallId = try container.decode(String.self, forKey: .toolCallId)
                toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
                success = try container.decode(Bool.self, forKey: .success)
                result = try container.decodeIfPresent(String.self, forKey: .result)
                error = try container.decodeIfPresent(String.self, forKey: .error)
                durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
                duration = try container.decodeIfPresent(Int.self, forKey: .duration)
                details = try container.decodeIfPresent(ToolDetails.self, forKey: .details)

                // Handle output as either String or [ContentBlock] array
                if let outputString = try? container.decodeIfPresent(String.self, forKey: .output) {
                    output = outputString
                } else if let outputBlocks = try? container.decodeIfPresent([ToolOutputBlock].self, forKey: .output) {
                    output = outputBlocks.compactMap { $0.text }.joined()
                } else {
                    output = nil
                }
            }
        }

        /// Details structure for tool results (e.g., screenshot data).
        struct ToolDetails: Decodable, Sendable {
            let screenshot: String?
            let format: String?
        }
    }

    /// Helper struct for decoding tool output content blocks.
    private struct ToolOutputBlock: Decodable {
        let type: String
        let text: String?
    }

    // MARK: - Result

    struct Result: EventResult {
        let toolCallId: String
        let toolName: String?
        let success: Bool
        let result: String?
        let error: String?
        let durationMs: Int?
        let details: EventData.ToolDetails?

        /// Display-friendly result text.
        var displayResult: String {
            if success {
                return result ?? ""
            } else {
                return error ?? "Error"
            }
        }
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        event.sessionId
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            toolCallId: event.data.toolCallId,
            toolName: event.data.toolName,
            success: event.data.success,
            result: event.data.result ?? event.data.output,
            error: event.data.error,
            durationMs: event.data.durationMs ?? event.data.duration,
            details: event.data.details
        )
    }
}
