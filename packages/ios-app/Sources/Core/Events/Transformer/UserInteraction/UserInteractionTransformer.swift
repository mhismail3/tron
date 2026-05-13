import Foundation

/// Transformer for UserInteraction capability_invocation content blocks.
///
/// Reads server-enriched status fields from the capability.invocation.started payload
/// (`interactionStatus`, `parsedAnswers`) injected by `session::reconstruct`
/// enrichment. For live WebSocket events (where the capability.invocation.started hasn't been
/// enriched yet), status defaults to `.generating`.
enum UserInteractionTransformer {

    /// Transform an UserInteraction capability_invocation content block into a ChatMessage.
    static func transform(
        invocationId: String,
        invocationStart: CapabilityInvocationStartedPayload?,
        contentBlock: [String: Any],
        timestamp: Date,
        tokenRecord: TokenRecord?,
        model: String?,
        turn: Int
    ) -> ChatMessage? {
        guard let argumentsJson = CapabilityArgumentExtractor.extractArguments(
            invocationStart: invocationStart,
            contentBlock: contentBlock
        ) else {
            TronLogger.shared.warning("UserInteraction: Could not extract arguments", category: .events)
            return nil
        }

        guard let paramsData = argumentsJson.data(using: .utf8),
              let params = try? JSONDecoder().decode(UserInteractionParams.self, from: paramsData) else {
            TronLogger.shared.warning("UserInteraction: Could not decode params from arguments", category: .events)
            return nil
        }

        // Read enriched fields from the server-provided capability.invocation.started payload.
        let payload = invocationStart?.rawPayload ?? [:]
        let (status, answers) = decodeEnrichment(from: payload)

        let result: UserInteractionResult? = (status == .answered && !answers.isEmpty)
            ? UserInteractionResult(
                answers: Array(answers.values),
                complete: true,
                submittedAt: ""
            )
            : nil

        let capabilityData = UserInteractionInvocationData(
            invocationId: invocationId,
            params: params,
            answers: answers,
            status: status,
            result: result
        )

        return ChatMessage(
            role: .assistant,
            content: .userInteraction(capabilityData),
            timestamp: timestamp,
            tokenRecord: tokenRecord,
            model: model,
            turnNumber: turn
        )
    }

    /// Decode `interactionStatus` / `parsedAnswers` fields injected by server-side
    /// enrichment.
    private static func decodeEnrichment(
        from payload: [String: AnyCodable]
    ) -> (status: UserInteractionStatus, answers: [String: UserInteractionAnswer]) {
        guard let statusStr = payload.string("interactionStatus") else {
            return (.generating, [:])
        }

        let status: UserInteractionStatus = switch statusStr {
        case "pending": .pending
        case "answered": .answered
        case "superseded": .superseded
        default: .pending
        }

        var answers: [String: UserInteractionAnswer] = [:]
        if let parsedValue = payload["parsedAnswers"],
           let parsedArray = parsedValue.value as? [[String: Any]] {
            for entry in parsedArray {
                guard let questionId = entry["questionId"] as? String else { continue }
                let selectedValues = (entry["selectedValues"] as? [String]) ?? []
                let otherValue = entry["otherValue"] as? String
                answers[questionId] = UserInteractionAnswer(
                    questionId: questionId,
                    selectedValues: selectedValues,
                    otherValue: otherValue
                )
            }
        }

        return (status, answers)
    }
}
