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

        var totalTokens: Int {
            let cacheWrite = hasPerTTLBreakdown
                ? (cacheCreation5mTokens + cacheCreation1hTokens)
                : cacheCreationTokens
            return inputTokens + outputTokens + cacheReadTokens + cacheWrite
        }
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
        let cacheWriteDefaultTtlCost: Double
        let totalCost: Double

        let baseInputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWrite5mTokens: Int
        let cacheWrite1hTokens: Int
        let cacheWriteDefaultTtlTokens: Int

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
        let writeDefaultTtlCost: Double
        let defaultTtlTokens: Int

        if hasPerTTL {
            write5mCost = (Double(cache5m) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
            write1hCost = (Double(cache1h) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite1hMultiplier
            writeDefaultTtlCost = 0
            defaultTtlTokens = 0
        } else {
            write5mCost = 0
            write1hCost = 0
            writeDefaultTtlCost = (Double(cacheCreation) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWrite5mMultiplier
            defaultTtlTokens = cacheCreation
        }

        let total = baseInputCost + outCost + cacheReadCost + write5mCost + write1hCost + writeDefaultTtlCost
        let fullPriceCacheRead = (Double(cacheRead) / 1_000_000) * pricing.inputPerMillion
        let savings = fullPriceCacheRead - cacheReadCost

        return CostBreakdown(
            baseInputCost: baseInputCost,
            outputCost: outCost,
            cacheReadCost: cacheReadCost,
            cacheWrite5mCost: write5mCost,
            cacheWrite1hCost: write1hCost,
            cacheWriteDefaultTtlCost: writeDefaultTtlCost,
            totalCost: total,
            baseInputTokens: baseInput,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: cache5m,
            cacheWrite1hTokens: cache1h,
            cacheWriteDefaultTtlTokens: defaultTtlTokens,
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

    /// Extract token usage from event payload's tokenRecord, falling back to tokenUsage.
    ///
    /// Live sessions emit tokenRecord (with source.rawInputTokens etc.).
    /// Imported sessions only emit tokenUsage (with inputTokens etc.).
    private static func extractTokenUsage(from payload: [String: AnyCodable]) -> (input: Int, output: Int, cacheRead: Int, cacheCreation: Int, cacheCreation5m: Int, cacheCreation1h: Int)? {
        // Prefer tokenRecord (live sessions)
        if let tokenRecord = payload["tokenRecord"]?.value as? [String: Any],
           let source = tokenRecord["source"] as? [String: Any] {
            let input = extractInt(source["rawInputTokens"]) ?? 0
            let output = extractInt(source["rawOutputTokens"]) ?? 0
            let cacheRead = extractInt(source["rawCacheReadTokens"]) ?? 0
            let cacheCreation = extractInt(source["rawCacheCreationTokens"]) ?? 0
            let cacheCreation5m = extractInt(source["rawCacheCreation5mTokens"]) ?? 0
            let cacheCreation1h = extractInt(source["rawCacheCreation1hTokens"]) ?? 0
            return (input, output, cacheRead, cacheCreation, cacheCreation5m, cacheCreation1h)
        }

        // Fallback to tokenUsage (imported sessions)
        if let tokenUsage = payload["tokenUsage"]?.value as? [String: Any] {
            let input = extractInt(tokenUsage["inputTokens"]) ?? 0
            let output = extractInt(tokenUsage["outputTokens"]) ?? 0
            let cacheRead = extractInt(tokenUsage["cacheReadTokens"]) ?? 0
            let cacheCreation = extractInt(tokenUsage["cacheCreationTokens"]) ?? 0
            return (input, output, cacheRead, cacheCreation, 0, 0)
        }

        return nil
    }

    // MARK: - Cost Breakdown Pricing (display-only)

    /// Model pricing per million tokens (USD).
    /// Used only for the analytics cost breakdown display — total cost comes from the server.
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

    /// Get pricing for a model (display-only, for analytics cost breakdown visualization).
    /// Total cost is always server-provided — this is only used to estimate component proportions.
    static func getPricing(for model: String?) -> ModelPricing {
        guard let model = model?.lowercased() else { return .defaultPricing }

        if model.contains("opus-4-5") || model.contains("opus-4.5") || model.contains("opus 4.5") {
            return ModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        if model.contains("opus") {
            return ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        if model.contains("sonnet") {
            return ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        if model.contains("haiku-4-5") || model.contains("haiku-4.5") || model.contains("haiku 4.5") {
            return ModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
        if model.contains("haiku") {
            return ModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25, cacheWrite5mMultiplier: 1.25, cacheWrite1hMultiplier: 2.0, cacheReadMultiplier: 0.1)
        }
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
        if model.contains("gemini-2.5-pro") {
            return ModelPricing(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }
        if model.contains("gemini-2.5-flash") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWrite5mMultiplier: 1.0, cacheWrite1hMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }

        return .defaultPricing
    }

    // MARK: - Initialization

    init(from events: [SessionEvent]) {
        struct TurnAccumulator {
            var input: Int = 0
            var output: Int = 0
            var cacheRead: Int = 0
            var cacheCreation: Int = 0
            var cacheCreation5m: Int = 0
            var cacheCreation1h: Int = 0
            var cost: Double? = nil
            var latency: Int = 0
            var tools: [String] = []
            var errors: [String] = []
            var model: String? = nil
        }

        // Sequential array — each message.assistant appends a new entry (no collisions).
        // turnNumberToLatestIndex maps turn number → latest array index so that
        // stream.turn_end / tool.call / errors route to the correct entry.
        // Cleared on detected "turn reset" so multi-model conversations (where
        // each model restarts turn numbering at 1) get distinct entries.
        var turnEntries: [TurnAccumulator] = []
        var turnNumberToLatestIndex: [Int: Int] = [:]
        var previousTurn: Int? = nil
        var previousModel: String? = nil
        var latencySum = 0
        var latencyCount = 0
        var totalTools = 0
        var totalErrs = 0

        for event in events {
            switch event.eventType {
            case .messageAssistant:
                guard let turn = Self.extractInt(event.payload["turn"]?.value) else { continue }
                let newModel = event.payload["model"]?.value as? String

                // Detect "turn reset" — start of a new conversation segment with
                // overlapping turn numbers:
                //   1. turn number LOWER than the previous turn (numbering restarts)
                //   2. turn number EQUAL to previous and model has changed
                // Same turn number with same model continues to accumulate (the
                // imported-session case where one logical turn has multiple
                // message.assistant events).
                let isReset: Bool = {
                    guard let prevTurn = previousTurn else { return false }
                    if turn < prevTurn { return true }
                    if turn == prevTurn,
                       let prev = previousModel,
                       let new = newModel,
                       prev != new {
                        return true
                    }
                    return false
                }()

                if isReset {
                    turnNumberToLatestIndex.removeAll()
                }
                previousTurn = turn
                if let newModel = newModel {
                    previousModel = newModel
                }

                // If this turn already has an entry (multiple assistant messages per turn,
                // common in imported sessions), accumulate into the existing entry.
                if let existingIndex = turnNumberToLatestIndex[turn] {
                    if let tokens = Self.extractTokenUsage(from: event.payload) {
                        turnEntries[existingIndex].input += tokens.input
                        turnEntries[existingIndex].output += tokens.output
                        turnEntries[existingIndex].cacheRead += tokens.cacheRead
                        turnEntries[existingIndex].cacheCreation += tokens.cacheCreation
                        turnEntries[existingIndex].cacheCreation5m += tokens.cacheCreation5m
                        turnEntries[existingIndex].cacheCreation1h += tokens.cacheCreation1h
                    }
                    if let latency = Self.extractInt(event.payload["latency"]?.value), latency > 0 {
                        turnEntries[existingIndex].latency += latency
                        latencySum += latency
                        latencyCount += 1
                    }
                    if turnEntries[existingIndex].model == nil, let newModel = newModel {
                        turnEntries[existingIndex].model = newModel
                    }
                } else {
                    var acc = TurnAccumulator()

                    if let tokens = Self.extractTokenUsage(from: event.payload) {
                        acc.input = tokens.input
                        acc.output = tokens.output
                        acc.cacheRead = tokens.cacheRead
                        acc.cacheCreation = tokens.cacheCreation
                        acc.cacheCreation5m = tokens.cacheCreation5m
                        acc.cacheCreation1h = tokens.cacheCreation1h
                    }

                    if let latency = Self.extractInt(event.payload["latency"]?.value), latency > 0 {
                        acc.latency = latency
                        latencySum += latency
                        latencyCount += 1
                    }

                    if let newModel = newModel {
                        acc.model = newModel
                    }

                    let index = turnEntries.count
                    turnEntries.append(acc)
                    turnNumberToLatestIndex[turn] = index
                }

            case .streamTurnEnd:
                guard let turn = Self.extractInt(event.payload["turn"]?.value),
                      let index = turnNumberToLatestIndex[turn] else { continue }

                if let tokens = Self.extractTokenUsage(from: event.payload) {
                    if turnEntries[index].input == 0 { turnEntries[index].input = tokens.input }
                    if turnEntries[index].output == 0 { turnEntries[index].output = tokens.output }
                    turnEntries[index].cacheRead = max(turnEntries[index].cacheRead, tokens.cacheRead)
                    turnEntries[index].cacheCreation = max(turnEntries[index].cacheCreation, tokens.cacheCreation)
                    turnEntries[index].cacheCreation5m = max(turnEntries[index].cacheCreation5m, tokens.cacheCreation5m)
                    turnEntries[index].cacheCreation1h = max(turnEntries[index].cacheCreation1h, tokens.cacheCreation1h)
                }

                if let cost = Self.extractDouble(event.payload["cost"]?.value) {
                    turnEntries[index].cost = cost
                }

                if turnEntries[index].model == nil, let model = event.payload["model"]?.value as? String {
                    turnEntries[index].model = model
                }

            case .toolCall:
                guard let turn = Self.extractInt(event.payload["turn"]?.value),
                      let toolName = event.payload["name"]?.value as? String,
                      let index = turnNumberToLatestIndex[turn] else { continue }

                if !turnEntries[index].tools.contains(toolName) {
                    turnEntries[index].tools.append(toolName)
                }
                totalTools += 1

            case .errorAgent, .errorProvider, .errorTool:
                let errorMsg = (event.payload["error"]?.value as? String) ?? "Unknown error"
                if let turn = Self.extractInt(event.payload["turn"]?.value),
                   let index = turnNumberToLatestIndex[turn] {
                    turnEntries[index].errors.append(errorMsg)
                }
                totalErrs += 1

            case .messageUser:
                // A new user message signals the start of a new prompt cycle. In
                // live sessions subsequent assistants may reuse prior turn numbers
                // (e.g. the server restarting turn numbering per cycle), so clear
                // the lookup to prevent collapsing into the previous cycle's entry.
                // Imported sessions do not interleave user messages between
                // multiple assistants for the same turn, so this does not affect
                // the import-accumulation path.
                turnNumberToLatestIndex.removeAll()

            default:
                break
            }
        }

        self.turns = turnEntries.enumerated().map { offset, value in
            return TurnData(
                turn: offset + 1,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheReadTokens: value.cacheRead,
                cacheCreationTokens: value.cacheCreation,
                cacheCreation5mTokens: value.cacheCreation5m,
                cacheCreation1hTokens: value.cacheCreation1h,
                cost: value.cost ?? 0,
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
