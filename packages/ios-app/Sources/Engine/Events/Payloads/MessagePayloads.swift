import Foundation

// MARK: - Message Payloads

/// Engine-authored content of a durable `message.agent` event.
///
/// Coordination semantics remain strings so a newer server can introduce a
/// presentation label without making an older client discard the transcript.
/// Identity, authority, and correlation fields are retained verbatim for the
/// read-only audit surface; only the bounded display name is optional.
struct AgentMessageContent: Codable, Equatable, Sendable {
    let messageId: String
    let sourceAgentId: String
    let sourceName: String?
    let kind: String
    let authority: String
    let text: String
    let assignmentId: String?
    let replyTo: String?

    init(
        messageId: String,
        sourceAgentId: String,
        sourceName: String? = nil,
        kind: String,
        authority: String,
        text: String,
        assignmentId: String? = nil,
        replyTo: String? = nil
    ) {
        self.messageId = messageId
        self.sourceAgentId = sourceAgentId
        self.sourceName = sourceName
        self.kind = kind
        self.authority = authority
        self.text = text
        self.assignmentId = assignmentId
        self.replyTo = replyTo
    }

    init?(from payload: [String: AnyCodable]) {
        guard let messageId = payload.string("messageId"), !messageId.isEmpty,
              let sourceAgentId = payload.string("sourceAgentId"), !sourceAgentId.isEmpty,
              let kind = payload.string("kind"), !kind.isEmpty,
              let authority = payload.string("authority"), !authority.isEmpty,
              let text = payload.string("text") else {
            return nil
        }
        self.init(
            messageId: messageId,
            sourceAgentId: sourceAgentId,
            sourceName: payload.string("sourceName"),
            kind: kind,
            authority: authority,
            text: text,
            assignmentId: payload.string("assignmentId"),
            replyTo: payload.string("replyTo")
        )
    }

    /// Decode the canonical persisted envelope `{ "content": { ... } }`.
    init?(eventPayload payload: [String: AnyCodable]) {
        guard let rawContent = payload["content"]?.dictionaryValue else {
            return nil
        }
        self.init(from: rawContent.mapValues(AnyCodable.init))
    }
}

/// Payload for message.user event
/// Server: UserMessageEvent.payload
///
/// NOTE: message.user events can contain:
/// 1. User text prompts (displayable)
/// 2. Tool result content blocks (LLM context, not for display - handled by tool.invocation.completed events)
/// 3. Image/document content blocks (displayable as thumbnails above text)
struct UserMessagePayload {
    let content: String
    /// Optional because live prompt emitters historically stored
    /// user messages with only `content`; imported sessions may include it.
    let turn: Int?
    let imageCount: Int?
    /// True if this message contains ONLY tool_result blocks (no text)
    /// These are LLM conversation context, not displayable user messages
    let isToolResultContext: Bool
    /// Attachments to this message (images, PDFs, documents)
    let attachments: [Attachment]?
    let userInputAnswer: UserInputAnswerRecord?
    init?(from payload: [String: AnyCodable]) {
        var extractedAttachments: [Attachment] = []

        // Content can be a string or array of content blocks
        if let content = payload.string("content") {
            self.content = content
            self.isToolResultContext = false
        } else if let contentBlocks = payload["content"]?.value as? [[String: Any]] {
            // Check if this is a tool_result context message (no text, only tool_results)
            let textBlocks = contentBlocks.filter { ($0["type"] as? String) == ContentBlockType.text.rawValue }
            let toolResultBlocks = contentBlocks.filter { ($0["type"] as? String) == ContentBlockType.toolResult.rawValue }

            if textBlocks.isEmpty && !toolResultBlocks.isEmpty {
                // This is a tool_result context message - not for display
                // Tool results are displayed via tool.invocation.completed events
                self.content = ""
                self.isToolResultContext = true
            } else {
                // Extract text from content blocks
                let texts = contentBlocks.compactMap { block -> String? in
                    guard block["type"] as? String == ContentBlockType.text.rawValue else { return nil }
                    return block["text"] as? String
                }
                self.content = texts.joined(separator: "\n")
                self.isToolResultContext = false
            }

            // Extract attachments from content blocks (images, documents, PDFs)
            for block in contentBlocks {
                let blockType = block["type"] as? String

                if blockType == ContentBlockType.image.rawValue {
                    if let base64Data = block["data"] as? String,
                       let mimeType = block["mimeType"] as? String,
                       let data = Data(base64Encoded: base64Data) {
                        extractedAttachments.append(Attachment(
                            type: .image,
                            data: data,
                            mimeType: mimeType,
                            fileName: nil
                        ))
                    }
                } else if blockType == ContentBlockType.document.rawValue {
                    // Document: Server format { type: 'document', data: <base64>, mimeType, fileName }
                    // Includes PDFs, text files (text/*), and JSON files
                    if let base64Data = block["data"] as? String,
                       let mimeType = block["mimeType"] as? String,
                       let data = Data(base64Encoded: base64Data) {
                        let fileName = block["fileName"] as? String
                        let attachmentType: AttachmentType
                        if mimeType == "application/pdf" {
                            attachmentType = .pdf
                        } else if mimeType.hasPrefix("text/") || mimeType == "application/json" {
                            attachmentType = .document
                        } else {
                            attachmentType = .document
                        }
                        extractedAttachments.append(Attachment(
                            type: attachmentType,
                            data: data,
                            mimeType: mimeType,
                            fileName: fileName
                        ))
                    }
                }
            }
        } else {
            return nil
        }

        self.turn = payload.int("turn")
        self.imageCount = payload.int("imageCount")
        self.attachments = extractedAttachments.isEmpty ? nil : extractedAttachments
        if payload.string("messageKind") == "user_input_answer",
           let invocationId = payload.string("invocationId"),
           let rawAnswers = payload["answers"]?.value as? [[String: Any]] {
            let answers = rawAnswers.compactMap { raw -> UserInputAnswer? in
                guard let questionId = raw["questionId"] as? String else { return nil }
                return UserInputAnswer(
                    questionId: questionId,
                    selectedLabel: raw["selectedLabel"] as? String,
                    freeText: raw["freeText"] as? String
                )
            }
            self.userInputAnswer = UserInputAnswerRecord(
                invocationId: invocationId,
                answers: answers
            )
        } else {
            self.userInputAnswer = nil
        }
    }
}

