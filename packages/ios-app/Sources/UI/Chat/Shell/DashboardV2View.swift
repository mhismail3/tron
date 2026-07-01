import SwiftUI

struct DashboardV2View: View {
    @Environment(\.dependencies) private var dependencies
    @Environment(\.interactionPolicy) private var interactionPolicy
    @Binding var selectedSessionId: String?
    @Binding var surfaceMode: DashboardSurfaceMode
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let actions: ShellToolbarActions

    @State private var workspaceExpansion = SessionListWorkspaceExpansion()
    @State private var agentBriefing = AgentBriefingViewModel()
    @State private var showAgentBriefing = false
    @State private var isLabPresented = false
    @State private var labDetent: DashboardV2LabDetent = .compact

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }

    private var workspaceGroups: [SessionListWorkspaceGroup] {
        SessionListWorkspaceGroup.groups(from: eventStoreManager.sortedSessions)
    }

    private var briefingSessionId: String? {
        selectedSessionId ?? eventStoreManager.sortedSessions.first?.id
    }

    private var briefingRefreshKey: DashboardV2BriefingRefreshKey {
        DashboardV2BriefingRefreshKey(
            sessionId: briefingSessionId,
            isConnected: dependencies.connectionRepository.connectionState.isConnected
        )
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    DashboardV2AgentBriefingCard(
                        state: agentBriefing.state,
                        isRefreshing: agentBriefing.isRefreshing
                    ) {
                        showAgentBriefing = true
                    }

                    sessionsSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 158)
                .padding(.bottom, 116)
            }
            .accessibilityIdentifier("dashboard-v2-surface")

            DashboardV2FloatingActions(
                canCreate: interactionPolicy?.canCreateSession ?? false,
                onOpenLab: {
                    labDetent = .compact
                    isLabPresented = true
                },
                onNewSession: onNewSession
            )
            .padding(.trailing, 20)
            .padding(.bottom, 10)

            DashboardV2TopBar(
                surfaceMode: $surfaceMode,
                onOpenLab: {
                    labDetent = .compact
                    isLabPresented = true
                },
                onSettings: actions.onSettings
            )

            if isLabPresented {
                DashboardV2LabOverlay(
                    detent: $labDetent,
                    onClose: {
                        isLabPresented = false
                    }
                )
                .zIndex(20)
            }
        }
        .tronScreenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: briefingRefreshKey) {
            await refreshBriefing()
        }
        .sheet(isPresented: $showAgentBriefing) {
            AgentBriefingSheet(
                viewModel: agentBriefing,
                repository: dependencies.workerLifecycleRepository,
                sessionId: briefingSessionId,
                workspaceId: nil,
                connectionState: dependencies.connectionRepository.connectionState
            )
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronEmerald)
                    .accessibilityHidden(true)
                Text("Sessions")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.tronTextPrimary)
                Spacer()
                Text("\(eventStoreManager.sortedSessions.count)")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .dashboardV2GlassSurface(cornerRadius: 14)
            }
            .padding(.horizontal, 2)

            ForEach(workspaceGroups) { group in
                DashboardV2WorkspaceGroupView(
                    group: group,
                    isExpanded: workspaceExpansion.isExpanded(group.id),
                    selectedSessionId: selectedSessionId,
                    onToggle: {
                        withAnimation(SessionListLayout.expansionAnimation) {
                            workspaceExpansion.toggle(group.id)
                        }
                    },
                    onSelect: { session in
                        selectedSessionId = session.id
                    }
                )
            }
        }
    }

    private func refreshBriefing() async {
        await agentBriefing.refresh(
            repository: dependencies.workerLifecycleRepository,
            sessionId: briefingSessionId,
            workspaceId: nil,
            connectionState: dependencies.connectionRepository.connectionState
        )
    }
}

private struct DashboardV2BriefingRefreshKey: Equatable {
    let sessionId: String?
    let isConnected: Bool
}

private struct DashboardV2TopBar: View {
    @Binding var surfaceMode: DashboardSurfaceMode
    let onOpenLab: () -> Void
    let onSettings: () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 12) {
                DashboardModeSelectorButton(
                    selectedMode: $surfaceMode,
                    size: 44,
                    accent: .tronEmerald
                )

                Spacer(minLength: 12)

                Text("Tron")
                    .font(TronTypography.sans(size: 22, weight: .bold))
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)
                    .accessibilityIdentifier("dashboard-v2-title")

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    DashboardV2IconButton(
                        systemImage: "testtube.2",
                        accessibilityLabel: "Open component lab",
                        accessibilityIdentifier: "dashboard-v2-open-lab",
                        size: 44,
                        symbolSize: 19,
                        action: onOpenLab
                    )

                    DashboardV2IconButton(
                        systemImage: "gearshape",
                        accessibilityLabel: "Settings",
                        accessibilityIdentifier: "dashboard-v2-settings",
                        size: 44,
                        symbolSize: 20,
                        action: onSettings
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, proxy.safeAreaInsets.top + 42)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .ignoresSafeArea()
        .allowsHitTesting(true)
    }
}

