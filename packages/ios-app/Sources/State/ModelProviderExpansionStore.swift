import Foundation
import Observation

/// Per-device memory of which model-picker provider sections the user collapsed.
/// The paired Gateway profile and the provider ID key every entry, so each
/// pairing keeps its own choices. This is a presentation preference only; the
/// Gateway catalog stays canonical.
@MainActor
@Observable
final class ModelProviderExpansionStore {
    private struct Document: Codable {
        let version: Int
        let collapsed: [String]
    }

    static let documentKey = "modelPicker.providerExpansion.v1"
    /// The app shares one device-local preference. Tests construct a store over
    /// their own defaults suite instead.
    static let shared = ModelProviderExpansionStore()

    private static let version = 1
    private static let maximumEntryCount = 512
    private static let maximumKeyBytes = 320
    private static let maximumDocumentBytes = 64 * 1024

    private let defaults: UserDefaults
    private var collapsedKeys: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsedKeys = Self.load(from: defaults)
    }

    /// A section with no remembered choice starts expanded only when it holds
    /// the current selection.
    func isExpanded(profileID: String?, provider: String, selectedProvider: String?) -> Bool {
        if collapsedKeys.contains(Self.key(profileID: profileID, provider: provider)) { return false }
        return selectedProvider == provider
    }

    func setExpanded(_ expanded: Bool, profileID: String?, provider: String) {
        let key = Self.key(profileID: profileID, provider: provider)
        guard !key.isEmpty, key.utf8.count <= Self.maximumKeyBytes else { return }
        if expanded {
            guard collapsedKeys.remove(key) != nil else { return }
        } else {
            guard collapsedKeys.contains(key) || collapsedKeys.count < Self.maximumEntryCount,
                  collapsedKeys.insert(key).inserted else { return }
        }
        let document = Document(version: Self.version, collapsed: collapsedKeys.sorted())
        guard let data = try? JSONEncoder().encode(document),
              data.count <= Self.maximumDocumentBytes else { return }
        defaults.set(data, forKey: Self.documentKey)
    }

    static func key(profileID: String?, provider: String) -> String {
        "\(profileID ?? "unpaired")|\(provider)"
    }

    private static func load(from defaults: UserDefaults) -> Set<String> {
        guard let data = defaults.data(forKey: documentKey),
              data.count <= maximumDocumentBytes,
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == version,
              document.collapsed.count <= maximumEntryCount,
              document.collapsed.allSatisfy({ !$0.isEmpty && $0.utf8.count <= maximumKeyBytes }) else {
            return []
        }
        return Set(document.collapsed)
    }
}
