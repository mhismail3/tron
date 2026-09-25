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
        #expect(ProviderUsagePresentation.summary(snapshot) == "0% used (5h) · 124% used (Weekly)")
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
            ProviderSummary(id: id, name: name, configured: configured, usageSupported: nil, localOnly: nil, authSource: nil,
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

    @Test("summary-only usage omits the detail stack while genuine detail remains visible")
    func summaryOnlyContent() {
        #expect(!ProviderUsagePresentation.hasDetailContent(
            ProviderUsageSnapshot(providerId: "empty", status: .available)
        ))
        #expect(!ProviderUsagePresentation.hasDetailContent(
            ProviderUsageSnapshot(providerId: "unsupported", status: .unsupported,
                windows: [UsageWindow(id: "ignored", label: "Ignored", usedPercent: 0)])
        ))
        #expect(ProviderUsagePresentation.hasDetailContent(
            ProviderUsageSnapshot(providerId: "available", status: .available,
                windows: [UsageWindow(id: "quota", label: "Quota", usedPercent: 0)])
        ))
        // The updated line lives in the summary header, not the detail stack.
        #expect(!ProviderUsagePresentation.hasDetailContent(
            ProviderUsageSnapshot(providerId: "updated", status: .available,
                updatedAt: "2026-01-02T03:04:05.123Z")
        ))
        #expect(ProviderUsagePresentation.hasDetailContent(
            ProviderUsageSnapshot(providerId: "limited", status: .rateLimited,
                retryAt: "2026-01-02T04:04:05.123Z")
        ))
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

    @Test("only a supported configured row reserves its usage line while the read is pending")
    func usagePlaceholderDecision() {
        func shows(
            snapshot: ProviderUsageSnapshot? = nil,
            configured: Bool = true,
            usageSupported: Bool = true,
            capabilityAvailable: Bool = true,
            readResolved: Bool = false
        ) -> Bool {
            ProviderUsagePresentation.showsUsageLoadingLine(
                snapshot: snapshot, configured: configured, usageSupported: usageSupported,
                capabilityAvailable: capabilityAvailable, readResolved: readResolved
            )
        }

        #expect(shows())
        #expect(!shows(readResolved: true))
        #expect(!shows(configured: false))
        #expect(!shows(usageSupported: false))
        #expect(!shows(capabilityAvailable: false))
        #expect(!shows(snapshot: ProviderUsageSnapshot(providerId: "p", status: .available)))
    }

    @Test("balance-only snapshots present the primary balance in the same slot as windows")
    func balanceOnlySummary() {
        let balances = [
            UsageBalance(id: "available", label: "Available", amount: 49.59, currency: "USD"),
            UsageBalance(id: "voucher", label: "Voucher", amount: 12.5, currency: "USD")
        ]
        let snapshot = ProviderUsageSnapshot(providerId: "moonshotai", status: .available, balances: balances)
        #expect(ProviderUsagePresentation.summary(snapshot) == "$49.59 Available")
        #expect(ProviderUsagePresentation.hasDetailContent(snapshot))
        #expect(ProviderUsagePresentation.summary(ProviderUsageSnapshot(
            providerId: "moonshotai", status: .available,
            balances: [UsageBalance(id: "available", label: "Available", amount: -1.2, currency: "USD")]
        )) == "-$1.20 Available")
        #expect(ProviderUsagePresentation.summary(ProviderUsageSnapshot(
            providerId: "moonshotai-cn", status: .available,
            balances: [UsageBalance(id: "available", label: "Available", amount: 12.5, currency: "CNY")]
        )) == "CN¥12.50 Available")
        // Windows stay authoritative when a provider reports both, and stale or
        // rate-limited decoration keeps applying to a balance-only row.
        #expect(ProviderUsagePresentation.summary(ProviderUsageSnapshot(
            providerId: "moonshotai", status: .available,
            windows: [UsageWindow(id: "quota", label: "Quota", usedPercent: 12)], balances: balances
        )) == "12% used")
        // A lone window with a known cadence still names it (Codex's weekly quota).
        #expect(ProviderUsagePresentation.summary(ProviderUsageSnapshot(
            providerId: "openai-codex", status: .available,
            windows: [UsageWindow(id: "primary", label: "Primary", usedPercent: 26, windowSeconds: 604_800)]
        )) == "26% used (Weekly)")
        #expect(ProviderUsagePresentation.summary(ProviderUsageSnapshot(
            providerId: "moonshotai", status: .rateLimited, stale: true, balances: balances
        )) == "Usage temporarily rate limited · $49.59 Available · Stale")
    }

    @Test("balance currency copy follows the reported ISO code and falls back on anything else")
    func currencyFormatting() {
        #expect(ProviderUsagePresentation.currency(49.59, code: "USD") == "$49.59")
        #expect(ProviderUsagePresentation.currency(-1.2, code: "USD") == "-$1.20")
        #expect(ProviderUsagePresentation.currency(12.5, code: "CNY") == "CN¥12.50")
        #expect(ProviderUsagePresentation.currency(12.5, code: "usd") == "$12.50")
        #expect(ProviderUsagePresentation.currency(3.456, code: "USD") == "$3.46")
        for code in ["DOLLARS", "US", "", "US1"] {
            #expect(ProviderUsagePresentation.currency(12.5, code: code) == "12.5 \(code)")
        }
    }

    @Test("secondary balances present their share of the primary balance")
    func balanceShares() {
        let primary = UsageBalance(id: "available", label: "Available", amount: 20, currency: "USD")
        func share(_ amount: Double, currency: String = "USD") -> Double? {
            ProviderUsagePresentation.balanceShare(
                UsageBalance(id: "secondary", label: "Voucher", amount: amount, currency: currency),
                of: primary
            )
        }
        #expect(share(10) == 50)
        #expect(share(0) == 0)
        // An inconsistent snapshot clamps instead of overflowing the bar.
        #expect(share(40) == 100)
        #expect(share(10, currency: "usd") == 50)
        #expect(share(10, currency: "CNY") == nil)
        #expect(share(-1) == nil)
        // A zero or negative primary supports no share, so a deficit stays a
        // deficit rather than an inverted percentage.
        for primaryAmount in [0.0, -5.0] {
            #expect(ProviderUsagePresentation.balanceShare(
                UsageBalance(id: "voucher", label: "Voucher", amount: 10, currency: "USD"),
                of: UsageBalance(id: "available", label: "Available", amount: primaryAmount, currency: "USD")
            ) == nil)
        }
        #expect(ProviderUsagePresentation.balanceShareCaption(50, of: primary) == "50% of available")
        #expect(ProviderUsagePresentation.balanceDeficitCopy == "Deficit")
    }

    @Test("only a configured local-only row without a snapshot or pending read shows unlimited")
    func localUnlimitedDecision() {
        func shows(
            configured: Bool = true,
            localOnly: Bool = true,
            snapshot: ProviderUsageSnapshot? = nil,
            isLoading: Bool = false
        ) -> Bool {
            ProviderUsagePresentation.showsLocalUnlimited(
                configured: configured, localOnly: localOnly, snapshot: snapshot, isLoading: isLoading
            )
        }
        #expect(shows())
        #expect(!shows(configured: false))
        #expect(!shows(localOnly: false))
        #expect(!shows(isLoading: true))
        #expect(!shows(snapshot: ProviderUsageSnapshot(providerId: "ollama", status: .unavailable)))
    }
}
