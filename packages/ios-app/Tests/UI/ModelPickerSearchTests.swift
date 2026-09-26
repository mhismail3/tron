import Foundation
import Testing
@testable import TronMobile

/// Shared model picker: the search filter and the Recent / Latest / provider
/// sectioning that orders them.
///
/// Failure modes this suite must catch, written before the sectioning existed:
/// 1. a recent `provider/id` that has left the available catalog (or an alias
///    that was renamed) renders an empty or wrong card;
/// 2. a recent entry for a model the Gateway marks unavailable renders anyway;
/// 3. duplicate recent entries draw the same card twice;
/// 4. an unbounded recent list or a Latest rail longer than the cap;
/// 5. models without a release date (or with a malformed one) sneak into Latest
///    and sort against well-formed dates;
/// 6. a latest alias and the pinned release its ID names share a date and both
///    appear in the Latest rail;
/// 7. ties on a release date order nondeterministically between renders;
/// 8. provider sections lose the selected model's provider, or stop being
///    alphabetical;
/// 9. an unavailable model creates a provider section of its own;
/// 10. a query leaves the Recent/Latest rails visible or hides a match behind a
///     provider section.
@Suite("Model picker search")
struct ModelPickerSearchTests {
    @Test("shared picker filters provider, id, and display name")
    func filtersModels() {
        let models = [
            model("alpha", "reasoning", "Alpha Reasoner"),
            model("beta", "fast", "Beta Fast"),
            model("anthropic", "claude-opus-4-5", "Claude Opus 4.5 (latest)"),
            model("anthropic", "claude-opus-4-5-20251101", "Claude Opus 4.5"),
        ]
        #expect(ModelPickerSearchPolicy.filtered(models, query: "beta").map(\.id) == ["fast"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "reasoning").map(\.id) == ["reasoning"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "20251101").map(\.id) == ["claude-opus-4-5-20251101"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "latest alias").map(\.id) == ["claude-opus-4-5"])
        #expect(ModelPickerSearchPolicy.filtered(models, query: "").count == 4)
    }

    @Test("pinned release identity reads the date suffix once")
    func pinnedReleaseIdentity() {
        #expect(ModelReleaseDate.pinnedReleaseDate(inID: "claude-opus-4-5-20251101") == "2025-11-01")
        #expect(ModelReleaseDate.pinnedReleaseDate(inID: "claude-opus-4-5") == nil)
        #expect(ModelReleaseDate.admits("2025-11-01"))
        #expect(!ModelReleaseDate.admits("2025-11"))
        #expect(!ModelReleaseDate.admits("November 2025"))
        #expect(ModelReleaseDate.admits("20251101") == false)
    }

    @Test("recent rail keeps gateway order and drops stale, unavailable, and repeated refs")
    func recentRailAdmission() {
        let catalog = [
            model("anthropic", "claude-opus-5", "Claude Opus 5"),
            model("anthropic", "claude-sonnet-5", "Claude Sonnet 5"),
            model("openai", "gpt-5", "GPT-5", available: false),
        ]
        let recent = [
            recent("anthropic", "claude-sonnet-5", at: "2026-01-03T00:00:00Z"),
            recent("openai", "gpt-5", at: "2026-01-02T00:00:00Z"),
            recent("anthropic", "removed-model", at: "2026-01-01T00:00:00Z"),
            recent("anthropic", "claude-sonnet-5", at: "2025-12-31T00:00:00Z"),
            recent("anthropic", "claude-opus-5", at: "2025-12-30T00:00:00Z"),
        ]
        let sections = ModelPickerSectioning.sections(
            models: catalog, recent: recent, selection: nil, query: ""
        )
        #expect(sections.recent.map(\.id) == ["claude-sonnet-5", "claude-opus-5"])
    }

    @Test("recent rail stays bounded to the gateway cap")
    func recentRailBound() {
        let catalog = (0..<20).map { model("alpha", "m\($0)", "Model \($0)") }
        let history = (0..<20).map { recent("alpha", "m\($0)", at: "2026-01-01T00:00:00Z") }
        let sections = ModelPickerSectioning.sections(models: catalog, recent: history, selection: nil, query: "")
        #expect(sections.recent.count == ModelPickerSectioning.maximumRecentModels)
        #expect(sections.recent.map(\.id) == (0..<12).map { "m\($0)" })
    }

    @Test("latest rail orders by release date and ignores undated and malformed dates")
    func latestRailOrdering() {
        let catalog = [
            model("alpha", "unknown", "Alpha Unknown"),
            model("alpha", "malformed", "Alpha Malformed", releaseDate: "2025-11"),
            model("alpha", "older", "Alpha Older", releaseDate: "2025-06-01"),
            model("beta", "newer-b", "Beta Newer", releaseDate: "2026-02-01"),
            model("beta", "newer-a", "Beta Newer A", releaseDate: "2026-02-01"),
            model("gamma", "newest", "Gamma Newest", releaseDate: "2026-03-01"),
        ]
        let sections = ModelPickerSectioning.sections(models: catalog, recent: [], selection: nil, query: "")
        // Ties break on display name: "Beta Newer" precedes "Beta Newer A".
        #expect(sections.latest.map(\.id) == ["newest", "newer-b", "newer-a", "older"])
    }

    @Test("latest rail stays bounded by the cap")
    func latestRailBound() {
        let catalog = (0..<14).map {
            model("alpha", "m\($0)", "Model \($0)", releaseDate: String(format: "2026-01-%02d", $0 + 1))
        }
        let sections = ModelPickerSectioning.sections(models: catalog, recent: [], selection: nil, query: "")
        #expect(sections.latest.count == ModelPickerSectioning.maximumLatestModels)
        #expect(sections.latest.map(\.id) == ["m13", "m12", "m11", "m10", "m9", "m8", "m7", "m6", "m5", "m4"])
    }

