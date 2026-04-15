import SwiftUI

// MARK: - History Sheet

/// Drill-down sheet for session history: turn list with expandable event details and fork capabilities.
@available(iOS 26.0, *)
struct HistorySheet: View {
    let turnGroups: [TurnGroup]
    let sessionId: String
    let eventStoreManager: EventStoreManager
    let onDismissParent: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var expandedTurns: Set<String> = []
    @State private var forkingEventId: String?
    @State private var forkError: String?

    /// Whether any turns are inherited (forked session)
    private var hasInheritedTurns: Bool {
        turnGroups.contains { $0.isInherited }
    }

    private var inheritedTurns: [TurnGroup] {
        turnGroups.filter { $0.isInherited }
    }

    private var currentTurns: [TurnGroup] {
        turnGroups.filter { !$0.isInherited }
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 8) {
                    if turnGroups.isEmpty {
                        emptyState
                    } else if hasInheritedTurns {
                        forkedContent
                    } else {
                        linearContent
                    }
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("History")
                        .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronCoral)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronCoral)
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { forkError != nil },
                set: { if !$0 { forkError = nil } }
            )) {
                Button("OK") { forkError = nil }
            } message: {
                Text(forkError ?? "")
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(.tronCoral)
    }

    // MARK: - Linear Content

    private var linearContent: some View {
        ForEach(turnGroups) { turn in
            turnCard(turn)
        }
    }

    // MARK: - Forked Content

    @ViewBuilder
    private var forkedContent: some View {
        // Inherited turns collapsible
        inheritedTurnsSection

        // Fork point
        ForkPointIndicator()

        // Current session turns
        if currentTurns.isEmpty {
            Text("No new turns since fork")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else {
            ForEach(currentTurns) { turn in
                turnCard(turn)
            }
        }
    }

    @State private var isInheritedExpanded = false

    private var inheritedTurnsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronPurple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Inherited Turns")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                    Text("\(inheritedTurns.count) turn\(inheritedTurns.count == 1 ? "" : "s")")
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.tronTextMuted)
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isInheritedExpanded ? -180 : 0))
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronPurple.opacity(0.25)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isInheritedExpanded.toggle()
                }
            }

            if isInheritedExpanded {
                LazyVStack(spacing: 4) {
                    ForEach(inheritedTurns) { turn in
                        turnCard(turn, muted: true)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .background(Color.tronOverlay(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }

    // MARK: - Turn Card

    private func turnCard(_ turn: TurnGroup, muted: Bool = false) -> some View {
        let isExpanded = expandedTurns.contains(turn.id)

        return VStack(spacing: 0) {
            // Header row
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if isExpanded {
                        expandedTurns.remove(turn.id)
                    } else {
                        expandedTurns.insert(turn.id)
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        // Turn number badge
                        Text("\(turn.turnNumber)")
                            .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .bold))
                            .foregroundStyle(muted ? .tronTextMuted : .tronCoral)
                            .frame(width: 24, height: 24)
                            .background((muted ? Color.tronTextMuted : Color.tronCoral).opacity(0.2))
                            .clipShape(Circle())

                        // Role icon
                        if !muted {
                            if turn.turnNumber == 0 {
                                Image(systemName: "rays")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronTextMuted)
                            } else {
                                Image(systemName: turn.startsWithUserMessage ? "person.fill" : "cpu")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(turn.startsWithUserMessage ? .tronBlue : .tronEmerald)
                            }
                        }

                        Text(turn.displayPreview ?? "Pre-session activity")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(muted ? .tronTextMuted : .tronTextPrimary)
                            .lineLimit(1)

                        Spacer()

                        Image(systemName: "chevron.down")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(.tronTextMuted)
                            .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    }

                    // Stats pills
                    if let data = turn.analyticsData {
                        HStack(spacing: 8) {
                            if data.latency > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock")
                                        .font(TronTypography.sans(size: TronTypography.sizeXS))
                                    Text(DurationFormatter.format(data.latency, style: .compact))
                                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                }
                                .foregroundStyle(muted ? .tronTextMuted : .tronSlate)
                            }

                            if data.toolCount > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "hammer.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeXS))
                                    Text("\(data.toolCount)")
                                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                }
                                .foregroundStyle(muted ? .tronTextMuted : .tronCyan)
                            }

                            if data.errorCount > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeXS))
                                    Text("\(data.errorCount)")
                                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                }
                                .foregroundStyle(.tronError)
                            }
                        }
                        .padding(.leading, 32)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)

            // Expanded events
            if isExpanded {
                eventsContent(for: turn)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .sectionFill(muted ? .tronSlate : .tronCoral, cornerRadius: 10, subtle: true, compact: false)
    }

    // MARK: - Events Content

    @ViewBuilder
    private func eventsContent(for turn: TurnGroup) -> some View {
        let (mainItems, postTurnItems) = processEventsForTurn(turn)

        VStack(alignment: .leading, spacing: 2) {
            Divider()
                .foregroundStyle(.tronTextMuted.opacity(0.15))
                .padding(.bottom, 4)

            if mainItems.isEmpty && postTurnItems.isEmpty {
                Text("No events in this turn")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(mainItems) { item in
                        processedEventRow(item, turn: turn)
                    }
                }

                if !postTurnItems.isEmpty {
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
                            processedEventRow(item, turn: turn)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func processedEventRow(_ item: ProcessedEventItem, turn: TurnGroup) -> some View {
        switch item.kind {
        case .single(let event):
            EventRow(
                event: event,
                isHead: false,
                isMuted: turn.isInherited,
                forkButtonState: forkButtonState(for: event, turn: turn),
                isForking: forkingEventId == event.id,
                isForkDisabled: forkingEventId != nil && forkingEventId != event.id,
                onFork: { await performFork(eventId: event.id) }
            )

        case .mergedTool(let call, let result):
            mergedToolRow(call: call, result: result, turn: turn)
        }
    }

    // MARK: - Merged Tool Row

    private func mergedToolRow(call: SessionEvent, result: SessionEvent?, turn: TurnGroup) -> some View {
        let toolName = call.payload.string("name") ?? "unknown"
        let args = call.payload.dict("arguments") ?? [:]
        let keyArg = call.extractKeyArgument(toolName: toolName, from: args)
        let isError = result?.payload.bool("isError") ?? false
        let duration = result?.payload.int("duration")

        let displayName = keyArg.isEmpty ? toolName : "\(toolName): \(keyArg)"
        let statusIcon = isError ? "xmark.circle.fill" : "checkmark.circle.fill"
        let statusColor: Color = isError ? .tronError : .tronSuccess

        return HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronCyan)
                .frame(width: 20)

            Text(displayName)
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)

            Spacer()

            if result != nil {
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

            if case .active = forkButtonState(for: call, turn: turn) {
                ForkButton(
                    isForking: forkingEventId == call.id,
                    isDisabled: forkingEventId != nil && forkingEventId != call.id,
                    onFork: { await performFork(eventId: call.id) }
                )
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    // MARK: - Fork

    private func forkButtonState(for event: SessionEvent, turn: TurnGroup) -> ForkButtonState {
        deriveForkButtonState(
            event: event,
            sessionId: sessionId,
            isInherited: turn.isInherited
        )
    }

    private func performFork(eventId: String) async {
        forkingEventId = eventId

        do {
            let newSessionId = try await eventStoreManager.forkSession(sessionId, fromEventId: eventId)
            eventStoreManager.setActiveSession(newSessionId)
            eventStoreManager.loadSessions()
            NotificationCenter.default.post(name: .switchToSession, object: newSessionId)
            dismiss()
            onDismissParent()
        } catch {
            forkError = "Failed to fork session: \(error.localizedDescription)"
        }
        forkingEventId = nil
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(TronTypography.sans(size: TronTypography.sizeDisplay))
                .foregroundStyle(.tronTextMuted)
            Text("No turns yet")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            Text("Events will appear as you chat")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

}
