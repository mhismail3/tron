import Foundation
import Testing
@testable import TronMobile

/// Per-device model-provider expansion memory.
///
/// Failure modes this suite must catch, written first:
/// 1. an unremembered picker collapses everything, or expands everything, so the
///    selected model's provider cannot be found;
/// 2. a collapse does not survive the next picker presentation;
/// 3. expanding never clears a remembered collapse;
/// 4. one paired Gateway's collapse leaks into another pairing's picker;
/// 5. a corrupt, wrong-version, or oversized stored document crashes or bleeds
///    state into the picker instead of falling back to defaults.
@MainActor
@Suite("Model provider expansion memory")
struct ModelProviderExpansionStoreTests {
    @Test("an unremembered provider is expanded only when it holds the selection")
    func defaultExpansionFollowsSelection() throws {
        let store = try makeStore()
        #expect(store.isExpanded(profileID: "profile-a", provider: "anthropic", selectedProvider: "anthropic"))
        #expect(!store.isExpanded(profileID: "profile-a", provider: "openai", selectedProvider: "anthropic"))
        #expect(!store.isExpanded(profileID: "profile-a", provider: "openai", selectedProvider: nil))
    }

    @Test("a collapse and its reversal survive the next picker presentation")
    func collapsePersistsAcrossStores() throws {
        let defaults = try makeDefaults()
        let first = ModelProviderExpansionStore(defaults: defaults)
        first.setExpanded(false, profileID: "profile-a", provider: "anthropic")
        #expect(!first.isExpanded(profileID: "profile-a", provider: "anthropic", selectedProvider: "anthropic"))

        let second = ModelProviderExpansionStore(defaults: defaults)
        #expect(!second.isExpanded(profileID: "profile-a", provider: "anthropic", selectedProvider: "anthropic"))
        #expect(!second.isExpanded(profileID: "profile-a", provider: "openai", selectedProvider: nil))

        second.setExpanded(true, profileID: "profile-a", provider: "anthropic")
        let third = ModelProviderExpansionStore(defaults: defaults)
        #expect(third.isExpanded(profileID: "profile-a", provider: "anthropic", selectedProvider: "anthropic"),
                "clearing the collapse restores the selection default")
    }

    @Test("each paired profile remembers its own provider sections")
    func profilesStayIndependent() throws {
        let defaults = try makeDefaults()
        let store = ModelProviderExpansionStore(defaults: defaults)
        store.setExpanded(false, profileID: "profile-a", provider: "anthropic")
        #expect(!store.isExpanded(profileID: "profile-a", provider: "anthropic", selectedProvider: "anthropic"))
        #expect(store.isExpanded(profileID: "profile-b", provider: "anthropic", selectedProvider: "anthropic"))
        #expect(store.isExpanded(profileID: nil, provider: "anthropic", selectedProvider: "anthropic"))
    }

    @Test("a corrupt stored document falls back to defaults")
    func corruptDocumentIsIgnored() throws {
        for stored in [
            Data("not json".utf8),
            Data(#"{"version":99,"collapsed":["profile-a|anthropic"]}"#.utf8),
            Data(#"{"version":1,"collapsed":[""]}"#.utf8),
        ] {
            let defaults = try makeDefaults()
            defaults.set(stored, forKey: ModelProviderExpansionStore.documentKey)
            let store = ModelProviderExpansionStore(defaults: defaults)
            #expect(store.isExpanded(profileID: "profile-a", provider: "anthropic", selectedProvider: "anthropic"))
        }
    }

    @Test("an oversized collapse key is refused")
    func oversizedKeyIsRefused() throws {
        let defaults = try makeDefaults()
        let store = ModelProviderExpansionStore(defaults: defaults)
        let provider = String(repeating: "p", count: 400)
        store.setExpanded(false, profileID: "profile-a", provider: provider)
        #expect(store.isExpanded(profileID: "profile-a", provider: provider, selectedProvider: provider))
        #expect(defaults.data(forKey: ModelProviderExpansionStore.documentKey) == nil)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "model-provider-expansion.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: name))
    }

    private func makeStore() throws -> ModelProviderExpansionStore {
        ModelProviderExpansionStore(defaults: try makeDefaults())
    }
}
