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
        "Turn \(turnGroup.turnNumber)"
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: turnTitle,
            iconName: "number.circle",
            accent: .tronAmberLight
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Analytics summary
                    if let data = turnGroup.analyticsData {
                        turnAnalyticsSummary(data)
                            .sheetSection()
                    }

                    // Events
                    processedEventsView
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
        let breakdown = ConsolidatedAnalytics.turnCostBreakdown(for: data)

        VStack(spacing: 10) {
            // Totals header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TokenFormatter.format(data.totalTokens))
                        .font(TronTypography.mono(size: TronTypography.sizeBodyLG, weight: .bold))
                        .foregroundStyle(.tronAmberLight)
                    Text("tokens")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatCost(data.cost))
                        .font(TronTypography.mono(size: TronTypography.sizeBodyLG, weight: .bold))
                        .foregroundStyle(.tronAmber)
                    Text("cost")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            // Token/cost pills — single row
            HStack(spacing: 6) {
                analyticsPill(label: "In", tokens: data.inputTokens, cost: breakdown.inputCost)
                analyticsPill(label: "Out", tokens: data.outputTokens, cost: breakdown.outputCost)
                if data.cacheReadTokens > 0 {
                    analyticsPill(label: "Cache↓", tokens: data.cacheReadTokens, cost: breakdown.cacheReadCost)
                }
                if data.cacheCreationTokens > 0 {
                    analyticsPill(label: "Cache↑", tokens: data.cacheCreationTokens, cost: breakdown.cacheWriteCost)
                }
            }

            // Stats row
            HStack(spacing: 0) {
                if data.latency > 0 {
                    statItem(value: formatLatency(data.latency), label: "latency")
                }
                if let model = data.model {
                    statItem(value: model, label: "model")
                }
                if data.toolCount > 0 {
                    statItem(value: "\(data.toolCount)", label: "tools")
                }
                if data.errorCount > 0 {
                    statItem(value: "\(data.errorCount)", label: "errors", color: .tronError)
                }
            }

            // Tool names
            if !data.tools.isEmpty {
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
        .padding(12)
        .sectionFill(.tronAmberLight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func analyticsPill(label: String, tokens: Int, cost: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(TronTypography.mono(size: TronTypography.sizeXS))
                .foregroundStyle(.tronTextMuted)
            HStack {
                Text(TokenFormatter.format(tokens))
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronAmberLight)
                Spacer()
                Text(formatCost(cost))
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronAmber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .sectionFill(.tronAmberLight, cornerRadius: 8, subtle: true, compact: false)
    }

    private func statItem(value: String, label: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(color ?? .tronAmberLight.opacity(0.8))
            Text(label)
                .font(TronTypography.pill)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Processed Events

    /// Events split into main events and post-turn events, with tool call/result merging
    private var processedEventsView: some View {
        let (mainItems, postTurnItems) = processEvents()

        return VStack(alignment: .leading, spacing: 8) {
            Text("Events")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(.tronTextSecondary)

            if mainItems.isEmpty && postTurnItems.isEmpty {
                Text("No events in this turn")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(mainItems) { item in
                        processedEventRow(item)
                    }
                }

                if !postTurnItems.isEmpty {
                    // Post-turn divider
                    HStack(spacing: 8) {
                        Rectangle()
                            .fill(Color.tronTextMuted.opacity(0.2))
                            .frame(height: 1)
                        Text("Post-turn")
                            .font(TronTypography.mono(size: TronTypography.sizeXS, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                        Rectangle()
                            .fill(Color.tronTextMuted.opacity(0.2))
                            .frame(height: 1)
                    }
                    .padding(.vertical, 4)

                    LazyVStack(spacing: 2) {
                        ForEach(postTurnItems) { item in
                            processedEventRow(item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func processedEventRow(_ item: ProcessedEventItem) -> some View {
        switch item.kind {
        case .single(let event):
            EventRow(
                event: event,
                isHead: false,
                isMuted: turnGroup.isInherited,
                forkButtonState: forkButtonState(for: event),
                onFork: { forkEventId = event.id }
            )

        case .mergedTool(let call, let result):
            mergedToolRow(call: call, result: result)
        }
    }

    // MARK: - Merged Tool Row

    @available(iOS 26.0, *)
    private func mergedToolRow(call: SessionEvent, result: SessionEvent?) -> some View {
        let toolName = call.payload.string("name") ?? "unknown"
        let args = call.payload.dict("arguments") ?? [:]
        let keyArg = call.extractKeyArgument(toolName: toolName, from: args)
        let isError = result?.payload.bool("isError") ?? false
        let duration = result?.payload.int("duration")

        let displayName = keyArg.isEmpty ? toolName : "\(toolName): \(keyArg)"
        let statusIcon = isError ? "xmark.circle.fill" : "checkmark.circle.fill"
        let statusColor: Color = isError ? .tronError : .tronSuccess

        return HStack(spacing: 10) {
            // Tool icon
            Image(systemName: "wrench.and.screwdriver")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronCyan)
                .frame(width: 20)

            // Tool name + key arg
            Text(displayName)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)

            Spacer()

            // Status + duration
            if let result {
                HStack(spacing: 4) {
                    if let duration {
                        Text("\(duration)ms")
                            .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    Image(systemName: statusIcon)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(statusColor)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.tronCyan)
            }

            // Fork button (on the call event)
            if case .active = forkButtonState(for: call) {
                Button(action: { forkEventId = call.id }) {
                    Text("Fork")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronAmber)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.tronAmber.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    // MARK: - Event Processing

    /// Process events into merged tool rows and separate post-turn events
    private func processEvents() -> (main: [ProcessedEventItem], postTurn: [ProcessedEventItem]) {
        let events = turnGroup.events

        // Find the index of the last assistant message
        let lastAssistantIndex = events.lastIndex(where: { $0.eventType == .messageAssistant })

        // Find the last tool result after the last assistant message (or the assistant itself)
        let lastMainIndex: Int
        if let lai = lastAssistantIndex {
            // Check if there are tool results after this assistant message
            let afterAssistant = events[lai...]
            if let lastToolResult = afterAssistant.lastIndex(where: { $0.eventType == .toolResult }) {
                lastMainIndex = lastToolResult
            } else {
                lastMainIndex = lai
            }
        } else {
            lastMainIndex = events.count - 1
        }

        // Split events into main and post-turn
        let mainEvents = lastMainIndex < events.count ? Array(events[...lastMainIndex]) : events
        let postTurnEvents = lastMainIndex + 1 < events.count ? Array(events[(lastMainIndex + 1)...]) : []

        // Post-turn event types that should be shown (exclude noise)
        let postTurnTypes: Set<SessionEventType> = [
            .configModelSwitch, .configPromptUpdate, .configReasoningLevel,
            .llmHookResult, .worktreeAcquired, .worktreeCommit, .worktreeReleased,
            .worktreeMerged, .worktreeRenamed, .skillActivated, .skillDeactivated,
            .memoryRetained, .rulesLoaded, .rulesActivated
        ]

        let filteredPostTurn = postTurnEvents.filter { postTurnTypes.contains($0.eventType) }

        // Process main events — merge tool.call + tool.result pairs
        var mainItems: [ProcessedEventItem] = []
        var consumedResultIds = Set<String>()

        // Build a map of toolCallId → tool.result event
        var resultByCallId: [String: SessionEvent] = [:]
        for event in mainEvents where event.eventType == .toolResult {
            if let callId = event.payload.string("toolCallId") {
                resultByCallId[callId] = event
            }
        }

        for event in mainEvents {
            if event.eventType == .toolResult {
                // Skip tool results — they're merged into tool calls
                continue
            }

            if event.eventType == .toolCall {
                let callId = event.payload.string("toolCallId") ?? event.id
                let result = resultByCallId[callId]
                if let result { consumedResultIds.insert(result.id) }
                mainItems.append(ProcessedEventItem(kind: .mergedTool(call: event, result: result)))
            } else {
                mainItems.append(ProcessedEventItem(kind: .single(event)))
            }
        }

        // Post-turn items are always single events
        let postTurnItems = filteredPostTurn.map { ProcessedEventItem(kind: .single($0)) }

        return (mainItems, postTurnItems)
    }

    // MARK: - Fork Button State

    private func forkButtonState(for event: SessionEvent) -> ForkButtonState {
        if turnGroup.isInherited { return .hidden }
        if event.sessionId != sessionId { return .hidden }
        return event.isForkable ? .active : .hidden
    }

    // MARK: - Helpers

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}

// MARK: - Processed Event Item

/// Represents either a single event or a merged tool call+result pair
struct ProcessedEventItem: Identifiable {
    enum Kind {
        case single(SessionEvent)
        case mergedTool(call: SessionEvent, result: SessionEvent?)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .single(let event): return event.id
        case .mergedTool(let call, _): return "tool-\(call.id)"
        }
    }
}

/// Wrapper to make eventId identifiable for sheet presentation
private struct ForkEventItem: Identifiable {
    let eventId: String
    var id: String { eventId }
}
