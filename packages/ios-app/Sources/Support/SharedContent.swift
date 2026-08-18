import Foundation

struct SharedContent: Codable, Equatable {
    let text: String?
    let url: String?
    let timestamp: Date
}

struct ShareMessagePayload: Equatable { let prompt: String }

enum SharedContentFragment: Equatable {
    case text(String)
    case url(String)
}

enum SharedContentReducer {
    static func content(
        from fragments: [SharedContentFragment],
        timestamp: Date
    ) -> SharedContent? {
        var text: String?
        var url: String?
        for fragment in fragments {
            switch fragment {
            case .text(let value):
                text = value
            case .url(let value):
                if url == nil { url = value }
                else { text = [text, value].compactMap { $0 }.joined(separator: "\n") }
            }
        }
        guard text != nil || url != nil else { return nil }
        return SharedContent(text: text, url: url, timestamp: timestamp)
    }
}

extension SharedContent {
    func buildSharePrompt() -> ShareMessagePayload? {
        let values = [url, text].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        return values.isEmpty ? nil : ShareMessagePayload(prompt: values.joined(separator: "\n\n"))
    }
}

protocol PendingShareStoring {
    func save(_ content: SharedContent)
    func load() -> SharedContent?
    func clear()
}

struct UserDefaultsPendingShareStore: PendingShareStoring {
    static let suiteName = "group.com.tron.shared"
    private static let key = "pendingShare"

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        self.defaults = defaults
    }

    func save(_ content: SharedContent) {
        guard let defaults, let data = try? JSONEncoder().encode(content) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func load() -> SharedContent? {
        guard let data = defaults?.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(SharedContent.self, from: data)
    }

    func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}
