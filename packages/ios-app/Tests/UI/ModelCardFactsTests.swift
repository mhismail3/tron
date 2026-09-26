import Testing
@testable import TronMobile

/// Facts shown on the model picker's rail cards.
///
/// Failure modes this suite must catch, written before the code:
/// 1. Prices lose sub-dollar precision, print needless decimals, or an absent
///    price renders as "$0" and advertises the model as free.
/// 2. Context windows round up past the real limit (1,048,576 as "1.1M"),
///    or a missing window renders as "0".
/// 3. A release date shows the wrong month (off-by-one indexing), follows the
///    device locale inconsistently, or renders a malformed date instead of
///    omitting it.
/// 4. A row summary shows separators around missing facts, or a line for a
///    model with no facts at all.
@Suite("Model card facts")
struct ModelCardFactsTests {
    @Test("prices keep sub-dollar precision and an absent price stays absent")
    func priceLabels() {
        #expect(ModelCardFacts.priceLabel(ModelTokenPrice(input: 10, output: 50)) == "$10 / $50")
        #expect(ModelCardFacts.priceLabel(ModelTokenPrice(input: 0.15, output: 0.47)) == "$0.15 / $0.47")
        #expect(ModelCardFacts.priceLabel(ModelTokenPrice(input: 1.75, output: 14)) == "$1.75 / $14")
        #expect(ModelCardFacts.priceLabel(ModelTokenPrice(input: 0.3, output: 1.2)) == "$0.30 / $1.20")
        #expect(ModelCardFacts.priceLabel(ModelTokenPrice(input: 0.004, output: 0)) == "<$0.01 / $0")
        #expect(ModelCardFacts.priceLabel(nil) == nil)
    }

    @Test("context windows never round past the real limit")
    func contextLabels() {
        #expect(ModelCardFacts.contextLabel(1_000_000) == "1M")
        #expect(ModelCardFacts.contextLabel(1_048_576) == "1M")
        #expect(ModelCardFacts.contextLabel(1_500_000) == "1.5M")
        #expect(ModelCardFacts.contextLabel(200_000) == "200K")
        #expect(ModelCardFacts.contextLabel(131_072) == "131K")
        #expect(ModelCardFacts.contextLabel(8_192) == "8K")
        #expect(ModelCardFacts.contextLabel(512) == "512")
        #expect(ModelCardFacts.contextLabel(0) == nil)
    }

    @Test("release dates show the short month and year, and malformed dates are omitted")
    func releaseLabels() {
        #expect(ModelCardFacts.releaseLabel("2026-09-22") == "Sep 2026")
        #expect(ModelCardFacts.releaseLabel("2025-01-01") == "Jan 2025")
        #expect(ModelCardFacts.releaseLabel("2025-12-31") == "Dec 2025")
        #expect(ModelCardFacts.releaseLabel("2025-13-01") == nil)
        #expect(ModelCardFacts.releaseLabel("2025-00-10") == nil)
        #expect(ModelCardFacts.releaseLabel("Sep 2026") == nil)
        #expect(ModelCardFacts.releaseLabel(nil) == nil)
    }

    @Test("a row summary joins only the facts that exist")
    func rowSummary() {
        let full = model(context: 1_000_000, cost: ModelTokenPrice(input: 5, output: 25), releaseDate: "2026-09-22")
        #expect(ModelCardFacts.rowSummary(full) == "1M context · $5 / $25 · Sep 2026")
        let noPrice = model(context: 200_000, cost: nil, releaseDate: "2025-11-01")
        #expect(ModelCardFacts.rowSummary(noPrice) == "200K context · Nov 2025")
        let bare = model(context: 0, cost: nil, releaseDate: nil)
        #expect(ModelCardFacts.rowSummary(bare) == nil)
    }

    private func model(context: Int, cost: ModelTokenPrice?, releaseDate: String?) -> ModelSummary {
        ModelSummary(provider: "p", id: "m", name: "M", reasoning: false, input: ["text"],
                     contextWindow: context, maxTokens: 1_000, available: true,
                     releaseDate: releaseDate, cost: cost)
    }
}
