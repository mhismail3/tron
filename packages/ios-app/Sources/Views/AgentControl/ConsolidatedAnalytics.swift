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
        let providerTotalTokens: Int
        let cost: Double?
        let pricingAvailable: Bool
        let pricingUnavailableReason: String?
        let latency: Int
        let capabilityCount: Int
        let capabilities: [String]
        let errorCount: Int
        let errors: [String]
        let model: String?
        let baseInputCost: Double
        let outputCost: Double
        let cacheReadCost: Double
        let cacheWriteCost: Double
        let baseInputTokens: Int

        var totalTokens: Int {
            if providerTotalTokens > 0 { return providerTotalTokens }
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
    let totalCapabilityInvocations: Int
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
        let outputTokens = totalOutputTokens
        let cacheRead = totalCacheReadTokens
        let cacheCreation = totalCacheCreationTokens
        let cache5m = totalCacheCreation5mTokens
        let cache1h = totalCacheCreation1hTokens

        let hasPerTTL = cache5m > 0 || cache1h > 0
        let defaultTtlTokens: Int

        if hasPerTTL {
            defaultTtlTokens = 0
        } else {
            defaultTtlTokens = cacheCreation
        }

        let baseInput = turns.reduce(0) { $0 + $1.baseInputTokens }
        let baseInputCost = turns.reduce(0) { $0 + $1.baseInputCost }
        let outCost = turns.reduce(0) { $0 + $1.outputCost }
        let cacheReadCost = turns.reduce(0) { $0 + $1.cacheReadCost }
        let cacheWriteCost = turns.reduce(0) { $0 + $1.cacheWriteCost }
        let total = baseInputCost + outCost + cacheReadCost + cacheWriteCost

        return CostBreakdown(
            baseInputCost: baseInputCost,
            outputCost: outCost,
            cacheReadCost: cacheReadCost,
            cacheWrite5mCost: hasPerTTL ? cacheWriteCost : 0,
            cacheWrite1hCost: 0,
            cacheWriteDefaultTtlCost: hasPerTTL ? 0 : cacheWriteCost,
            totalCost: total,
            baseInputTokens: baseInput,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: cache5m,
            cacheWrite1hTokens: cache1h,
            cacheWriteDefaultTtlTokens: defaultTtlTokens,
            hasPerTTLBreakdown: hasPerTTL,
            cacheSavings: 0
        )
    }

    static func turnCostBreakdown(for turn: TurnData) -> TurnCostBreakdown {
        return TurnCostBreakdown(
            inputCost: turn.baseInputCost,
            outputCost: turn.outputCost,
            cacheReadCost: turn.cacheReadCost,
            cacheWriteCost: turn.cacheWriteCost
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

    private struct ExtractedTokenUsage {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation5m: Int
        let cacheCreation1h: Int
        let providerTotal: Int
        let cost: Double?
        let pricingAvailable: Bool
        let pricingUnavailableReason: String?
        let baseInputTokens: Int
        let baseInputCost: Double
        let outputCost: Double
        let cacheReadCost: Double
        let cacheWriteCost: Double
    }

    private static func extractTokenUsage(from payload: [String: AnyCodable]) -> ExtractedTokenUsage? {
        guard let tokenRecordDict = payload["tokenRecord"]?.value as? [String: Any],
              let tokenRecord = TokenRecord.from(dict: tokenRecordDict) else {
            return nil
        }

        let cost = tokenRecord.pricing.cost
        return ExtractedTokenUsage(
            input: tokenRecord.source.rawInputTokens,
            output: tokenRecord.source.rawOutputTokens,
            cacheRead: tokenRecord.source.rawCacheReadTokens,
            cacheCreation: tokenRecord.source.rawCacheCreationTokens,
            cacheCreation5m: tokenRecord.source.rawCacheCreation5mTokens,
            cacheCreation1h: tokenRecord.source.rawCacheCreation1hTokens,
            providerTotal: tokenRecord.source.rawTotalTokens,
            cost: cost?.totalCost,
            pricingAvailable: tokenRecord.pricing.available,
            pricingUnavailableReason: tokenRecord.pricing.reason,
            baseInputTokens: cost?.baseInputTokens ?? 0,
            baseInputCost: cost?.baseInputCost ?? 0,
            outputCost: cost?.outputCost ?? 0,
            cacheReadCost: cost?.cacheReadCost ?? 0,
            cacheWriteCost: cost?.cacheWriteCost ?? 0
        )
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
            var providerTotal: Int = 0
            var cost: Double? = nil
            var pricingAvailable: Bool = false
            var pricingUnavailableReason: String? = nil
            var baseInputTokens: Int = 0
            var baseInputCost: Double = 0
            var outputCost: Double = 0
            var cacheReadCost: Double = 0
            var cacheWriteCost: Double = 0
            var latency: Int = 0
            var capabilities: [String] = []
            var errors: [String] = []
            var model: String? = nil
        }

        // Sequential array: each canonical token segment appends or updates a
        // server-owned turn record. The segment-aware key prevents provider
        // switches or resumes with repeated turn numbers from colliding.
        var turnEntries: [TurnAccumulator] = []
        var turnKeyToLatestIndex: [String: Int] = [:]
        var turnToLatestIndexes: [Int: [Int]] = [:]
        var previousTurn: Int? = nil
        var previousModel: String? = nil
        var latencySum = 0
        var latencyCount = 0
        var totalCapabilities = 0
        var totalErrs = 0

        for event in events {
            switch event.eventType {
            case .messageAssistant:
                guard let turn = Self.extractInt(event.payload["turn"]?.value) else { continue }
                let newModel = event.payload["model"]?.value as? String
                guard let turnKey = Self.turnKey(payload: event.payload) else { continue }

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
                    turnKeyToLatestIndex.removeAll()
                    turnToLatestIndexes.removeAll()
                }
                previousTurn = turn
                if let newModel = newModel {
                    previousModel = newModel
                }

                // If this turn already has an entry (multiple assistant messages per turn,
                // common in imported sessions), accumulate into the existing entry.
                if let existingIndex = turnKeyToLatestIndex[turnKey] {
                    if let tokens = Self.extractTokenUsage(from: event.payload) {
                        turnEntries[existingIndex].input += tokens.input
                        turnEntries[existingIndex].output += tokens.output
                        turnEntries[existingIndex].cacheRead += tokens.cacheRead
                        turnEntries[existingIndex].cacheCreation += tokens.cacheCreation
                        turnEntries[existingIndex].cacheCreation5m += tokens.cacheCreation5m
                        turnEntries[existingIndex].cacheCreation1h += tokens.cacheCreation1h
                        turnEntries[existingIndex].providerTotal += tokens.providerTotal
                        turnEntries[existingIndex].cost = (turnEntries[existingIndex].cost ?? 0) + (tokens.cost ?? 0)
                        turnEntries[existingIndex].pricingAvailable = turnEntries[existingIndex].pricingAvailable || tokens.pricingAvailable
                        turnEntries[existingIndex].pricingUnavailableReason = tokens.pricingUnavailableReason
                        turnEntries[existingIndex].baseInputTokens += tokens.baseInputTokens
                        turnEntries[existingIndex].baseInputCost += tokens.baseInputCost
                        turnEntries[existingIndex].outputCost += tokens.outputCost
                        turnEntries[existingIndex].cacheReadCost += tokens.cacheReadCost
                        turnEntries[existingIndex].cacheWriteCost += tokens.cacheWriteCost
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
                        acc.providerTotal = tokens.providerTotal
                        acc.cost = tokens.cost
                        acc.pricingAvailable = tokens.pricingAvailable
                        acc.pricingUnavailableReason = tokens.pricingUnavailableReason
                        acc.baseInputTokens = tokens.baseInputTokens
                        acc.baseInputCost = tokens.baseInputCost
                        acc.outputCost = tokens.outputCost
                        acc.cacheReadCost = tokens.cacheReadCost
                        acc.cacheWriteCost = tokens.cacheWriteCost
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
                    turnKeyToLatestIndex[turnKey] = index
                    turnToLatestIndexes[turn, default: []].append(index)
                }

            case .streamTurnEnd:
                guard Self.extractInt(event.payload["turn"]?.value) != nil else { continue }
                guard let turnKey = Self.turnKey(payload: event.payload),
                      let index = turnKeyToLatestIndex[turnKey] else { continue }

                if let tokens = Self.extractTokenUsage(from: event.payload) {
                    if turnEntries[index].input == 0 { turnEntries[index].input = tokens.input }
                    if turnEntries[index].output == 0 { turnEntries[index].output = tokens.output }
                    turnEntries[index].cacheRead = max(turnEntries[index].cacheRead, tokens.cacheRead)
                    turnEntries[index].cacheCreation = max(turnEntries[index].cacheCreation, tokens.cacheCreation)
                    turnEntries[index].cacheCreation5m = max(turnEntries[index].cacheCreation5m, tokens.cacheCreation5m)
                    turnEntries[index].cacheCreation1h = max(turnEntries[index].cacheCreation1h, tokens.cacheCreation1h)
                    turnEntries[index].providerTotal = max(turnEntries[index].providerTotal, tokens.providerTotal)
                    turnEntries[index].cost = tokens.cost
                    turnEntries[index].pricingAvailable = tokens.pricingAvailable
                    turnEntries[index].pricingUnavailableReason = tokens.pricingUnavailableReason
                    turnEntries[index].baseInputTokens = tokens.baseInputTokens
                    turnEntries[index].baseInputCost = tokens.baseInputCost
                    turnEntries[index].outputCost = tokens.outputCost
                    turnEntries[index].cacheReadCost = tokens.cacheReadCost
                    turnEntries[index].cacheWriteCost = tokens.cacheWriteCost
                }

                if turnEntries[index].model == nil, let model = event.payload["model"]?.value as? String {
                    turnEntries[index].model = model
                }

            case .capabilityInvocationStarted:
                guard let turn = Self.extractInt(event.payload["turn"]?.value),
                      let modelPrimitiveName = event.payload["modelPrimitiveName"]?.value as? String,
                      let index = Self.latestIndex(for: turn, in: turnToLatestIndexes) else { continue }

                if !turnEntries[index].capabilities.contains(modelPrimitiveName) {
                    turnEntries[index].capabilities.append(modelPrimitiveName)
                }
                totalCapabilities += 1

            case .errorAgent, .errorProvider, .errorCapability:
                let errorMsg = (event.payload["error"]?.value as? String) ?? "Unknown error"
                if let turn = Self.extractInt(event.payload["turn"]?.value),
                   let index = Self.latestIndex(for: turn, in: turnToLatestIndexes) {
                    turnEntries[index].errors.append(errorMsg)
                }
                totalErrs += 1

            case .messageUser:
                turnKeyToLatestIndex.removeAll()
                turnToLatestIndexes.removeAll()

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
                providerTotalTokens: value.providerTotal,
                cost: value.cost,
                pricingAvailable: value.pricingAvailable,
                pricingUnavailableReason: value.pricingUnavailableReason,
                latency: value.latency,
                capabilityCount: value.capabilities.count,
                capabilities: value.capabilities,
                errorCount: value.errors.count,
                errors: value.errors,
                model: value.model?.shortModelName,
                baseInputCost: value.baseInputCost,
                outputCost: value.outputCost,
                cacheReadCost: value.cacheReadCost,
                cacheWriteCost: value.cacheWriteCost,
                baseInputTokens: value.baseInputTokens
            )
        }

        self.totalCost = self.turns.reduce(0) { $0 + ($1.cost ?? 0) }
        self.totalTurns = self.turns.count
        self.totalCapabilityInvocations = totalCapabilities
        self.totalErrors = totalErrs
        self.avgLatency = latencyCount > 0 ? latencySum / latencyCount : 0
    }

    private static func turnKey(payload: [String: AnyCodable]) -> String? {
        guard let tokenRecordDict = payload["tokenRecord"]?.value as? [String: Any],
              let tokenRecord = TokenRecord.from(dict: tokenRecordDict) else {
            return nil
        }
        return "\(tokenRecord.meta.contextSegmentId):\(tokenRecord.meta.turn)"
    }

    private static func latestIndex(for turn: Int, in index: [Int: [Int]]) -> Int? {
        index[turn]?.last
    }
}
