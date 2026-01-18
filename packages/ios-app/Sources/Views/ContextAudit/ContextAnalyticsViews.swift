import SwiftUI

// MARK: - Analytics Section

@available(iOS 26.0, *)
struct AnalyticsSection: View {
    let sessionId: String
    let events: [SessionEvent]

    @State private var showCopied = false

    private var analytics: ConsolidatedAnalytics {
        ConsolidatedAnalytics(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            VStack(alignment: .leading, spacing: 2) {
                Text("Analytics")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Session performance and cost breakdown")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Session ID (tappable to copy)
            SessionIdRow(sessionId: sessionId)

            // Cost Summary
            CostSummaryCard(analytics: analytics)

            // Turn Breakdown
            TurnBreakdownContainer(turns: analytics.turns)
        }
        .padding(.top, 8)
    }
}

// MARK: - Session ID Row

@available(iOS 26.0, *)
struct SessionIdRow: View {
    let sessionId: String
    @State private var showCopied = false

    var body: some View {
        HStack {
            Image(systemName: "number.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tronTextMuted)

            Text(showCopied ? "Copied!" : sessionId)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(showCopied ? .tronEmerald : .tronTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .animation(.easeInOut(duration: 0.15), value: showCopied)

            Spacer()

            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(.tronTextMuted)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            UIPasteboard.general.string = sessionId
            showCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showCopied = false
            }
        }
    }
}

// MARK: - Cost Summary Card

@available(iOS 26.0, *)
struct CostSummaryCard: View {
    let analytics: ConsolidatedAnalytics

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.00001 { return "$0.00" }      // Below $0.00001 (0.001 cent) - show as $0.00
        if cost < 0.0001 { return String(format: "$%.5f", cost) }  // Show 5 decimal places
        if cost < 0.001 { return String(format: "$%.4f", cost) }   // Show 4 decimal places
        if cost < 0.01 { return String(format: "$%.3f", cost) }    // Show 3 decimal places
        return String(format: "$%.2f", cost)
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronAmber)

                Text("Session Cost")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronAmber)

                Spacer()

                Text(formatCost(analytics.totalCost))
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronAmber)
            }

            // Stats row
            HStack(spacing: 0) {
                CostStatItem(value: "\(analytics.totalTurns)", label: "turns")
                CostStatItem(value: formatLatency(analytics.avgLatency), label: "avg latency")
                CostStatItem(value: "\(analytics.totalToolCalls)", label: "tool calls")
                CostStatItem(value: "\(analytics.totalErrors)", label: "errors", isError: analytics.totalErrors > 0)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronAmber.opacity(0.15))
        }
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }
}

@available(iOS 26.0, *)
struct CostStatItem: View {
    let value: String
    let label: String
    var isError: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(isError ? .tronError : .white.opacity(0.8))
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Turn Breakdown Container

@available(iOS 26.0, *)
struct TurnBreakdownContainer: View {
    let turns: [ConsolidatedAnalytics.TurnData]
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private var totalTokens: Int {
        turns.reduce(0) { $0 + $1.totalTokens }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.number")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronEmerald)

                Text("Turn Breakdown")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald)

                // Count badge
                Text("\(turns.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronEmerald.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text(formatTokens(totalTokens))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                if turns.isEmpty {
                    Text("No turns recorded")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(12)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(turns) { turn in
                            TurnRow(turn: turn)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.tronEmerald.opacity(0.15))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Turn Row (Expandable)

@available(iOS 26.0, *)
struct TurnRow: View {
    let turn: ConsolidatedAnalytics.TurnData
    @State private var isExpanded = false

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.00001 { return "$0.00" }      // Below $0.00001 (0.001 cent) - show as $0.00
        if cost < 0.0001 { return String(format: "$%.5f", cost) }  // Show 5 decimal places
        if cost < 0.001 { return String(format: "$%.4f", cost) }   // Show 4 decimal places
        if cost < 0.01 { return String(format: "$%.3f", cost) }    // Show 3 decimal places
        return String(format: "$%.2f", cost)
    }

    private func formatLatency(_ ms: Int) -> String {
        if ms == 0 { return "-" }
        if ms < 1000 {
            return "\(ms)ms"
        } else {
            return String(format: "%.1fs", Double(ms) / 1000.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                // Turn number badge
                Text("\(turn.turn)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 24, height: 24)
                    .background(Color.tronEmerald.opacity(0.2))
                    .clipShape(Circle())

                // Summary info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // Tokens
                        HStack(spacing: 3) {
                            Image(systemName: "number")
                                .font(.system(size: 9))
                            Text(formatTokens(turn.totalTokens))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.white.opacity(0.7))

                        // Cost
                        Text(formatCost(turn.cost))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronAmber)

                        // Latency
                        if turn.latency > 0 {
                            Text(formatLatency(turn.latency))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }

                    // Tools and errors indicators
                    HStack(spacing: 8) {
                        if turn.toolCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 8))
                                Text("\(turn.toolCount)")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.tronCyan)
                        }

                        if turn.errorCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 8))
                                Text("\(turn.errorCount)")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                            .foregroundStyle(.tronError)
                        }

                        if let model = turn.model {
                            Text(model)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Token breakdown
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(formatTokens(turn.inputTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronOrange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                            Text(formatTokens(turn.outputTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronRed)
                        }

                        // Cache tokens (only show if present)
                        if turn.cacheReadTokens > 0 || turn.cacheCreationTokens > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cache")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.4))
                                HStack(spacing: 4) {
                                    if turn.cacheReadTokens > 0 {
                                        Text("↓\(formatTokens(turn.cacheReadTokens))")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.tronEmerald)
                                    }
                                    if turn.cacheCreationTokens > 0 {
                                        Text("↑\(formatTokens(turn.cacheCreationTokens))")
                                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                                            .foregroundStyle(.tronPurple)
                                    }
                                }
                            }
                        }

                        Spacer()
                    }

                    // Tools used
                    if !turn.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tools")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))

                            FlowLayout(spacing: 4) {
                                ForEach(turn.tools, id: \.self) { tool in
                                    Text(tool)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tronCyan)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.tronCyan.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    // Errors
                    if !turn.errors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Errors")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))

                            ForEach(turn.errors, id: \.self) { error in
                                Text(error)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tronError)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.tronEmerald.opacity(0.08))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Flow Layout (for tool tags)

