import Testing
@testable import TronMobile

@Suite("Provider display formatting")
struct ProviderDisplayFormattingTests {
    @Test("formats Anthropic model identifiers without losing decimal versions")
    func anthropicModelVersions() {
        #expect(ModelDisplayFormatting.model("claude-opus-5-5") == "Claude Opus 5.5")
        #expect(ModelDisplayFormatting.model("claude-opus-5-5") == ModelDisplayFormatting.model("Claude Opus 5.5"))
        #expect(ModelDisplayFormatting.model("claude-fable-5-1") == "Claude Fable 5.1")
        #expect(ModelDisplayFormatting.model("claude-mythos-5-1") == "Claude Mythos 5.1")
        #expect(ModelDisplayFormatting.model("claude-opus-4-8") == "Claude Opus 4.8")
        #expect(ModelDisplayFormatting.model("claude-opus-4-5") == "Claude Opus 4.5 (latest)")
        #expect(ModelDisplayFormatting.model("claude-sonnet-4-5") == "Claude Sonnet 4.5 (latest)")
        #expect(ModelDisplayFormatting.model("claude-haiku-4-5") == "Claude Haiku 4.5 (latest)")
        #expect(ModelDisplayFormatting.model("claude-haiku-4-5-20251001") == "Claude Haiku 4.5")
        #expect(ModelDisplayFormatting.model("claude-opus-4-5-20251101") == "Claude Opus 4.5")
        #expect(ModelDisplayFormatting.model("claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
    }

    @Test("uses authoritative catalog names for model choices")
    func authoritativeAnthropicNames() {
        let models = [
            summary(id: "claude-haiku-4-5", name: "Claude Haiku 4.5 (latest)"),
            summary(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5"),
            summary(id: "claude-opus-4-5", name: "Claude Opus 4.5 (latest)"),
            summary(id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5"),
            summary(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5 (latest)"),
            summary(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5"),
            summary(id: "claude-mythos-5-1", name: "Claude Mythos 5.1"),
        ]

        #expect(models.map(\.displayName) == [
            "Claude Haiku 4.5 (latest)", "Claude Haiku 4.5",
            "Claude Opus 4.5 (latest)", "Claude Opus 4.5",
            "Claude Sonnet 4.5 (latest)", "Claude Sonnet 4.5",
            "Claude Mythos 5.1",
        ])
        #expect(models.map(\.id).first == "claude-haiku-4-5")
        #expect(models.map(\.pickerIdentity) == [
            "Latest alias · anthropic/claude-haiku-4-5",
            "Pinned release · 2025-10-01 · anthropic/claude-haiku-4-5-20251001",
            "Latest alias · anthropic/claude-opus-4-5",
            "Pinned release · 2025-11-01 · anthropic/claude-opus-4-5-20251101",
            "Latest alias · anthropic/claude-sonnet-4-5",
            "Pinned release · 2025-09-29 · anthropic/claude-sonnet-4-5-20250929",
            "Model ID · anthropic/claude-mythos-5-1",
        ])
        #expect(Set(models.map(\.pickerIdentity)).count == models.count)
        #expect(models.map(\.ref).count == models.count)
        // Negative control: when a catalog name is available it wins over the ID-only fallback.
        #expect(summary(id: "claude-haiku-4-5", name: "Claude Haiku 4.5").displayName == "Claude Haiku 4.5")
        #expect(ModelDisplayFormatting.model("unknown-model") == "Unknown Model")
    }

    private func summary(id: String, name: String) -> ModelSummary {
        ModelSummary(
            provider: "anthropic", id: id, name: name, reasoning: true, input: ["text"],
            contextWindow: 200_000, maxTokens: 16_000, available: false
        )
    }

    @Test("preserves CortexKit branding in provider names")
    func cortexKitBranding() {
        #expect(ModelDisplayFormatting.provider("Anthropic (CortexKit)") == "Anthropic (CortexKit)")
    }
}
