import Foundation

// MARK: - Message Payloads

/// Payload for message.user event
/// Server: UserMessageEvent.payload
///
/// NOTE: message.user events can contain:
/// 1. User text prompts (displayable)
/// 2. Capability result content blocks (LLM context, not for display - handled by capability.invocation.completed events)
/// 3. Image/document content blocks (displayable as thumbnails above text)
struct UserMessagePayload {
    let content: String
    /// Optional because live Tron prompt/subagent emitters historically stored
    /// user messages with only `content`; imported sessions may include it.
    let turn: Int?
    let imageCount: Int?
    /// True if this message contains ONLY capability_result blocks (no text)
    /// These are LLM conversation context, not displayable user messages
    let isCapabilityResultContext: Bool
    /// Attachments to this message (images, PDFs, documents)
    let attachments: [Attachment]?
    /// Skills referenced in this message (rendered as cyan chips above the message)
    let skills: [Skill]?
    /// Server-provided structured message kind for interactive-capability responses.
    /// Values: `"answered_questions"`, `"subagent_results_delivered"`. When present,
    /// iOS renders a chip instead of the plain text content.
    let messageKind: String?
    /// Number of questions answered for `messageKind == "answered_questions"`.
    let answerCount: Int?
    /// Number of subagent results delivered for `messageKind == "subagent_results_delivered"`.
    let subagentCount: Int?

    init?(from payload: [String: AnyCodable]) {
        var extractedAttachments: [Attachment] = []

        // Content can be a string or array of content blocks
        if let content = payload.string("content") {
            self.content = content
            self.isCapabilityResultContext = false
        } else if let contentBlocks = payload["content"]?.value as? [[String: Any]] {
            // Check if this is a capability_result context message (no text, only capability_results)
            let textBlocks = contentBlocks.filter { ($0["type"] as? String) == ContentBlockType.text.rawValue }
            let capabilityResultBlocks = contentBlocks.filter { ($0["type"] as? String) == ContentBlockType.capabilityResult.rawValue }

            if textBlocks.isEmpty && !capabilityResultBlocks.isEmpty {
                // This is a capability_result context message - not for display
                // Capability results are displayed via capability.invocation.completed events
                self.content = ""
                self.isCapabilityResultContext = true
            } else {
                // Extract text from content blocks
                let texts = contentBlocks.compactMap { block -> String? in
                    guard block["type"] as? String == ContentBlockType.text.rawValue else { return nil }
                    return block["text"] as? String
                }
                self.content = texts.joined(separator: "\n")
                self.isCapabilityResultContext = false
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

        // Parse skills from payload. `service` is populated for events written
        // after the service-tagging refactor; older stored events omit it, in
        // which case we fall through to the Skill.init default ("tron"), so no
        // service badge renders for historic activations — matching pre-refactor
        // display behavior.
        if let skillsArray = payload["skills"]?.value as? [[String: Any]] {
            self.skills = skillsArray.compactMap { skillDict -> Skill? in
                guard let name = skillDict["name"] as? String else { return nil }
                let sourceString = skillDict["source"] as? String ?? "project"
                let source: SkillSource = sourceString == "global" ? .global : .project
                let displayName = skillDict["displayName"] as? String ?? name
                let service = skillDict["service"] as? String ?? SkillService.tron.rawValue
                return Skill(
                    name: name,
                    displayName: displayName,
                    description: "",
                    source: source,
                    tags: nil,
                    service: service
                )
            }
        } else {
            self.skills = nil
        }

        // Structured interactive-capability response metadata (server-provided).
        self.messageKind = payload.string("messageKind")
        self.answerCount = payload.int("answerCount")
        self.subagentCount = payload.int("subagentCount")
    }
}

/// Payload for message.assistant event
/// Server: `events/types/payloads/message.rs::AssistantMessagePayload`
///
/// IMPORTANT: This payload contains ContentBlocks which may include capability_invocation blocks.
/// However, capability_invocation blocks should be IGNORED here — they are rendered via capability.invocation.started events.
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

    /// Extracts ONLY the text content, ignoring capability_invocation blocks.
    /// Capability invocations are rendered via separate capability.invocation.started events.
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
    }
}

/// Payload for message.system event
/// Server: `events/types/payloads/message.rs::SystemMessagePayload`
///
/// Both `content` and `source` are non-optional on the Rust payload.
/// Missing `source` or an unknown value fails decode rather than silently
/// dropping the discriminator that would otherwise let the UI route the
/// message (compaction banner vs. error banner vs. hook output).
struct SystemMessagePayload {
    let content: String
    let source: SystemMessageSource

    init?(from payload: [String: AnyCodable]) {
        guard let content = payload.string("content"),
              let sourceStr = payload.string("source"),
              let source = SystemMessageSource(rawValue: sourceStr) else {
            TronLogger.shared.warning(
                "message.system event missing required field(s) content/source or unknown source value; dropping",
                category: .events
            )
            return nil
        }
        self.content = content
        self.source = source
    }
}
