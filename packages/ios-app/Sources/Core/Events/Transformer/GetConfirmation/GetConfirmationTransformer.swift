import Foundation

/// Transformer for GetConfirmation tool_use content blocks.
///
/// Reads server-enriched status fields from the tool.call payload
/// (`toolStatus`, `confirmationDecision`, `confirmationNote`) injected by
/// `session.reconstruct` enrichment. For live WebSocket events (where the
/// tool.call hasn't been enriched yet), status defaults to `.generating`.
enum GetConfirmationTransformer {

    /// Transform a GetConfirmation tool_use content block into a ChatMessage.
    static func transform(
        toolUseId: String,
        toolCall: ToolCallPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        turn: Int
    ) -> ChatMessage? {
        guard let argumentsJson = ToolArgumentExtractor.extractArguments(
            toolCall: toolCall,
            contentBlock: contentBlock
        ) else {
            TronLogger.shared.warning("GetConfirmation: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(GetConfirmationParams.self, from: paramsData) else {
            TronLogger.shared.warning("GetConfirmation: Could not decode params from arguments", category: .events)
            return nil
        }

        // Read enriched fields from the server-provided tool.call payload.
        // Live events don't have these yet — default to .generating.
        let payload = toolCall?.rawPayload ?? [:]
        let (status, decision, note) = decodeEnrichment(from: payload)

        let result: GetConfirmationResult? = decision.map { decision in
            GetConfirmationResult(
                decision: decision,
                note: note,
                submittedAt: ""  // Not available from persisted data
            )
        }

        let toolData = GetConfirmationToolData(
            toolCallId: toolUseId,
            params: params,
            status: status,
            decision: decision,
            note: note,
            result: result
        )

        return ChatMessage(
            role: .assistant,
            content: .getConfirmation(toolData),
            timestamp: timestamp,
            turnNumber: turn
        )
    }

    /// Decode `toolStatus` / `confirmationDecision` / `confirmationNote`
    /// fields injected by server-side enrichment.
    private static func decodeEnrichment(
        from payload: [String: AnyCodable]
    ) -> (status: GetConfirmationStatus, decision: ConfirmationDecision?, note: String?) {
        guard let statusStr = payload.string("toolStatus") else {
            // Live event — no enrichment yet.
            return (.generating, nil, nil)
        }

        let status: GetConfirmationStatus = switch statusStr {
        case "pending": .pending
        case "approved": .approved
        case "denied": .denied
        case "superseded": .superseded
        default: .pending
        }

        let decision: ConfirmationDecision? = payload.string("confirmationDecision")
            .flatMap(ConfirmationDecision.init(rawValue:))
        let note = payload.string("confirmationNote")

        return (status, decision, note)
    }
}
