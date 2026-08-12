import Foundation

struct SharedContent: Codable {
    let text: String?
    let url: String?
    let timestamp: Date
}

struct ShareMessagePayload { let prompt: String }

extension SharedContent {
    func buildSharePrompt() -> ShareMessagePayload? {
        let values = [url, text].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        return values.isEmpty ? nil : ShareMessagePayload(prompt: values.joined(separator: "\n\n"))
    }
}

enum PendingShareService {
    static let suiteName = "group.com.tron.shared"
    private static let key = "pendingShare"

    static func save(_ content: SharedContent, store: UserDefaults? = nil) {
        guard let suite = store ?? UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(content) else { return }
        suite.set(data, forKey: key)
    }

    static func load(store: UserDefaults? = nil) -> SharedContent? {
        guard let suite = store ?? UserDefaults(suiteName: suiteName),
              let data = suite.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SharedContent.self, from: data)
    }

    static func clear(store: UserDefaults? = nil) {
        (store ?? UserDefaults(suiteName: suiteName))?.removeObject(forKey: key)
    }
}
