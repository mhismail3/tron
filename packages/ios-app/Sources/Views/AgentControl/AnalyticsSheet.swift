import SwiftUI

// MARK: - Analytics Sheet

/// Drill-down sheet for session analytics: summary card + expandable per-turn breakdown.
@available(iOS 26.0, *)
struct AnalyticsSheet: View {
    let analytics: ConsolidatedAnalytics
    let turnGroups: [TurnGroup]

    @Environment(\.dismiss) private var dismiss
    @State private var expandedTurns: Set<String> = []

    /// Pre-indexed turn groups by turn number for O(1) lookup per row.
    private var turnGroupIndex: [Int: TurnGroup] {
        Dictionary(turnGroups.map { ($0.turnNumber, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Enable liquid glass on turn cards only for short histories; large lists fall back to plain fill to avoid rendering glitches.
    private var useGlassForTurns: Bool {
        analytics.turns.count <= 25
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 16) {
                    // Session-level analytics summary
                    SessionAnalyticsSection(analytics: analytics)

                    // Per-turn breakdown
                    if !analytics.turns.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Per-Turn Breakdown")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                                .foregroundStyle(.tronTextSecondary)

                            LazyVStack(spacing: 6) {
                                ForEach(analytics.turns) { turnData in
                                    turnCard(turnData)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Analytics", color: .tronRose)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronRose)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronRose)
    }

    // MARK: - Turn Card

    @ViewBuilder
    private func turnCard(_ turnData: ConsolidatedAnalytics.TurnData) -> some View {
        let isExpanded = expandedTurns.contains(turnData.id.uuidString)
        let turnGroup = turnGroupIndex[turnData.turn]

        VStack(spacing: 0) {
            // Header row — always visible
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isExpanded {
                        expandedTurns.remove(turnData.id.uuidString)
                    } else {
                        expandedTurns.insert(turnData.id.uuidString)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    // Turn number badge
                    Text("\(turnData.turn)")
                        .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .bold))
                        .foregroundStyle(.tronRose)
                        .frame(width: 24, height: 24)
                        .background(Color.tronRose.opacity(0.2))
                        .clipShape(Circle())

                    // Preview text
                    if let preview = turnGroup?.displayPreview {
                        Text(preview)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)
                    } else {
                        Text("Turn \(turnData.turn)")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                    }

                    Spacer()

                    // Compact stats
                    Text(TokenFormatter.format(turnData.totalTokens))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronRose)

                    Text(formatCost(turnData.cost))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronRose)

                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isExpanded ? -180 : 0))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded detail
            if isExpanded {
                turnDetailContent(turnData)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .sectionFill(.tronRose, cornerRadius: 10, subtle: true, compact: useGlassForTurns)
    }

    // MARK: - Expanded Turn Detail

    @ViewBuilder
    private func turnDetailContent(_ turnData: ConsolidatedAnalytics.TurnData) -> some View {
        let breakdown = ConsolidatedAnalytics.turnCostBreakdown(for: turnData)

        VStack(spacing: 8) {
            // Token/cost pills
            HStack(spacing: 6) {
                analyticsPill(label: "In", tokens: turnData.inputTokens, cost: breakdown.inputCost)
                analyticsPill(label: "Out", tokens: turnData.outputTokens, cost: breakdown.outputCost)
                if turnData.cacheReadTokens > 0 {
                    analyticsPill(label: "Cache\u{2193}", tokens: turnData.cacheReadTokens, cost: breakdown.cacheReadCost)
                }
                if turnData.cacheCreationTokens > 0 {
                    analyticsPill(label: "Cache\u{2191}", tokens: turnData.cacheCreationTokens, cost: breakdown.cacheWriteCost)
                }
            }

            // Stats row — 4-column grid to align with pills above
            let statColumns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
            LazyVGrid(columns: statColumns, alignment: .leading, spacing: 0) {
                if turnData.toolCount > 0 {
                    statItem(value: "\(turnData.toolCount)", label: "Tools")
                }
                if turnData.latency > 0 {
                    statItem(value: DurationFormatter.format(turnData.latency, style: .compact), label: "Latency")
                }
                if let model = turnData.model {
                    statItem(value: model, label: "Model")
                }
                if turnData.errorCount > 0 {
                    statItem(value: "\(turnData.errorCount)", label: "Errors", color: .tronError)
                }
            }

            // Tool names
            if !turnData.tools.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(turnData.tools, id: \.self) { tool in
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
    }

    private func analyticsPill(label: String, tokens: Int, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeXS))
                .foregroundStyle(.tronTextMuted)
            HStack {
                Text(TokenFormatter.format(tokens))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronRose)
                Spacer()
                Text(formatCost(cost))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronRose)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .sectionFill(.tronRose, cornerRadius: 8, subtle: true, compact: useGlassForTurns, interactive: false)
    }

    private func statItem(value: String, label: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeXS))
                .foregroundStyle(.tronTextMuted)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(color ?? .tronRose)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