    @Test("latest rail keeps the alias when its pinned release shares the date")
    func latestRailCollapsesAliasPair() {
        let catalog = [
            model("anthropic", "claude-opus-4-5-20251101", "Claude Opus 4.5", releaseDate: "2025-11-01"),
            model("anthropic", "claude-opus-4-5", "Claude Opus 4.5 (latest)", releaseDate: "2025-11-01"),
            // Same date, unrelated IDs: both stay.
            model("beta", "sibling-a", "Beta Sibling A", releaseDate: "2025-11-01"),
            model("beta", "sibling-b", "Beta Sibling B", releaseDate: "2025-11-01"),
            // The alias is not in the catalog, so the pinned release stays.
            model("gamma", "orphan-20251001", "Gamma Orphan", releaseDate: "2025-10-01"),
            // Another provider publishes only the ID delta pairs: a pinned
            // release never collapses against a different provider's alias.
            model("delta", "mirror", "Delta Mirror (latest)", releaseDate: "2025-11-01"),
            model("delta", "mirror-20251101", "Delta Mirror", releaseDate: "2025-11-01"),
            model("epsilon", "mirror-20251101", "Epsilon Mirror", releaseDate: "2025-11-01"),
        ]
        let sections = ModelPickerSectioning.sections(models: catalog, recent: [], selection: nil, query: "")
        #expect(sections.latest.map(\.id).sorted() == [
            "claude-opus-4-5", "mirror", "mirror-20251101", "orphan-20251001", "sibling-a", "sibling-b",
        ])
        #expect(sections.latest.filter { $0.id == "mirror-20251101" }.map(\.provider) == ["epsilon"],
                "only delta's own alias collapses delta's pinned release")
        let anthropic = sections.providers.first { $0.provider == "anthropic" }
        #expect(anthropic?.models.map(\.id) == ["claude-opus-4-5-20251101", "claude-opus-4-5"])
    }

    @Test("provider sections lead with the selected provider, then sort by display name")
    func providerSectionOrder() {
        let catalog = [
            model("openai", "gpt-5", "GPT-5"),
            model("anthropic", "claude-opus-5", "Claude Opus 5"),
            model("xai", "grok-5", "Grok 5"),
            model("deepseek", "deepseek-v4", "DeepSeek V4"),
        ]
        let sections = ModelPickerSectioning.sections(
            models: catalog,
            recent: [],
            selection: ModelRef(provider: "xai", id: "grok-5"),
            query: ""
        )
        #expect(sections.providers.map(\.provider) == ["xai", "anthropic", "deepseek", "openai"])
        #expect(sections.providers.map(\.displayName) == ["xAI", "Anthropic", "DeepSeek", "OpenAI"])
        #expect(sections.providers.first?.models.count == 1)

        let unselected = ModelPickerSectioning.sections(models: catalog, recent: [], selection: nil, query: "")
        #expect(unselected.providers.map(\.provider) == ["anthropic", "deepseek", "openai", "xai"])
    }

    @Test("an unavailable model never creates a provider section")
    func unavailableModelsAreOmitted() {
        let catalog = [
            model("alpha", "available", "Alpha Available"),
            model("beta", "unavailable", "Beta Unavailable", available: false),
        ]
        let sections = ModelPickerSectioning.sections(models: catalog, recent: [], selection: nil, query: "")
        #expect(sections.providers.map(\.provider) == ["alpha"])
        #expect(sections.latest.isEmpty)
    }

    @Test("a query replaces the rails and keeps every match in a provider section")
    func searchReplacesRails() {
        let catalog = [
            model("anthropic", "claude-opus-5", "Claude Opus 5", releaseDate: "2026-01-01"),
            model("openai", "gpt-5", "GPT-5", releaseDate: "2026-02-01"),
        ]
        let recent = [recent("openai", "gpt-5", at: "2026-03-01T00:00:00Z")]
        let sections = ModelPickerSectioning.sections(
            models: catalog, recent: recent, selection: nil, query: "gpt"
        )
        #expect(sections.recent.isEmpty)
        #expect(sections.latest.isEmpty)
        #expect(sections.providers.map(\.provider) == ["openai"])
        #expect(sections.providers.first?.models.map(\.id) == ["gpt-5"])

        let empty = ModelPickerSectioning.sections(
            models: catalog, recent: recent, selection: nil, query: "nothing-matches"
        )
        #expect(empty.recent.isEmpty)
        #expect(empty.latest.isEmpty)
        #expect(empty.providers.isEmpty)
    }

    @Test("provider grouping looks up the provider through its display name")
    func providerGroupingUsesDisplayNames() {
        let catalog = [
            model("openai-codex", "gpt-5-codex", "GPT-5 Codex"),
            model("vertex-ai", "gemini-3", "Gemini 3"),
        ]
        let sections = ModelPickerSectioning.sections(models: catalog, recent: [], selection: nil, query: "")
        #expect(sections.providers.map(\.displayName) == ["OpenAI Codex", "Vertex AI"])
    }

    private func model(
        _ provider: String,
        _ id: String,
        _ name: String,
        available: Bool = true,
        releaseDate: String? = nil
    ) -> ModelSummary {
        ModelSummary(
            provider: provider,
            id: id,
            name: name,
            reasoning: true,
            input: ["text"],
            contextWindow: 200_000,
            maxTokens: 32_000,
            available: available,
            releaseDate: releaseDate
        )
    }

    private func recent(_ provider: String, _ id: String, at lastUsedAt: String) -> RecentModelRef {
        RecentModelRef(provider: provider, id: id, lastUsedAt: lastUsedAt)
    }
}
