import Foundation
import Testing
@testable import TronMobile

@Suite("Provider account usage")
struct ProviderUsagePresentationTests {
    @Test("decoding preserves genuine zero, overflow percentages, reset and balance data")
    func decodesContractWithoutInventingValues() throws {
        let data = Data(#"""
        {
          "providers": [{
            "providerId": "openai-codex", "status": "available", "source": "account",
            "scope": "account", "updatedAt": "2026-01-02T03:04:05.000Z", "retryAt": null,
            "stale": false, "message": null,
            "windows": [
              {"id":"five-hour","label":"5h","usedPercent":0,"used":0,"limit":100,"remaining":100,"unit":"requests","resetsAt":"2026-01-02T05:00:00.000Z","windowSeconds":18000},
              {"id":"weekly","label":"Weekly","usedPercent":124,"used":124,"limit":100,"remaining":0,"unit":"requests","resetsAt":null,"windowSeconds":604800}
            ],
            "balances": [{"id":"credit","label":"Credit","amount":12.5,"currency":"USD"}]
          }]
        }
        """#.utf8)
        let response = try JSONDecoder().decode(ProviderUsageResponse.self, from: data)
        let snapshot = try #require(response.providers.first)
        #expect(snapshot.windows[0].usedPercent == 0)
        #expect(snapshot.windows[1].usedPercent == 124)
        #expect(snapshot.balances.first?.amount == 12.5)
        #expect(ProviderUsagePresentation.summary(snapshot) == "5h 0% used · Weekly 124% used")
    }

    @Test("malformed and duplicate bounded usage data is rejected")
    func rejectsMalformedUsage() {
        let duplicate = Data(#"{"providers":[{"providerId":"p","status":"available","source":null,"scope":null,"updatedAt":null,"retryAt":null,"stale":false,"message":null,"windows":[{"id":"same","label":"A"},{"id":"same","label":"B"}],"balances":[]}]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderUsageResponse.self, from: duplicate)
        }
        let invalidReset = Data(#"{"providers":[{"providerId":"p","status":"available","source":null,"scope":null,"updatedAt":null,"retryAt":null,"stale":false,"message":null,"windows":[{"id":"w","label":"A","resetsAt":"not-a-date"}],"balances":[]}] }"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProviderUsageResponse.self, from: invalidReset)
        }
    }

    @Test("ordering is configured first then stable friendly name and ID")
    func configuredFirstOrdering() {
        let provider: (String, String, Bool) -> ProviderSummary = { id, name, configured in
            ProviderSummary(id: id, name: name, configured: configured, authSource: nil,
                            credentialType: nil, authMethods: [], modelCount: 0)
        }
        let result = ProviderUsageOrdering.sorted([
            provider("z", "Beta", false), provider("a", "Alpha", false),
            provider("b", "Alpha", true), provider("a2", "Alpha", true)
        ])
        #expect(result.map(\.id) == ["a2", "b", "a", "z"])
    }

    @Test("unsupported status never presents fabricated measurements")
    func unsupportedStatusCopy() {
        let snapshot = ProviderUsageSnapshot(
            providerId: "future", status: .unsupported,
            windows: [UsageWindow(id: "quota", label: "Quota", usedPercent: 0)]
        )
        #expect(ProviderUsagePresentation.summary(snapshot) == "Account usage is not supported by this provider")
    }

    @Test("rate limits retain current status and present retry timestamp")
    func rateLimitFormatting() {
        let snapshot = ProviderUsageSnapshot(
            providerId: "openrouter", status: .rateLimited,
            updatedAt: "2026-01-02T03:04:05.123Z", retryAt: "2026-01-02T04:04:05.123Z", stale: true,
            windows: [UsageWindow(id: "key", label: "Key", usedPercent: 70)]
        )
        #expect(ProviderUsagePresentation.summary(snapshot).contains("Usage temporarily rate limited"))
        #expect(ProviderUsagePresentation.summary(snapshot).contains("Stale"))
        #expect(ProviderUsagePresentation.retryCopy(snapshot)?.hasPrefix("Retry after ") == true)
        #expect(ProviderUsagePresentation.retryCopy(ProviderUsageSnapshot(providerId: "openrouter", status: .rateLimited, retryAt: "not-a-date")) == nil)
    }

    @Test("detail preserves reported quota amounts alongside percentages")
    func quantityDetailFormatting() {
        #expect(ProviderUsagePresentation.quantityDetail(
            UsageWindow(id: "key", label: "Key", usedPercent: 70, used: 7, limit: 10, remaining: 3, unit: "USD")
        ) == "7 USD used · Limit 10 USD · 3 USD remaining")
        #expect(ProviderUsagePresentation.quantityDetail(
            UsageWindow(id: "weekly", label: "Weekly", usedPercent: 24)
        ) == nil)
        #expect(ProviderUsagePresentation.quantityDetail(
            UsageWindow(id: "quota", label: "Quota", used: 7, limit: 10, remaining: 3)
        ) == "3 remaining")
    }

    @Test("amount-only spend and remaining values never become percentages")
    func amountFormatting() {
        #expect(ProviderUsagePresentation.windowSummary(
            UsageWindow(id: "spend", label: "Spend", used: 12.5, unit: "USD")
        ) == "12.5 USD used")
        #expect(ProviderUsagePresentation.windowSummary(
            UsageWindow(id: "remaining", label: "Remaining", remaining: 0, unit: "requests")
        ) == "0 requests remaining")
        #expect(ProviderUsagePresentation.windowSummary(
            UsageWindow(id: "quota", label: "Quota", used: 24, limit: 100, unit: "requests")
        ) == "24/100 requests used")
    }
}
