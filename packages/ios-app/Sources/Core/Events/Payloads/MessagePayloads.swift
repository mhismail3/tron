import Foundation

// MARK: - Message Payloads

/// Payload for message.user event
/// Server: UserMessageEvent.payload
///
/// NOTE: message.user events can contain:
/// 1. User text prompts (displayable)
/// 2. Tool result content blocks (LLM context, not for display - handled by tool.result events)
/// 3. Image/document content blocks (displayable as thumbnails above text)
struct UserMessagePayload {
    let content: String
    let turn: Int
    let imageCount: Int?
    /// True if this message contains ONLY tool_result blocks (no text)
    /// These are LLM conversation context, not displayable user messages
    let isToolResultContext: Bool
    /// Attachments to this message (images, PDFs, documents)
    let attachments: [Attachment]?
    /// Skills referenced in this message (rendered as cyan chips above the message)
    let skills: [Skill]?
    /// Spells referenced in this message (ephemeral skills, rendered as pink chips)
    let spells: [Skill]?

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
                // Tool results are displayed via tool.result events
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

        self.turn = payload.int("turn") ?? 1
        self.imageCount = payload.int("imageCount")
        self.attachments = extractedAttachments.isEmpty ? nil : extractedAttachments

        // Parse skills from payload
        if let skillsArray = payload["skills"]?.value as? [[String: Any]] {
            self.skills = skillsArray.compactMap { skillDict -> Skill? in
                guard let name = skillDict["name"] as? String else { return nil }
                let sourceString = skillDict["source"] as? String ?? "project"
                let source: SkillSource = sourceString == "global" ? .global : .project
                let displayName = skillDict["displayName"] as? String ?? name
                return Skill(
                    name: name,
                    displayName: displayName,
                    description: "",
                    source: source,
                    tags: nil
                )
            }
        } else {
            self.skills = nil
        }

        // Parse spells from payload (ephemeral skills)
        if let spellsArray = payload["spells"]?.value as? [[String: Any]] {
            self.spells = spellsArray.compactMap { spellDict -> Skill? in
                guard let name = spellDict["name"] as? String else { return nil }
                let sourceString = spellDict["source"] as? String ?? "project"
                let source: SkillSource = sourceString == "global" ? .global : .project
                let displayName = spellDict["displayName"] as? String ?? name
                return Skill(
                    name: name,
                    displayName: displayName,
                    description: "",
                    source: source,
                    tags: nil
                )
            }
        } else {
            self.spells = nil
        }
    }
}

/// Payload for message.assistant event
/// Server: AssistantMessageEvent.payload
///
/// IMPORTANT: This payload contains ContentBlocks which may include tool_use blocks.
/// However, tool_use blocks should be IGNORED here - they are rendered via tool.call events.
struct AssistantMessagePayload {
    let contentBlocks: [[String: Any]]?
    let turn: Int
    let tokenRecord: TokenRecord?
    let stopReason: StopReason?
    let latencyMs: Int?
    let model: String?
    let hasThinking: Bool?
    let interrupted: Bool?

    /// Extracts ONLY the text content, ignoring tool_use blocks
    /// Tool calls are rendered via separate tool.call events
    var textContent: String? {
        guard let blocks = contentBlocks else { return nil }
        let texts = blocks.compactMap { block -> String? in
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
        guard let blocks = contentBlocks else { return nil }
        let thoughts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == ContentBlockType.thinking.rawValue else { return nil }
            return block["thinking"] as? String
        }
        return thoughts.isEmpty ? nil : thoughts.joined(separator: "\n")
    }

    init(from payload: [String: AnyCodable]) {
        if let blocks = payload["content"]?.value as? [[String: Any]] {
            self.contentBlocks = blocks
        } else {
            self.contentBlocks = nil
        }

        self.turn = payload.int("turn") ?? 1

        self.tokenRecord = TokenRecord.from(dict: payload.dict("tokenRecord"))

        if let stopStr = payload.string("stopReason") {
            self.stopReason = StopReason(rawValue: stopStr)
        } else {
            self.stopReason = nil
        }

        self.latencyMs = payload.int("latency") ?? payload.int("latencyMs")
        self.model = payload.string("model")
        self.hasThinking = payload.bool("hasThinking")
        self.interrupted = payload.bool("interrupted")
    }
}

/// Payload for message.system event
/// Server: SystemMessageEvent.payload
struct SystemMessagePayload {
    let content: String
    let source: SystemMessageSource?

    init?(from payload: [String: AnyCodable]) {
        guard let content = payload.string("content") else {
            return nil
        }
        self.content = content

        if let sourceStr = payload.string("source") {
            self.source = SystemMessageSource(rawValue: sourceStr)
        } else {
            self.source = nil
        }
    }
}
