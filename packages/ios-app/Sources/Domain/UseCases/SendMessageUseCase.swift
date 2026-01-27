import Foundation

// MARK: - Send Message Error

/// Errors that can occur when sending a message
enum SendMessageError: LocalizedError, Equatable {
    case emptyMessage
    case agentNotResponding
    case networkError(message: String)

    static func == (lhs: SendMessageError, rhs: SendMessageError) -> Bool {
        switch (lhs, rhs) {
        case (.emptyMessage, .emptyMessage): return true
        case (.agentNotResponding, .agentNotResponding): return true
        case (.networkError(let lm), .networkError(let rm)): return lm == rm
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .emptyMessage:
            return "Message cannot be empty"
        case .agentNotResponding:
            return "Agent is not responding"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - Send Message Use Case

/// Use case for sending a message to the agent.
/// Handles message validation and delegates to the agent client.
@MainActor
final class SendMessageUseCase: UseCase {
    private let agentClient: AgentClientProtocol

    init(agentClient: AgentClientProtocol) {
        self.agentClient = agentClient
    }

    // MARK: - Request/Response

    struct Request {
        let message: String
        var images: [ImageAttachment]? = nil
        var attachments: [FileAttachment]? = nil
        var reasoningLevel: String? = nil
        var skills: [Skill]? = nil
        var spells: [Skill]? = nil
    }

    typealias Response = Void

    // MARK: - Execute

    func execute(_ request: Request) async throws {
        // Validate message
        let trimmedMessage = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw SendMessageError.emptyMessage
        }

        // Send to agent
        do {
            try await agentClient.sendPrompt(
                trimmedMessage,
                images: request.images,
                attachments: request.attachments,
                reasoningLevel: request.reasoningLevel,
                skills: request.skills,
                spells: request.spells
            )
        } catch let error as SendMessageError {
            throw error
        } catch {
            throw SendMessageError.networkError(message: error.localizedDescription)
        }
    }
}
