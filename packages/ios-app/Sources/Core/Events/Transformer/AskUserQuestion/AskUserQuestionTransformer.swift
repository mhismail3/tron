import Foundation

/// Transformer for AskUserQuestion tool_use content blocks.
///
/// Reads server-enriched status fields from the capability.invocation.started payload
/// (`toolStatus`, `parsedAnswers`) injected by `session::reconstruct`
/// enrichment. For live WebSocket events (where the capability.invocation.started hasn't been
/// enriched yet), status defaults to `.generating`.
enum AskUserQuestionTransformer {

    /// Transform an AskUserQuestion tool_use content block into a ChatMessage.
    static func transform(
        toolUseId: String,
        toolCall: CapabilityInvocationStartedPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        tokenRecord: TokenRecord?,
        model: String?,
        turn: Int
    ) -> ChatMessage? {
        guard let argumentsJson = CapabilityArgumentExtractor.extractArguments(
            toolCall: toolCall,
            contentBlock: contentBlock
        ) else {
            TronLogger.shared.warning("AskUserQuestion: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(AskUserQuestionParams.self, from: paramsData) else {
            TronLogger.shared.warning("AskUserQuestion: Could not decode params from arguments", category: .events)
            return nil
        }

        // Read enriched fields from the server-provided capability.invocation.started payload.
        let payload = toolCall?.rawPayload ?? [:]
        let (status, answers) = decodeEnrichment(from: payload)

        let result: AskUserQuestionResult? = (status == .answered && !answers.isEmpty)
            ? AskUserQuestionResult(
                answers: Array(answers.values),
                complete: true,
                submittedAt: ""
            )
            : nil

        let toolData = AskUserQuestionToolData(
            invocationId: toolUseId,
            params: params,
            answers: answers,
            status: status,
            result: result
        )

        return ChatMessage(
            role: .assistant,
            content: .askUserQuestion(toolData),
            timestamp: timestamp,
            tokenRecord: tokenRecord,
            model: model,
            turnNumber: turn
        )
    }

    /// Decode `toolStatus` / `parsedAnswers` fields injected by server-side
    /// enrichment.
    private static func decodeEnrichment(
        from payload: [String: AnyCodable]
    ) -> (status: AskUserQuestionStatus, answers: [String: AskUserQuestionAnswer]) {
        guard let statusStr = payload.string("toolStatus") else {
            return (.generating, [:])
        }

        let status: AskUserQuestionStatus = switch statusStr {
        case "pending": .pending
        case "answered": .answered
        case "superseded": .superseded
        default: .pending
        }

        var answers: [String: AskUserQuestionAnswer] = [:]
        if let parsedValue = payload["parsedAnswers"],
           let parsedArray = parsedValue.value as? [[String: Any]] {
            for entry in parsedArray {
                guard let questionId = entry["questionId"] as? String else { continue }
                let selectedValues = (entry["selectedValues"] as? [String]) ?? []
                let otherValue = entry["otherValue"] as? String
                answers[questionId] = AskUserQuestionAnswer(
                    questionId: questionId,
                    selectedValues: selectedValues,
                    otherValue: otherValue
                )
            }
        }

        return (status, answers)
    }
}
