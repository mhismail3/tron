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
            ProviderSummary(id: id, name: name, configured: configured, usageSupported: nil, authSource: nil,
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
        #expect(ProviderUsagePresentation.hasDetailContent(
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

    @Test("the usage skeleton breathes within a bounded opacity range")
    func loadingLineOpacityIsBounded() {
        let engine = ProviderUsageLoadingLineEngine.self
        #expect(abs(engine.opacity(progress: 0.25) - engine.maximumOpacity) < 1e-9)
        #expect(abs(engine.opacity(progress: 0.75) - engine.minimumOpacity) < 1e-9)
        for step in 0...40 {
            let value = engine.opacity(progress: Double(step) / 40)
            #expect(value >= engine.minimumOpacity)
            #expect(value <= engine.maximumOpacity)
        }
        // Out-of-range progress clamps instead of extrapolating the wave.
        for progress in [-1.0, 2.0] {
            let value = engine.opacity(progress: progress)
            #expect(value >= engine.minimumOpacity)
            #expect(value <= engine.maximumOpacity)
        }
    }

    @Test("the catalog usage flag decodes and a Gateway without it stays unsupported")
    func decodesUsageSupportFlag() throws {
        func provider(_ json: String) throws -> ProviderSummary {
            try JSONDecoder.gateway.decode(ProviderSummary.self, from: Data(json.utf8))
        }
        let supported = try provider(#"{"id":"opencode-go","name":"OpenCode Go","configured":true,"usageSupported":true,"authSource":"api-key","credentialType":"api-key","authMethods":["api_key"],"modelCount":3}"#)
        #expect(supported.supportsUsage)
        let legacy = try provider(#"{"id":"openrouter","name":"OpenRouter","configured":true,"authSource":"api-key","credentialType":"api-key","authMethods":["api_key"],"modelCount":3}"#)
        #expect(!legacy.supportsUsage)
        let explicitFalse = try provider(#"{"id":"ollama","name":"Ollama","configured":true,"usageSupported":false,"authSource":null,"credentialType":null,"authMethods":[],"modelCount":0}"#)
        #expect(!explicitFalse.supportsUsage)
    }
}
