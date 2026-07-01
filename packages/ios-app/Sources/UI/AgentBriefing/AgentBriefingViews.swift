import SwiftUI

struct AgentBriefingDashboardBand: View {
    let state: AgentBriefingLoadState
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(2)
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(3)
                    metricLine
                }

                Spacer(minLength: 8)

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(.tronTextMuted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(accent, cornerRadius: 12, subtle: true, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agent-briefing-dashboard-band")
        .accessibilityLabel("Agent Briefing")
    }

    @ViewBuilder
    private var metricLine: some View {
        if let overview = state.overview {
            HStack(spacing: 8) {
                briefingMetric("Active", overview.summary.activeWorkCount)
                briefingMetric("Needs you", overview.summary.needsYouCount)
                briefingMetric("Weak", overview.summary.weakPointCount)
            }
        }
    }

    private func briefingMetric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(accent)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.82)
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

struct AgentBriefingSheet: View {
    @Bindable var viewModel: AgentBriefingViewModel
    let repository: any WorkerLifecycleRepository
    let sessionId: String?
    let workspaceId: String?
    let connectionState: ConnectionState

    @State private var selectedItem: AgentBriefingItemDTO?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    sections
                    diagnosticsNote
                }
                .padding(18)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SheetPrimaryActionButton(
                        icon: "arrow.clockwise",
                        accent: .tronEmerald,
                        isBusy: viewModel.isRefreshing,
                        accessibilityLabel: "Refresh agent briefing"
                    ) {
                        Task { await refresh() }
                    }
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "Agent Briefing", color: .tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: .tronEmerald)
                }
            }
            .task {
                await refresh()
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(.tronEmerald)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: headerIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                    .foregroundStyle(headerAccent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headerTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                    Text(headerDetail)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(.tronTextSecondary)
                }
                Spacer(minLength: 8)
            }
            if let overview = viewModel.state.overview {
                HStack(spacing: 8) {
                    headerMetric("Active", overview.summary.activeWorkCount, .tronCyan)
                    headerMetric("Needs you", overview.summary.needsYouCount, .tronWarning)
                    headerMetric("Weak", overview.summary.weakPointCount, .tronError)
                }
            }
        }
        .padding(14)
        .sectionFill(headerAccent, cornerRadius: 12, interactive: false)
    }

    @ViewBuilder
    private var sections: some View {
        if let overview = viewModel.state.overview {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(overview.sections) { section in
                    AgentBriefingSectionView(section: section, selectedItem: $selectedItem)
                }
            }
        } else if case .loading = viewModel.state {
            AgentBriefingEmptyState(icon: "clock", title: "Loading", detail: "Reading scoped server evidence.")
        } else {
            AgentBriefingEmptyState(icon: "exclamationmark.triangle", title: "No briefing", detail: headerDetail)
        }
    }

    private var diagnosticsNote: some View {
        Label("Deep diagnostics remain in Servers when operator-level details are needed.", systemImage: "stethoscope")
            .font(TronTypography.sans(size: TronTypography.sizeCaption))
            .foregroundStyle(.tronTextMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headerMetric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(color)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: String {
        switch viewModel.state {
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

    private var headerDetail: String {
        switch viewModel.state {
        case .unavailable:
            "Connect to a server and open a session to scope the briefing."
        case .loading:
            "Reading scoped module activity and policy evidence."
        case .loaded(let overview):
            overview.summary.detail
        case .degraded(let message):
            message
        }
    }

    private var headerIcon: String {
        if let overview = viewModel.state.overview, overview.summary.degraded { return "exclamationmark.triangle" }
        if case .degraded = viewModel.state { return "exclamationmark.triangle" }
        return "person.text.rectangle"
    }

    private var headerAccent: Color {
        if let overview = viewModel.state.overview, overview.summary.degraded { return .tronWarning }
        if case .degraded = viewModel.state { return .tronWarning }
        return .tronEmerald
    }

    private func refresh() async {
        await viewModel.refresh(
            repository: repository,
            sessionId: sessionId,
            workspaceId: workspaceId,
            connectionState: connectionState
        )
    }
}

private struct AgentBriefingSectionView: View {
    let section: AgentBriefingSectionDTO
    @Binding var selectedItem: AgentBriefingItemDTO?

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(section.narrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronTextSecondary)
                if section.items.isEmpty {
                    AgentBriefingEmptyState(icon: "checkmark.circle", title: "Clear", detail: section.emptyState)
                } else {
                    ForEach(section.items) { item in
                        Button {
                            selectedItem = selectedItem?.id == item.id ? nil : item
                        } label: {
                            AgentBriefingItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                        if selectedItem?.id == item.id {
                            AgentBriefingEvidenceView(item: item)
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(section.question)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(13)
        .sectionFill(.tronEmerald, cornerRadius: 12, subtle: true, interactive: true)
    }
}

private struct AgentBriefingItemRow: View {
    let item: AgentBriefingItemDTO

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2)
                Text(item.detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 8)
            Image(systemName: "info.circle")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(item.title)
    }

    private var tone: AgentBriefingStatusTone {
        AgentBriefingStatusTone(item.status)
    }

    private var icon: String {
        switch tone {
        case .active: return "play.circle.fill"
        case .waiting: return "hourglass.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .recorded: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .active: return .tronCyan
        case .waiting: return .tronWarning
        case .blocked: return .tronError
        case .recorded: return .tronEmerald
        }
    }
}

private struct AgentBriefingEvidenceView: View {
    let item: AgentBriefingItemDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentBriefingEvidenceLine(label: "Evidence", value: item.evidence?.label ?? "Provider-safe metadata")
            AgentBriefingEvidenceLine(label: "Kind", value: item.evidence?.resourceKind ?? "module_resource")
            AgentBriefingEvidenceLine(label: "Updated", value: item.evidence?.updatedAt ?? "unknown")
            AgentBriefingEvidenceLine(label: "Policy", value: item.evidence?.providerSafe == false ? "Needs review" : "Provider-safe")
        }
        .padding(10)
        .sectionFill(.tronEmerald, cornerRadius: 8, subtle: true, interactive: false)
        .accessibilityIdentifier("agent-briefing-evidence-detail")
    }
}

private struct AgentBriefingEvidenceLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(TronTypography.codeCaption)
                .foregroundStyle(.tronTextMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct AgentBriefingEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(detail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tronTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