private struct DashboardV2FloatingActions: View {
    let canCreate: Bool
    let onOpenLab: () -> Void
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            DashboardV2IconButton(
                systemImage: "sparkles",
                accessibilityLabel: "Open component lab",
                accessibilityIdentifier: "dashboard-v2-floating-lab",
                size: 44,
                symbolSize: 19,
                accent: .tronCyan,
                action: onOpenLab
            )

            DashboardV2IconButton(
                systemImage: "plus",
                accessibilityLabel: FloatingNewSessionButtonAccessibility.label,
                accessibilityIdentifier: "dashboard-v2-new-session",
                size: 50,
                symbolSize: 24,
                accent: .tronEmerald,
                isEnabled: canCreate,
                action: onNewSession
            )
            .accessibilityHint(FloatingNewSessionButtonAccessibility.hint)
        }
    }
}

private struct DashboardV2AgentBriefingCard: View {
    let state: AgentBriefingLoadState
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                            .foregroundStyle(.tronTextPrimary)
                            .lineLimit(2)
                        Text(detail)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(3)
                    }

                    Spacer(minLength: 8)

                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accent)
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(.tronTextMuted)
                            .accessibilityHidden(true)
                    }
                }

                metricLine
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .dashboardV2GlassSurface(
            cornerRadius: 24,
            tint: accent.opacity(0.14),
            strokeOpacity: 0.16
        )
        .accessibilityIdentifier("dashboard-v2-agent-briefing-card")
        .accessibilityLabel("Agent Briefing")
    }

    @ViewBuilder
    private var metricLine: some View {
        if let overview = state.overview {
            HStack(spacing: 8) {
                metric("Active", overview.summary.activeWorkCount, .tronCyan)
                metric("Needs you", overview.summary.needsYouCount, .tronWarning)
                metric("Weak", overview.summary.weakPointCount, .tronError)
            }
        }
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var title: String {
        switch state {
        case .unavailable:
            "Agent Briefing"
        case .loading:
            "Preparing briefing"
        case .loaded(let overview):
            overview.summary.title
        case .degraded:
            "Briefing unavailable"
        }
    }

    private var detail: String {
        switch state {
        case .unavailable:
            "Connect to the server to read scoped activity."
        case .loading:
            "Reading server-owned activity evidence."
        case .loaded(let overview):
            overview.summary.detail
        case .degraded(let message):
            message
        }
    }

    private var icon: String {
        if let overview = state.overview, overview.summary.degraded { return "exclamationmark.triangle" }
        switch state {
        case .unavailable: return "antenna.radiowaves.left.and.right.slash"
        case .loading: return "clock"
        case .loaded: return "person.text.rectangle"
        case .degraded: return "exclamationmark.triangle"
        }
    }

    private var accent: Color {
        if let overview = state.overview, overview.summary.degraded { return .tronWarning }
        if case .degraded = state { return .tronWarning }
        return .tronEmerald
    }
}

private struct DashboardV2WorkspaceGroupView: View {
    let group: SessionListWorkspaceGroup
    let isExpanded: Bool
    let selectedSessionId: String?
    let onToggle: () -> Void
    let onSelect: (CachedSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 9) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)

                    Text(group.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .bold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)

                    Spacer()
                }
                .padding(.horizontal, 2)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.name)
            .accessibilityValue(isExpanded ? "expanded" : "collapsed")

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(group.sessions) { session in
                        DashboardV2SessionRow(
                            session: session,
                            isSelected: session.id == selectedSessionId
                        ) {
                            onSelect(session)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct DashboardV2SessionRow: View {
    let session: CachedSession
    let isSelected: Bool
    let action: () -> Void

    private var status: SessionListStatus {
        SessionListStatus(session: session)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: status.symbolName)
                    .font(TronTypography.sans(size: 16, weight: .semibold))
                    .foregroundStyle(status.color)
                    .frame(width: 22, height: 22)
                    .accessibilityHidden(true)

                Text(session.listTitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Text(session.compactDate)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .dashboardV2GlassSurface(
            cornerRadius: 18,
            tint: Color.tronEmerald.opacity(isSelected ? 0.20 : 0.12),
            strokeOpacity: isSelected ? 0.20 : 0.11
        )
        .accessibilityLabel("\(session.listTitle), \(status.accessibilityLabel), last active \(session.formattedDate)")
        .opacity(session.isDeleting ? SessionListLayout.deletingRowOpacity : 1.0)
        .allowsHitTesting(!session.isDeleting)
    }
}
