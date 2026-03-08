import Foundation

// MARK: - Shared Content

/// Content shared from other apps via the Share Extension.
/// Serialized to the App Group container for cross-process transfer.
struct SharedContent: Codable {
    let text: String?
    let url: String?
    let timestamp: Date
}

/// Payload passed from ContentView to ChatView via notification.
struct ShareMessagePayload {
    let prompt: String
    let skillName: String?
}

extension SharedContent {
    static let urlShareSkillName = "obsidian"

    /// Build the prompt text and determine whether to auto-attach a skill.
    ///
    /// URL shares: "Add this to your notes\n\n{url}" (+ optional text), attaches obsidian skill.
    /// Text-only shares: raw text, no skill attachment.
    func buildSharePrompt() -> ShareMessagePayload? {
        if let url, !url.isEmpty {
            var prompt = "Add this to your notes\n\n\(url)"
            if let text, !text.isEmpty {
                prompt += "\n\n\(text)"
            }
            return ShareMessagePayload(prompt: prompt, skillName: Self.urlShareSkillName)
        } else if let text, !text.isEmpty {
            return ShareMessagePayload(prompt: text, skillName: nil)
        }
        return nil
    }
}

// MARK: - Pending Share Service

/// Reads and writes pending shared content via the App Group UserDefaults.
/// Used by both the Share Extension (write) and main app (read/clear).
enum PendingShareService {
    static let suiteName = "group.com.tron.shared"
    private static let key = "pendingShare"

    static func save(_ content: SharedContent, store: UserDefaults? = nil) {
        guard let suite = store ?? UserDefaults(suiteName: suiteName) else { return }
        guard let data = try? JSONEncoder().encode(content) else { return }
        suite.set(data, forKey: key)
    }

    static func load(store: UserDefaults? = nil) -> SharedContent? {
        guard let suite = store ?? UserDefaults(suiteName: suiteName) else { return nil }
        guard let data = suite.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SharedContent.self, from: data)
    }

    static func clear(store: UserDefaults? = nil) {
        guard let suite = store ?? UserDefaults(suiteName: suiteName) else { return }
        suite.removeObject(forKey: key)
    }
}
