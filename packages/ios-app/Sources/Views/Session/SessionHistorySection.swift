import SwiftUI

// MARK: - Session History Section

@available(iOS 26.0, *)
struct SessionHistorySection: View {
    let turnGroups: [TurnGroup]
    let onTurnSelected: (TurnGroup) -> Void

    /// Whether any turns are inherited (forked session)
    private var hasInheritedTurns: Bool {
        turnGroups.contains { $0.isInherited }
    }

    /// Inherited turns (from parent session)
    private var inheritedTurns: [TurnGroup] {
        turnGroups.filter { $0.isInherited }
    }

    /// Current session turns
    private var currentTurns: [TurnGroup] {
        turnGroups.filter { !$0.isInherited }
    }

    @State private var isInheritedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                Text("Turn-by-turn session activity")
                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextDisabled)
            }

            if turnGroups.isEmpty {
                emptyState
            } else if hasInheritedTurns {
                forkedSessionContent
            } else {
                linearSessionContent
            }
        }
    }

    // MARK: - Forked Session Content

    @ViewBuilder
    private var forkedSessionContent: some View {
        // Inherited turns (collapsible)
        inheritedTurnsSection

        // Fork point indicator
        ForkPointIndicator()

        // Current session turns
        if currentTurns.isEmpty {
            VStack(spacing: 8) {
                Text("No new turns since fork")
                    .font(TronTypography.mono(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            ForEach(currentTurns) { turn in
                turnRow(turn)
            }
        }
    }

    // MARK: - Inherited Turns (Collapsible)

    private var inheritedTurnsSection: some View {
        VStack(spacing: 0) {
            // Header
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

            // Expanded content
            if isInheritedExpanded {
                VStack(spacing: 4) {
                    ForEach(inheritedTurns) { turn in
                        turnRow(turn, muted: true)
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

    // MARK: - Linear Session Content

    private var linearSessionContent: some View {
        ForEach(turnGroups) { turn in
            turnRow(turn)
        }
    }

    // MARK: - Turn Row

    private func turnRow(_ turn: TurnGroup, muted: Bool = false) -> some View {
        Button {
            onTurnSelected(turn)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Line 1: Turn badge + role icon + message preview
                HStack(spacing: 8) {
                    // Turn number badge
                    Text(turn.turnNumber == 0 ? "S" : "\(turn.turnNumber)")
                        .font(TronTypography.mono(size: TronTypography.sizeBody2, weight: .bold))
                        .foregroundStyle(muted ? .tronTextMuted : .tronAmberLight)
                        .frame(width: 24, height: 24)
                        .background((muted ? Color.tronTextMuted : Color.tronAmberLight).opacity(0.2))
                        .clipShape(Circle())

                    // Role icon (user vs assistant)
                    if turn.turnNumber > 0 && !muted {
                        Image(systemName: turn.startsWithUserMessage ? "person.fill" : "cpu")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(turn.startsWithUserMessage ? .tronBlue : .tronEmerald)
                    }

                    // Message preview or fallback
                    Text(turn.displayPreview ?? (turn.turnNumber == 0 ? "Session events" : "Agent activity"))
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(muted ? .tronTextMuted : .tronTextPrimary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                }

                // Line 2: Stats pills
                if let data = turn.analyticsData {
                    HStack(spacing: 8) {
                        if data.toolCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "hammer.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeXS))
                                Text("\(data.toolCount)")
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            }
                            .foregroundStyle(muted ? .tronTextMuted : .tronCyan)
                        }

                        HStack(spacing: 3) {
                            Image(systemName: "number")
                                .font(TronTypography.sans(size: TronTypography.sizeXS))
                            Text(TokenFormatter.format(data.totalTokens))
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        }
                        .foregroundStyle(muted ? .tronTextMuted : .tronAmberLight)

                        if data.cost > 0 {
                            Text(formatCost(data.cost))
                                .font(TronTypography.mono(size: TronTypography.sizeCaption))
                                .foregroundStyle(muted ? .tronTextMuted : .tronAmberLight)
                        }

                        if data.latency > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .font(TronTypography.sans(size: TronTypography.sizeXS))
                                Text(formatLatency(data.latency))
                                    .font(TronTypography.mono(size: TronTypography.sizeCaption))
                            }
                            .foregroundStyle(muted ? .tronTextMuted : .tronSlate)
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
                    .padding(.leading, 32) // Align with text after badge
                }
            }
            .padding(10)
            .sectionFill(muted ? .tronSlate : .tronAmberLight, cornerRadius: 10, subtle: true)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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

    // MARK: - Helpers

    private func formatLatency(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return String(format: "%.1fs", Double(ms) / 1000.0)
    }
}
