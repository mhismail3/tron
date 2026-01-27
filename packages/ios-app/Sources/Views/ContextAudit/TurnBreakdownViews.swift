import SwiftUI

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
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronEmerald)

                Text("Turn Breakdown")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)

                // Count badge
                Text("\(turns.count)")
                    .font(TronTypography.pillValue)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronEmerald.opacity(0.7))
                    .clipShape(Capsule())

                Spacer()

                Text(formatTokens(totalTokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
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
                        .font(TronTypography.codeCaption)
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
        if cost < 0.00001 { return "$0.00" }
        if cost < 0.0001 { return String(format: "$%.5f", cost) }
        if cost < 0.001 { return String(format: "$%.4f", cost) }
        if cost < 0.01 { return String(format: "$%.3f", cost) }
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
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .bold))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 24, height: 24)
                    .background(Color.tronEmerald.opacity(0.2))
                    .clipShape(Circle())

                // Summary info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // Tokens
                        Text("\(formatTokens(turn.totalTokens)) tokens")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.white.opacity(0.7))

                        // Cost
                        Text(formatCost(turn.cost))
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronAmber)

                        // Latency
                        if turn.latency > 0 {
                            Text(formatLatency(turn.latency))
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }

                    // Tools and errors indicators
                    HStack(spacing: 8) {
                        if turn.toolCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "hammer.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeXS))
                                Text("\(turn.toolCount)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            }
                            .foregroundStyle(.tronCyan)
                        }

                        if turn.errorCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeXS))
                                Text("\(turn.errorCount)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            }
                            .foregroundStyle(.tronError)
                        }

                        if let model = turn.model {
                            Text(model)
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
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
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.4))
                            Text(formatTokens(turn.inputTokens))
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronOrange)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output")
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.4))
                            Text(formatTokens(turn.outputTokens))
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronRed)
                        }

                        // Cache tokens (only show if present)
                        if turn.cacheReadTokens > 0 || turn.cacheCreationTokens > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cache")
                                    .font(TronTypography.pill)
                                    .foregroundStyle(.white.opacity(0.4))
                                HStack(spacing: 4) {
                                    if turn.cacheReadTokens > 0 {
                                        Text("↓\(formatTokens(turn.cacheReadTokens))")
                                            .font(TronTypography.codeSM)
                                            .foregroundStyle(.tronEmerald)
                                    }
                                    if turn.cacheCreationTokens > 0 {
                                        Text("↑\(formatTokens(turn.cacheCreationTokens))")
                                            .font(TronTypography.codeSM)
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
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.4))

                            FlowLayout(spacing: 4) {
                                ForEach(turn.tools, id: \.self) { tool in
                                    Text(tool)
                                        .font(TronTypography.pill)
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
                                .font(TronTypography.pill)
                                .foregroundStyle(.white.opacity(0.4))

                            ForEach(turn.errors, id: \.self) { error in
                                Text(error)
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
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
