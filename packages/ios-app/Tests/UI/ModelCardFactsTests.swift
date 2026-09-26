import Testing
@testable import TronMobile

/// Facts shown on the model picker's rail cards.
///
/// Failure modes this suite must catch, written before the code:
/// 1. Prices lose sub-dollar precision, print needless decimals, or an absent
///    price renders as "$0" and advertises the model as free.
/// 2. Context windows round up past the real limit (1,048,576 as "1.1M"),
///    or a missing window renders as "0".
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
}
