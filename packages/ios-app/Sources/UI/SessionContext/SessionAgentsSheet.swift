import SwiftUI

/// Session-scoped directory for nested and contacted agents. The parent sheet
/// owns paging and retains its last authoritative snapshot; detail sheets own
/// their own independently refreshable projections.
struct SessionAgentsSheet: View {
    let ownerSessionId: String
    let agents: [AgentRelationDTO]
    let totals: AgentRelationTotalsDTO?
    let nextCursor: String?
    let isLoading: Bool
    let hasLoadedSnapshot: Bool
    let loadError: String?
    let isSupported: Bool
    let repository: any AgentRepository
    let workerRepository: any WorkerKernelRepository
    let isConnected: Bool
    let onRetry: () -> Void
    let onLoadOlder: () -> Void
    let onProjectionChanged: () -> Void

    @State private var selectedAgent: AgentRelationDTO?

    private var children: [AgentRelationDTO] {
        SessionAgentsPresentation.orderedChildren(agents)
    }

    private var contacts: [AgentRelationDTO] {
        SessionAgentsPresentation.orderedContacts(agents)
    }

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let loadError {
                        retryCard(loadError)
                    }

                    if agents.isEmpty {
                        emptyState
                    } else {
                        if !children.isEmpty {
                            agentGroup(
                                title: "Child agents",
                                detail: "Nested agents owned by this session, shown with their descendants."
                            ) {
                                ForEach(children) { agent in
                                    AgentRelationRow(agent: agent) {
                                        selectedAgent = agent
                                    }
                                    .padding(.leading, min(CGFloat(agent.depth) * 14, 42))
                                }
                            }
                        }

                        if !contacts.isEmpty {
                            agentGroup(
                                title: "Other agents",
                                detail: "Parents, promoted agents, managed agents, and durable conversation contacts."
                            ) {
                                ForEach(contacts) { agent in
                                    AgentRelationRow(agent: agent) {
                                        selectedAgent = agent
                                    }
                                }
                            }
                        }
                    }

                    if nextCursor != nil, !isLoading {
                        Button(action: onLoadOlder) {
                            Label("Load older relationships", systemImage: "clock.arrow.circlepath")
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeCaption,
                                    weight: .semibold
                                ))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: true)
                    } else if isLoading, !agents.isEmpty {
                        SheetLoadingState(label: "Loading older relationships…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .containerRelativeFrame(.horizontal)
                .clipped()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Agents", color: .tronPurple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronPurple)
                }
            }
        }
        .workerConsoleSheetPresentation()
        .tint(.tronPurple)
        .sheet(item: $selectedAgent) { agent in
            AgentDetailSheet(
                ownerSessionId: ownerSessionId,
                relation: agent,
                repository: repository,
                workerRepository: workerRepository,
                isConnected: isConnected,
                onProjectionChanged: onProjectionChanged
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isSupported {
            Label(
                "Reusable agent management requires a newer Tron server. Existing session and worker controls remain available.",
                systemImage: "person.3.sequence"
            )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
        } else if isLoading, !hasLoadedSnapshot {
            SheetLoadingState(label: "Loading child agents and conversations…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else {
            Label(
                "No child agents or agent conversations.",
                systemImage: "person.3.sequence"
            )
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sectionFill(.tronPurple, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private func agentGroup<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        WorkerConsoleGroup(title: title, detail: detail, content: content)
    }

    private func retryCard(_ message: String) -> some View {
        Button(action: onRetry) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.tronError)
                VStack(alignment: .leading, spacing: 3) {
                    Text(hasLoadedSnapshot ? "Couldn’t refresh agents" : "Agent management unavailable")
                        .font(TronTypography.sans(
                            size: TronTypography.sizeBodySM,
                            weight: .semibold
                        ))
                    Text(message)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Retry").font(TronTypography.pillValue)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sectionFill(.tronError, cornerRadius: 12, subtle: true, interactive: true)
    }
}

private struct AgentRelationRow: View {
    let agent: AgentRelationDTO
    let action: () -> Void

    private var accent: Color {
        SessionAgentsPresentation.statusColor(agent.status)
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: SessionAgentsPresentation.statusSymbol(agent.status))
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(agent.name)
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(SessionAgentsPresentation.displayLabel(agent.status))
                            .font(TronTypography.pillValue)
                            .foregroundStyle(accent)
                    }

                    Text([
                        agent.role,
                        SessionAgentsPresentation.relationLabel(agent),
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)

                    if let task = agent.taskPreview, !task.isEmpty {
                        Text(task)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                    } else if let message = agent.lastMessagePreview, !message.isEmpty {
                        Text(message)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                    }

                    if let usage = SessionAgentsPresentation.usageSummary(
                        agent.subtreeUsage ?? agent.ownUsage
                    ) {
                        Text(usage)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: true)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens assignments, messages, transcript, results, and management")
    }
}
