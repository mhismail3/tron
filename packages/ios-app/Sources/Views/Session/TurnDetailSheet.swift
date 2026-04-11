import SwiftUI

// MARK: - Turn Detail Sheet

/// Detail sheet showing event-by-event history for a specific turn,
/// along with token/cost breakdown and fork capabilities.
@available(iOS 26.0, *)
struct TurnDetailSheet: View {
    let turnGroup: TurnGroup
    let sessionId: String
    let eventStoreManager: EventStoreManager
    let onDismissParent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var forkEventId: String?

    private var turnTitle: String {
        turnGroup.turnNumber == 0 ? "Session Events" : "Turn \(turnGroup.turnNumber)"
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: turnTitle,
            iconName: turnGroup.turnNumber == 0 ? "gearshape" : "number.circle",
            accent: .tronAmberLight
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Analytics summary
                    if let data = turnGroup.analyticsData {
                        turnAnalyticsSummary(data)
                            .sheetSection()
                    }

                    // Event timeline
                    eventTimeline
                        .sheetSection()
                }
                .padding(.vertical, 8)
            }
        }
        .sheet(item: Binding(
            get: { forkEventId.map { ForkEventItem(eventId: $0) } },
            set: { forkEventId = $0?.eventId }
        )) { wrapper in
            ForkConfirmationSheet(
                eventId: wrapper.eventId,
                event: turnGroup.events.first(where: { $0.id == wrapper.eventId }),
                sessionId: sessionId,
                eventStoreManager: eventStoreManager,
                onDismissParent: {
                    dismiss()
                    onDismissParent()
                }
            )
        }
    }

    // MARK: - Analytics Summary

    @ViewBuilder
    private func turnAnalyticsSummary(_ data: ConsolidatedAnalytics.TurnData) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Token breakdown
            HStack(spacing: 12) {
                tokenStat("Input", value: TokenFormatter.format(data.inputTokens))
                tokenStat("Output", value: TokenFormatter.format(data.outputTokens))

                if data.cacheReadTokens > 0 || data.cacheCreationTokens > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cache")
                            .font(TronTypography.pill)
                            .foregroundStyle(.tronTextMuted)
                        HStack(spacing: 4) {
                            if data.cacheReadTokens > 0 {
                                Text("\u{2193}\(TokenFormatter.format(data.cacheReadTokens))")
                                    .font(TronTypography.codeSM)
                                    .foregroundStyle(.tronAmberLight)
                            }
                            if data.hasPerTTLBreakdown {
                                if data.cacheCreation5mTokens > 0 {
                                    Text("\u{2191}5m:\(TokenFormatter.format(data.cacheCreation5mTokens))")
                                        .font(TronTypography.codeSM)
                                        .foregroundStyle(.tronAmberLight)
                                }
                                if data.cacheCreation1hTokens > 0 {
                                    Text("\u{2191}1h:\(TokenFormatter.format(data.cacheCreation1hTokens))")
                                        .font(TronTypography.codeSM)
                                        .foregroundStyle(.tronAmberLight)
                                }
                            } else if data.cacheCreationTokens > 0 {
                                Text("\u{2191}\(TokenFormatter.format(data.cacheCreationTokens))")
                                    .font(TronTypography.codeSM)
                                    .foregroundStyle(.tronAmberLight)
                            }
                        }
                    }
                }

                Spacer()
            }

            // Cost + latency + model row
            HStack(spacing: 12) {
                if data.cost > 0 {
                    HStack(spacing: 4) {
                        Text("Cost:")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                        Text(formatCost(data.cost))
                            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronAmberLight)
                    }
                }

                if data.latency > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(TronTypography.sans(size: TronTypography.sizeXS))
                        Text(formatLatency(data.latency))
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    }
                    .foregroundStyle(.tronSlate)
                }

                if let model = data.model {
                    Text(model)
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted)
                }
            }

            // Tools used
            if !data.tools.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tools")
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted)

                    FlowLayout(spacing: 4) {
                        ForEach(data.tools, id: \.self) { tool in
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
            if !data.errors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Errors")
                        .font(TronTypography.pill)
                        .foregroundStyle(.tronTextMuted)

                    ForEach(data.errors, id: \.self) { error in
                        Text(error)
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronError)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(12)
        .sectionFill(.tronAmberLight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tokenStat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(TronTypography.pill)
                .foregroundStyle(.tronTextMuted)
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronAmberLight)
        }
    }

    // MARK: - Event Timeline

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Events")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            if turnGroup.events.isEmpty {
                Text("No events in this turn")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(turnGroup.events) { event in
                        EventRow(
                            event: event,
                            isHead: false,
                            isMuted: turnGroup.isInherited,
                            forkButtonState: forkButtonState(for: event),
                            onFork: { forkEventId = event.id }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Fork Button State

    private func forkButtonState(for event: SessionEvent) -> ForkButtonState {
        // Don't show fork buttons for inherited events
        if turnGroup.isInherited { return .hidden }
        // Don't show for events from other sessions
        if event.sessionId != sessionId { return .hidden }
        return event.isForkable ? .active : .disabled
    }

    // MARK: - Helpers

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}

/// Wrapper to make eventId identifiable for sheet presentation
private struct ForkEventItem: Identifiable {
    let eventId: String
    var id: String { eventId }
}
