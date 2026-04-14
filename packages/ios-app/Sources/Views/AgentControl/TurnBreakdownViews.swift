import SwiftUI

// MARK: - Turn Row (Expandable)

@available(iOS 26.0, *)
struct TurnRow: View {
    let turn: ConsolidatedAnalytics.TurnData
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 10) {
                // Turn number badge
                Text("\(turn.turn)")
                    .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .bold))
                    .foregroundStyle(.tronAmberLight)
                    .frame(width: 24, height: 24)
                    .background(Color.tronAmberLight.opacity(0.2))
                    .clipShape(Circle())

                // Summary info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        // Tokens
                        Text("\(TokenFormatter.format(turn.totalTokens)) tokens")
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronTextSecondary)

                        // Cost
                        Text(formatCost(turn.cost))
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.tronAmberLight)

                        // Latency
                        if turn.latency > 0 {
                            Text(DurationFormatter.format(turn.latency, style: .compact))
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
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
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
                    .foregroundStyle(.tronTextDisabled)
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
                                .foregroundStyle(.tronTextMuted)
                            Text(TokenFormatter.format(turn.inputTokens))
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronAmberLight)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Output")
                                .font(TronTypography.pill)
                                .foregroundStyle(.tronTextMuted)
                            Text(TokenFormatter.format(turn.outputTokens))
                                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                                .foregroundStyle(.tronAmberLight)
                        }

                        // Cache tokens (only show if present)
                        if turn.cacheReadTokens > 0 || turn.cacheCreationTokens > 0 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cache")
                                    .font(TronTypography.pill)
                                    .foregroundStyle(.tronTextMuted)
                                HStack(spacing: 4) {
                                    if turn.cacheReadTokens > 0 {
                                        Text("↓\(TokenFormatter.format(turn.cacheReadTokens))")
                                            .font(TronTypography.codeSM)
                                            .foregroundStyle(.tronAmberLight)
                                    }
                                    if turn.hasPerTTLBreakdown {
                                        if turn.cacheCreation5mTokens > 0 {
                                            Text("↑5m:\(TokenFormatter.format(turn.cacheCreation5mTokens))")
                                                .font(TronTypography.codeSM)
                                                .foregroundStyle(.tronAmberLight)
                                        }
                                        if turn.cacheCreation1hTokens > 0 {
                                            Text("↑1h:\(TokenFormatter.format(turn.cacheCreation1hTokens))")
                                                .font(TronTypography.codeSM)
                                                .foregroundStyle(.tronAmberLight)
                                        }
                                    } else if turn.cacheCreationTokens > 0 {
                                        Text("↑\(TokenFormatter.format(turn.cacheCreationTokens))")
                                            .font(TronTypography.codeSM)
                                            .foregroundStyle(.tronAmberLight)
                                    }
                                }
                            }
                        }

                        Spacer()
                    }

                    // Per-component cost breakdown
                    TurnCostBreakdownRow(turn: turn)

                    // Tools used
                    if !turn.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tools")
                                .font(TronTypography.pill)
                                .foregroundStyle(.tronTextMuted)

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
                                .foregroundStyle(.tronTextMuted)

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
        .sectionFill(.tronAmberLight, cornerRadius: 8, subtle: true)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Turn Cost Breakdown Row

@available(iOS 26.0, *)
private struct TurnCostBreakdownRow: View {
    let turn: ConsolidatedAnalytics.TurnData

    var body: some View {
        let cb = ConsolidatedAnalytics.turnCostBreakdown(for: turn)

        HStack(spacing: 4) {
            Text("Cost:")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)

            Text("in \(formatCost(cb.inputCost))")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)

            Text("+ out \(formatCost(cb.outputCost))")
                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextSecondary)

            if turn.cacheReadTokens > 0 {
                Text("+ ↓\(formatCost(cb.cacheReadCost))")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }

            if cb.cacheWriteCost > 0 {
                Text("+ ↑\(formatCost(cb.cacheWriteCost))")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
        }
    }
}