/// Payload for message.assistant event
/// Server: `events/types/payloads/message.rs::AssistantMessagePayload`
///
/// IMPORTANT: This payload contains ContentBlocks which may include tool_invocation blocks.
/// However, tool_invocation blocks should be IGNORED here — they are rendered via tool.invocation.started events.
///
/// `content`, `turn`, `model`, and `stopReason` are all non-optional on the
/// Rust payload. Missing any of them fails decoding (`init?` returns nil)
/// rather than silently pinning the message to turn 1 or leaving the model
/// label blank — both defaults have lied in the past when an emitter skipped
/// a field.
struct AssistantMessagePayload {
    let contentBlocks: [[String: Any]]
    let turn: Int
    let tokenRecord: TokenRecord?
    let stopReason: StopReason?
    let latencyMs: Int?
    let model: String
    let hasThinking: Bool?
    let interrupted: Bool?
    let agentDeliveryProvenance: [AgentDeliveryMessageProvenance]

    /// Whether the provider response contains tool invocations. Their
    /// presence makes the response ineligible for a final textual-response
    /// footer whether tool execution continues or explicitly stops.
    var hasToolInvocations: Bool {
        contentBlocks.contains {
            $0["type"] as? String == ContentBlockType.toolInvocation.rawValue
        }
    }

    /// Conservative, server-contract-backed presentation eligibility. A
    /// completed text response with zero tool drafts is guaranteed to end
    /// the agent loop; interrupted or tool-bearing responses get no
    /// footer. Rendered position and provider stop-reason spelling are ignored.
    var isFinalAssistantResponse: Bool {
        textContent != nil && !hasToolInvocations && interrupted != true
    }

    /// Extracts ONLY the text content, ignoring tool_invocation blocks.
    /// Tool invocations are rendered via separate tool.invocation.started events.
    ///
    /// INVARIANT: the trimming here (`.whitespacesAndNewlines`) MUST
    /// match `StreamingManager.finalizeStreamingMessage` so the
    /// reconstructed text for an assistant message converges with the
    /// live-finalized text for the same message. Guarded by
    /// `TextStreamConvergenceTests`.
    var textContent: String? {
        let texts = contentBlocks.compactMap { block -> String? in
            guard block["type"] as? String == ContentBlockType.text.rawValue else { return nil }
            return block["text"] as? String
        }
        guard !texts.isEmpty else { return nil }
        let joined = texts.joined(separator: "\n")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extracts thinking content if present
    var thinkingContent: String? {
        let thoughts = contentBlocks.compactMap { block -> String? in
            guard block["type"] as? String == ContentBlockType.thinking.rawValue else { return nil }
            return block["thinking"] as? String
        }
        return thoughts.isEmpty ? nil : thoughts.joined(separator: "\n")
    }

    init?(from payload: [String: AnyCodable]) {
        // `content` is `Value` (non-optional) on the server, and iOS needs it
        // to be an array-of-blocks in every production code path. A plain
        // string or missing key is a schema violation.
        guard let blocks = payload["content"]?.value as? [[String: Any]] else {
            TronLogger.shared.warning(
                "message.assistant event missing required field 'content' (array of blocks); dropping",
                category: .events
            )
            return nil
        }
        guard let turn = payload.int("turn"),
              let model = payload.string("model"),
              let stopStr = payload.string("stopReason") else {
            TronLogger.shared.warning(
                "message.assistant event missing required field(s) turn/model/stopReason; dropping",
                category: .events
            )
            return nil
        }

        self.contentBlocks = blocks
        self.turn = turn
        self.model = model
        self.stopReason = StopReason(rawValue: stopStr)

        self.tokenRecord = TokenRecord.from(dict: payload.dict("tokenRecord"))
        self.latencyMs = payload.int("latency") ?? payload.int("latencyMs")
        self.hasThinking = payload.bool("hasThinking")
        self.interrupted = payload.bool("interrupted")
        self.agentDeliveryProvenance = payload
            .dict("agentDeliveryContinuation")?["deliveries"]
            .flatMap { AnyCodable($0).arrayValue }?
            .compactMap { value -> AgentDeliveryMessageProvenance? in
                guard let object = value as? [String: Any],
                      let deliveryId = object["deliveryId"] as? String,
                      let sourceKind = object["sourceKind"] as? String else {
                    return nil
                }
                return AgentDeliveryMessageProvenance(
                    deliveryId: deliveryId,
                    sourceKind: sourceKind,
                    sourceWorkerId: object["sourceWorkerId"] as? String,
                    sourceWorkerName: object["sourceWorkerName"] as? String,
                    sourceSessionId: object["sourceSessionId"] as? String,
                    sourceInvocationId: object["sourceInvocationId"] as? String,
                    wakePolicy: object["wakePolicy"] as? String,
                    boundary: object["boundary"] as? String,
                    triggeredWake: object["triggeredWake"] as? Bool,
                    redelivery: object["redelivery"] as? Bool ?? false,
                    includedInThisTurn: object["includedInThisTurn"] as? Bool
                )
            } ?? []
    }
}

/// Payload for a durable message tombstone.
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