@available(iOS 26.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Consolidated Analytics Data Model

struct ConsolidatedAnalytics {
    struct TurnData: Identifiable {
        let id = UUID()
        let turn: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let cost: Double
        let latency: Int
        let toolCount: Int
        let tools: [String]
        let errorCount: Int
        let errors: [String]
        let model: String?

        var totalTokens: Int { inputTokens + outputTokens }
    }

    let turns: [TurnData]
    let totalCost: Double
    let totalTurns: Int
    let totalToolCalls: Int
    let totalErrors: Int
    let avgLatency: Int

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

    /// Extract token usage from event payload
    private static func extractTokenUsage(from payload: [String: AnyCodable]) -> (input: Int, output: Int, cacheRead: Int, cacheCreation: Int)? {
        guard let tokenUsage = payload["tokenUsage"]?.value as? [String: Any] else { return nil }

        let input = extractInt(tokenUsage["inputTokens"]) ?? 0
        let output = extractInt(tokenUsage["outputTokens"]) ?? 0
        let cacheRead = extractInt(tokenUsage["cacheReadTokens"]) ?? 0
        let cacheCreation = extractInt(tokenUsage["cacheCreationTokens"]) ?? 0

        return (input, output, cacheRead, cacheCreation)
    }

    // MARK: - Cost Calculation

    /// Model pricing per million tokens (USD)
    private struct ModelPricing {
        let inputPerMillion: Double
        let outputPerMillion: Double
        let cacheWriteMultiplier: Double  // Applied to input rate for cache creation
        let cacheReadMultiplier: Double   // Applied to input rate for cache reads (discount)

        static let defaultPricing = ModelPricing(
            inputPerMillion: 3.0,
            outputPerMillion: 15.0,
            cacheWriteMultiplier: 1.25,
            cacheReadMultiplier: 0.1
        )
    }

    /// Get pricing for a model
    private static func getPricing(for model: String?) -> ModelPricing {
        guard let model = model?.lowercased() else { return .defaultPricing }

        // Claude models - check specific versions first, then fallback to general patterns
        // Opus 4.5 ($5/$25)
        if model.contains("opus-4-5") || model.contains("opus-4.5") || model.contains("opus 4.5") {
            return ModelPricing(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }
        // Opus legacy ($15/$75)
        if model.contains("opus") {
            return ModelPricing(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }
        // Sonnet 4.5 ($3/$15) - same as sonnet 4
        if model.contains("sonnet") {
            return ModelPricing(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }
        // Haiku 4.5 ($1/$5)
        if model.contains("haiku-4-5") || model.contains("haiku-4.5") || model.contains("haiku 4.5") {
            return ModelPricing(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }
        // Haiku 3 legacy ($0.25/$1.25)
        if model.contains("haiku") {
            return ModelPricing(inputPerMillion: 0.25, outputPerMillion: 1.25, cacheWriteMultiplier: 1.25, cacheReadMultiplier: 0.1)
        }

        // OpenAI models
        if model.contains("gpt-4o-mini") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("gpt-4o") || model.contains("gpt-4.1") {
            return ModelPricing(inputPerMillion: 2.50, outputPerMillion: 10.0, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("o3") {
            return ModelPricing(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }
        if model.contains("o4-mini") {
            return ModelPricing(inputPerMillion: 1.10, outputPerMillion: 4.40, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.5)
        }

        // Gemini models
        if model.contains("gemini-2.5-pro") {
            return ModelPricing(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }
        if model.contains("gemini-2.5-flash") || model.contains("gemini-2.0-flash") {
            return ModelPricing(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheWriteMultiplier: 1.0, cacheReadMultiplier: 0.25)
        }

        return .defaultPricing
    }

    /// Calculate cost from token usage
    private static func calculateCost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) -> Double {
        let pricing = getPricing(for: model)

        // Base input tokens (excluding cache tokens which are billed separately)
        let baseInputTokens = max(0, inputTokens - cacheReadTokens - cacheCreationTokens)
        let baseInputCost = (Double(baseInputTokens) / 1_000_000) * pricing.inputPerMillion

        // Cache creation cost (higher rate)
        let cacheCreationCost = (Double(cacheCreationTokens) / 1_000_000) * pricing.inputPerMillion * pricing.cacheWriteMultiplier

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
                cacheCreationTokens: value.cacheCreation
            )

            return TurnData(
                turn: key,
                inputTokens: value.input,
                outputTokens: value.output,
                cacheReadTokens: value.cacheRead,
                cacheCreationTokens: value.cacheCreation,
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

