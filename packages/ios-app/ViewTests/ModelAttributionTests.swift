import XCTest
@testable import TronMobileCore
@testable import TronMobile

final class ModelAttributionTests: XCTestCase {
    func testFooterNamesTheProviderAsItsCatalogDoes() {
        let antigravity = ProviderSummary(id: "antigravity-acp", name: "Google Antigravity", configured: true, usageSupported: nil,
                                          localOnly: nil, authSource: nil, credentialType: nil, authMethods: [], modelCount: 1)
        XCTAssertEqual(ChatModelAttribution.text(provider: "antigravity-acp", model: "gemini-4-neon", thinkingLevel: "high",
                                                 providers: ["antigravity-acp": antigravity]),
                       "Google Antigravity / Gemini 4 Neon · \(ThinkingLevelPresentation.title("high"))")
        XCTAssertEqual(ChatModelAttribution.text(provider: "openai", model: "gpt-6-luna", thinkingLevel: nil, providers: [:]),
                       "OpenAI / GPT 6 Luna")
    }
}
