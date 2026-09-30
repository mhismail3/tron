import Foundation

package struct SharedContent: Codable, Equatable {
    let text: String?
    let url: String?
    let timestamp: Date
}

package struct ShareMessagePayload: Equatable { package let prompt: String }

package enum SharedContentFragment: Equatable {
    case text(String)
    case url(String)
}

package enum SharedContentAdmissionPolicy {
    package static let maximumProviderCount = 32
    static let maximumFragmentBytes = 64 * 1_024
    static let maximumAggregateBytes = 128 * 1_024
    static let maximumPromptBytes = 192 * 1_024
    static let maximumStoredDocumentBytes = 256 * 1_024

    package static func admits(_ fragment: SharedContentFragment) -> Bool {
        fragment.value.utf8.count <= maximumFragmentBytes
    }

    package static func admits(_ fragments: [SharedContentFragment]) -> Bool {
        guard fragments.count <= maximumProviderCount else { return false }
        var total = 0
        for fragment in fragments {
            let bytes = fragment.value.utf8.count
            guard bytes <= maximumFragmentBytes,
                  total <= maximumAggregateBytes - bytes else { return false }
            total += bytes
        }
        return true
    }

    static func admits(_ content: SharedContent) -> Bool {
        var total = 0
        for value in [content.url, content.text].compactMap({ $0 }) {
            let bytes = value.utf8.count
            guard bytes <= maximumAggregateBytes,
                  total <= maximumAggregateBytes - bytes else { return false }
            total += bytes
        }
        return true
    }

    package static func admitsPrompt(_ prompt: String) -> Bool {
        prompt.utf8.count <= maximumPromptBytes
    }
}

private extension SharedContentFragment {
    var value: String {
        switch self {
        case .text(let value), .url(let value): return value
        }
    }
}

package enum SharedContentReducer {
    package static func content(
        from fragments: [SharedContentFragment],
        timestamp: Date
    ) -> SharedContent? {
        guard SharedContentAdmissionPolicy.admits(fragments) else { return nil }
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
        let content = SharedContent(text: text, url: url, timestamp: timestamp)
        return SharedContentAdmissionPolicy.admits(content) ? content : nil
    }
}

extension SharedContent {
    package func buildSharePrompt() -> ShareMessagePayload? {
        guard SharedContentAdmissionPolicy.admits(self) else { return nil }
        let values = [url, text].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        let prompt = values.joined(separator: "\n\n")
        guard !prompt.isEmpty, SharedContentAdmissionPolicy.admitsPrompt(prompt) else { return nil }
        return ShareMessagePayload(prompt: prompt)
    }
}

package protocol PendingShareStoring {
    @discardableResult func save(_ content: SharedContent) -> Bool
    func load() -> SharedContent?
    func clear()
}

package struct UserDefaultsPendingShareStore: PendingShareStoring {
    static let suiteName = "group.com.tron.shared"
    private static let key = "pendingShare"

    private let defaults: UserDefaults?

    package init(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        self.defaults = defaults
    }

    @discardableResult
    package func save(_ content: SharedContent) -> Bool {
        guard SharedContentAdmissionPolicy.admits(content),
              let defaults,
              let data = try? JSONEncoder().encode(content),
              data.count <= SharedContentAdmissionPolicy.maximumStoredDocumentBytes else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }

    package func load() -> SharedContent? {
        guard let defaults, let data = defaults.data(forKey: Self.key) else { return nil }
        guard data.count <= SharedContentAdmissionPolicy.maximumStoredDocumentBytes,
              let content = try? JSONDecoder().decode(SharedContent.self, from: data),
              SharedContentAdmissionPolicy.admits(content) else {
            defaults.removeObject(forKey: Self.key)
            return nil
        }
        return content
    }

    package func clear() {
        defaults?.removeObject(forKey: Self.key)
    }
}
