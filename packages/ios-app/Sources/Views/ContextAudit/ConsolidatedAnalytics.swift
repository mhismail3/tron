import Foundation

// MARK: - Consolidated Analytics Data Model

struct ConsolidatedAnalytics {
    struct TurnData: Identifiable {
        let id = UUID()
        let turn: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let cacheCreation5mTokens: Int
        let cacheCreation1hTokens: Int
        let cost: Double
        let latency: Int
        let toolCount: Int
        let tools: [String]
        let errorCount: Int
        let errors: [String]
        let model: String?

        var totalTokens: Int { inputTokens + outputTokens }
        var hasPerTTLBreakdown: Bool { cacheCreation5mTokens > 0 || cacheCreation1hTokens > 0 }
    }

    let turns: [TurnData]
    let totalCost: Double
    let totalTurns: Int
    let totalToolCalls: Int
    let totalErrors: Int
    let avgLatency: Int

    var totalInputTokens: Int { turns.reduce(0) { $0 + $1.inputTokens } }
    var totalOutputTokens: Int { turns.reduce(0) { $0 + $1.outputTokens } }
    var totalCacheReadTokens: Int { turns.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalCacheCreationTokens: Int { turns.reduce(0) { $0 + $1.cacheCreationTokens } }
    var totalCacheCreation5mTokens: Int { turns.reduce(0) { $0 + $1.cacheCreation5mTokens } }
    var totalCacheCreation1hTokens: Int { turns.reduce(0) { $0 + $1.cacheCreation1hTokens } }

    // MARK: - Cost Breakdown

    struct CostBreakdown {
        let baseInputCost: Double
        let outputCost: Double
        let cacheReadCost: Double
        let cacheWrite5mCost: Double
        let cacheWrite1hCost: Double
        let cacheWriteLegacyCost: Double
        let totalCost: Double

        let baseInputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWrite5mTokens: Int
        let cacheWrite1hTokens: Int
        let cacheWriteLegacyTokens: Int

        let hasPerTTLBreakdown: Bool
        let cacheSavings: Double
    }

    struct TurnCostBreakdown {
        let inputCost: Double
        let outputCost: Double
        let cacheReadCost: Double
        let cacheWriteCost: Double
    }

    var costBreakdown: CostBreakdown {
        let dominantModel = turns.first(where: { $0.model != nil })?.model
        let pricing = Self.getPricing(for: dominantModel)

        let inputTokens = totalInputTokens
        let outputTokens = totalOutputTokens
        let cacheRead = totalCacheReadTokens
        let cacheCreation = totalCacheCreationTokens
        let cache5m = totalCacheCreation5mTokens
        let cache1h = totalCacheCreation1hTokens

        let hasPerTTL = cache5m > 0 || cache1h > 0
        let baseInput = max(0, inputTokens - cacheRead - cacheCreation)

        let baseInputCost = (Double(baseInput) / 1_000_000) * pricing.inputPerMillion
        let outCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMillion
        let cacheReadCost = (Double(cacheRead) / 1_000_000) * pricing.inputPerMillion * pricing.cacheReadMultiplier

        let write5mCost: Double
        let write1hCost: Double
        let writeLegacyCost: Double
        let legacyTokens: Int

        if hasPerTTL {
            write5mCost = (Double(cache5m) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
            write1hCost = (Double(cache1h) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite1hMultiplier
            writeLegacyCost = 0
            legacyTokens = 0
        } else {
            write5mCost = 0
            write1hCost = 0
            writeLegacyCost = (Double(cacheCreation) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
            legacyTokens = cacheCreation
        }

        let total = baseInputCost + outCost + cacheReadCost + write5mCost + write1hCost + writeLegacyCost
        let fullPriceCacheRead = (Double(cacheRead) / 1_000_000) * pricing.inputPerMillion
        let savings = fullPriceCacheRead - cacheReadCost

        return CostBreakdown(
            baseInputCost: baseInputCost,
            outputCost: outCost,
            cacheReadCost: cacheReadCost,
            cacheWrite5mCost: write5mCost,
            cacheWrite1hCost: write1hCost,
            cacheWriteLegacyCost: writeLegacyCost,
            totalCost: total,
            baseInputTokens: baseInput,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: cache5m,
            cacheWrite1hTokens: cache1h,
            cacheWriteLegacyTokens: legacyTokens,
            hasPerTTLBreakdown: hasPerTTL,
            cacheSavings: savings
        )
    }

    static func turnCostBreakdown(for turn: TurnData) -> TurnCostBreakdown {
        let pricing = getPricing(for: turn.model)
        let baseInput = max(0, turn.inputTokens - turn.cacheReadTokens - turn.cacheCreationTokens)

        let inputCost = (Double(baseInput) / 1_000_000) * pricing.inputPerMillion
        let outputCost = (Double(turn.outputTokens) / 1_000_000) * pricing.outputPerMillion
        let cacheReadCost = (Double(turn.cacheReadTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheReadMultiplier

        let cacheWriteCost: Double
        if turn.hasPerTTLBreakdown {
            let cost5m = (Double(turn.cacheCreation5mTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
            let cost1h = (Double(turn.cacheCreation1hTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite1hMultiplier
            cacheWriteCost = cost5m + cost1h
        } else {
            cacheWriteCost = (Double(turn.cacheCreationTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
        }

        return TurnCostBreakdown(
            inputCost: inputCost,
            outputCost: outputCost,
            cacheReadCost: cacheReadCost,
            cacheWriteCost: cacheWriteCost
        )
    }

    // MARK: - Robust Number Extraction

    /// Extract Int from Any (handles both Int and Double from JSON)
    private static func extractInt(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let doubleVal = value as? Double { return Int(doubleVal) }
        if let nsNumber = value as? NSNumber { return nsNumber.intValue }
        return nil
    }

    /// Extract Double from Any (handles Double, Int, NSNumber, and String from JSON)
    private static func extractDouble(_ value: Any?) -> Double? {
        if let doubleVal = value as? Double { return doubleVal }
        if let intVal = value as? Int { return Double(intVal) }
        if let nsNumber = value as? NSNumber { return nsNumber.doubleValue }
        // Handle case where value comes as a String (e.g., from JSON serialization)
        if let stringVal = value as? String, let parsed = Double(stringVal) { return parsed }
        return nil
    }

    /// Extract token usage from event payload's tokenRecord.
    private static func extractTokenUsage(from payload: [String: AnyCodable]) -> (input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cacheCreation5m: Int, cacheCreation1h: Int)? {
        guard let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
              let source = tokenRecord["source"] as? [String: Any] else {
            return nil
        }

        let input = extractInt(source["rawInputTokens"]) ?? 0
        let output = extractInt(source["rawOutputTokens"]) ?? 0
        let cacheRead = extractInt(source["rawCacheReadTokens"]) ?? 0
        let cacheCreation = extractInt(source["rawCacheCreationTokens"]) ?? 0
        let cacheCreation5m = extractInt(source["rawCacheCreation5mTokens"]) ?? 0
        let cacheCreation1h = extractInt(source["rawCacheCreation1hTokens"]) ?? 0

        return (input, output, cacheRead, cacheCreation, cacheCreation5m, cacheCreation1h)
    }

    // MARK: - Cost Calculation

    /// Model pricing per million tokens (USD)
    struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheWrite5mMultiplier: Double  // 1.25x for 5-min TTL
        let cacheWrite1hMultiplier: Double  // 2.0x for 1-hour TTL
        let cacheReadMultiplier: Double     // 0.1x (90% discount)

        static let defaultPricing = ModelPricing(
            inputPerMillion: 3.0,
            outputPerMillion: 15.0,
            cacheWrite5mMultiplier: 1.25,
            cacheWrite1hMultiplier: 2.0,
            cacheReadMultiplier: 0.1
        )
    }

    /// Get pricing for a model
    static func getPricing(for model: String?) -> ModelPricing {
        guard let model = model?.lowercased() else { return .defaultPricing }

        // Claude models - check specific versions first, then fallback to general patterns
        // Opus 4.5 ($5/$25)
        if model.contains("opus-4-5") || model.contains("opus-4.5") || model.contains("opus 4.5") {
            return ModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        // Opus legacy ($15/$75)
        if model.contains("opus") {
            return ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        // Sonnet 4.5 ($3/$15) - same as sonnet 4
        if model.contains("sonnet") {
            return ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        // Haiku 4.5 ($1/$5)
        if model.contains("haiku-4-5") || model.contains("haiku-4.5") || model.contains("haiku 4.5") {
            return ModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        // Haiku 3 legacy ($0.25/$1.25)
        if model.contains("haiku") {
            return ModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }

        // OpenAI models
        if model.contains("gpt-4o-mini") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("gpt-4o") || model.contains("gpt-4.1") {
            return ModelPricing(inputPerMillion: 2.50, outputPerMillion: 10.0, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("o3") {
            return ModelPricing(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("o4-mini") {
            return ModelPricing(inputPerMillion: 1.10, outputPerMillion: 4.40, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }

        // Gemini models
        if model.contains("gemini-2.5-pro") {
            return ModelPricing(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }
        if model.contains("gemini-2.5-flash") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }

        return .defaultPricing
    }

    /// Calculate cost from token usage
    static func calculateCost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0
    ) -> Double {
        let pricing = getPricing(for: model)

        // Base input tokens (excluding cache tokens which are billed separately)
        let baseInputTokens = max(0, inputTokens - cacheReadTokens - cacheCreationTokens)
        let baseInputCost = (Double(baseInputTokens) / 1_000_000) * pricing.inputPerMillion

        // Cache creation cost — use per-TTL pricing when breakdown is available
        let cacheCreationCost: Double
        if cacheCreation5mTokens > 0 || cacheCreation1hTokens > 0 {
            let cost5m = (Double(cacheCreation5mTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
            let cost1h = (Double(cacheCreation1hTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite1hMultiplier
            cacheCreationCost = cost5m + cost1h
        } else {
            cacheCreationCost = (Double(cacheCreationTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
        }

        // Cache read cost (discounted rate)
        let cacheReadCost = (Double(cacheReadTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheReadMultiplier

        // Output cost
        let outputCost = (Double(outputTokens) / 1_000_000) * pricing.outputPerMillion

        return baseInputCost + cacheCreationCost + cacheReadCost + outputCost
    }

    // MARK: - Initialization

    init(from events: [SessionEvent]) {
        // Track data per turn
        struct TurnAccumulator {
            var input: Int = 0
            var output: Int = 0
            var cacheRead: Int = 0
            var cacheCreation: Int = 0
            var cacheCreation5m: Int = 0
            var cacheCreation1h: Int = 0
            var cost: Double? = nil  // nil means we need to calculate it
            var latency: Int = 0
            var tools: [String] = []
            var errors: [String] = []
            var model: String? = nil
        }

        var turnData: [Int: TurnAccumulator] = [:]
        var latencySum = 0
        var latencyCount = 0
        var totalTools = 0
        var totalErrs = 0

        for event in events {
            switch event.eventType {
            case .messageAssistant:
                guard let turn = Self.extractInt(event.payload["turn"]?.value) else { continue }
                var existing = turnData[turn] ?? TurnAccumulator()

                // Token usage
                if let tokens = Self.extractTokenUsage(from: event.payload) {
                    existing.input = max(existing.input, tokens.input)
                    existing.output = max(existing.output, tokens.output)
                    existing.cacheRead = max(existing.cacheRead, tokens.cacheRead)
                    existing.cacheCreation = max(existing.cacheCreation, tokens.cacheCreation)
                    existing.cacheCreation5m = max(existing.cacheCreation5m, tokens.cacheCreation5m)
                    existing.cacheCreation1h = max(existing.cacheCreation1h, tokens.cacheCreation1h)
                }

                // Latency
                if let latency = Self.extractInt(event.payload["latency"]?.value), latency > 0 {
                    existing.latency = max(existing.latency, latency)
                    latencySum += latency
                    latencyCount += 1
                }

                // Model
                if let model = event.payload["model"]?.value as? String {
                    existing.model = model
                }

                turnData[turn] = existing

            case .streamTurnEnd:
                guard let turn = Self.extractInt(event.payload["turn"]?.value) else { continue }
                var existing = turnData[turn] ?? TurnAccumulator()

                // Token usage (primary source for turn end)
                if let tokens = Self.extractTokenUsage(from: event.payload) {
                    // Use turn end tokens if we don't have them yet or if they're larger
                    if existing.input == 0 { existing.input = tokens.input }
                    if existing.output == 0 { existing.output = tokens.output }
                    existing.cacheRead = max(existing.cacheRead, tokens.cacheRead)
                    existing.cacheCreation = max(existing.cacheCreation, tokens.cacheCreation)
                    existing.cacheCreation5m = max(existing.cacheCreation5m, tokens.cacheCreation5m)
                    existing.cacheCreation1h = max(existing.cacheCreation1h, tokens.cacheCreation1h)
                }

                // Cost - this is the authoritative source from server
                if let cost = Self.extractDouble(event.payload["cost"]?.value) {
                    existing.cost = cost
                }

                // Model (if not already set from messageAssistant)
                if existing.model == nil, let model = event.payload["model"]?.value as? String {
                    existing.model = model
                }

                turnData[turn] = existing

            case .toolCall:
                guard let turn = Self.extractInt(event.payload["turn"]?.value),
                      let toolName = event.payload["name"]?.value as? String else { continue }

                var existing = turnData[turn] ?? TurnAccumulator()
                if !existing.tools.contains(toolName) {
                    existing.tools.append(toolName)
                }
                turnData[turn] = existing
                totalTools += 1

            case .errorAgent, .errorProvider, .errorTool:
                let errorMsg = (event.payload["error"]?.value as? String) ?? "Unknown error"
                if let turn = Self.extractInt(event.payload["turn"]?.value) {
                    var existing = turnData[turn] ?? TurnAccumulator()
                    existing.errors.append(errorMsg)
                    turnData[turn] = existing
                }
                totalErrs += 1

            default:
                break
            }
        }

        // Convert to array and calculate missing costs
        self.turns = turnData.sorted { $0.key < $1.key }.map { key, value in
            // Use server cost if available, otherwise calculate locally
            let finalCost = value.cost ?? Self.calculateCost(
                model: value.model,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheReadTokens: value.cacheRead,
                cacheCreationTokens: value.cacheCreation,
                cacheCreation5mTokens: value.cacheCreation5m,
                cacheCreation1hTokens: value.cacheCreation1h
            )

            return TurnData(
                turn: key,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheReadTokens: value.cacheRead,
                cacheCreationTokens: value.cacheCreation,
                cacheCreation5mTokens: value.cacheCreation5m,
                cacheCreation1hTokens: value.cacheCreation1h,
                cost: finalCost,
                latency: value.latency,
                toolCount: value.tools.count,
                tools: value.tools,
                errorCount: value.errors.count,
                errors: value.errors,
                model: value.model?.shortModelName
            )
        }

        self.totalCost = self.turns.reduce(0) { $0 + $1.cost }
        self.totalTurns = self.turns.count
        self.totalToolCalls = totalTools
        self.totalErrors = totalErrs
        self.avgLatency = latencyCount > 0 ? latencySum / latencyCount : 0
    }
}
