import Foundation

/// Stable, UI-independent presentation vocabulary for coordination messages.
/// Unknown server values remain readable instead of collapsing the audit row.
enum AgentMessagePresentation {
    enum Accent: Equatable {
        case operatorInstruction
        case ownerInstruction
        case peerMessage
        case engineEvidence
        case unknown
    }

    static func sender(_ content: AgentMessageContent) -> String {
        content.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? content.sourceAgentId
    }

    static func label(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func accent(authority: String) -> Accent {
        switch authority.lowercased() {
        case "operator": .operatorInstruction
        case "owner": .ownerInstruction
        case "peer": .peerMessage
        case "engine": .engineEvidence
        default: .unknown
        }
    }

    static func symbol(kind: String) -> String {
        switch kind.lowercased() {
        case "instruction": "arrow.right.circle.fill"
        case "request": "hand.raised.fill"
        case "question": "questionmark.bubble.fill"
        case "answer": "bubble.left.and.text.bubble.right.fill"
        case "update": "arrow.triangle.2.circlepath.circle.fill"
        case "result": "checkmark.seal.fill"
        case "information": "info.circle.fill"
        default: "bubble.left.fill"
        }
    }
}

