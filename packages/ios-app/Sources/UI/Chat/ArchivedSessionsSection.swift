import SwiftUI

/// The dashboard's archived container: one collapsed row after every workspace
/// group, plus the pages its owner published when expanded. Archived sessions
/// are hidden from the workspace groups and from the automation picker, so this
/// section is their only dashboard surface.
struct ArchivedSessionsSectionHeader: View {
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
                Image(systemName: isExpanded ? "archivebox.fill" : "archivebox")
                    .font(TronTypography.sans(size: SessionDashboardLayout.headerIconSize, weight: .semibold))
                    .frame(width: SessionDashboardLayout.iconColumnWidth, height: SessionDashboardLayout.iconColumnWidth)
                    .contentTransition(.symbolEffect(.replace))
                Text("Archived (\(count))")
                    .font(TronTypography.code(size: TronTypography.sizeBodyLG, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: SessionDashboardLayout.iconTextSpacing)
                TronDisclosureChevron(isExpanded: isExpanded, size: SessionDashboardLayout.headerChevronSize)
            }
            .foregroundStyle(Color.tronEmerald)
            .padding(.leading, SessionDashboardLayout.headerLeadingPadding)
            .padding(.trailing, SessionDashboardLayout.rowContainerHorizontalInset)
            .padding(.top, SessionDashboardLayout.headerTopPadding)
            .padding(.bottom, SessionDashboardLayout.headerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(TronDisclosureLayout.expansionAnimation, value: isExpanded)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .listRowInsets(SessionDashboardLayout.headerInsets)
        .accessibilityIdentifier("archived-sessions-container")
        .accessibilityLabel("Archived")
        .accessibilityValue("\(count)")
        .accessibilityHint(isExpanded ? "Double tap to hide archived sessions" : "Double tap to show archived sessions")
    }
}

/// Rows of one expanded archived container. Rows show their workspace and open
/// the session; Unarchive is the full-swipe action and Delete keeps the
/// dashboard's confirmation. A server whose pages cannot be shown is named
/// inline instead of leaving a silent gap.
struct ArchivedSessionsSectionRows: View {
    let sessions: [SessionSummary]
    let unavailableServerNames: [String]
    let isLoading: Bool
    let hasMore: Bool
    let onOpen: (SessionSummary) -> Void
    let onUnarchive: (SessionSummary) -> Void
    let onDelete: (SessionSummary) -> Void
    let onShowMore: () -> Void

    var body: some View {
        if isLoading && sessions.isEmpty {
            loadingRow
        }
        ForEach(sessions, id: \.dashboardID) { session in
            archivedRow(session)
        }
        ForEach(unavailableServerNames, id: \.self) { name in
            unavailableRow(name)
        }
        if hasMore {
            SessionListExpansionControls(
                workspaceName: "Archived",
                canShowLess: false,
                canShowMore: true,
                isEnabled: !isLoading,
                onShowLess: {},
                onShowMore: onShowMore
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(SessionDashboardLayout.rowInsets)
        }
    }

    private func archivedRow(_ session: SessionSummary) -> some View {
        Button {
            onOpen(session)
        } label: {
            HistoricalSessionRow(session: session, activity: .idle, showsContext: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("archived-session-row-\(session.dashboardID)")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.rowInsets)
        .transition(.opacity)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Unarchive is reversible, so it is the full-swipe action; Delete
            // keeps the dashboard's confirmation.
            Button("Unarchive", systemImage: "arrow.uturn.backward") { onUnarchive(session) }
                .tint(Color.gray)
                .accessibilityIdentifier("session-unarchive-action-\(session.dashboardID)")
            Button("Delete", systemImage: "trash") { onDelete(session) }
                .tint(Color.tronError)
                .accessibilityIdentifier("session-delete-action-\(session.dashboardID)")
        }
    }

    private var loadingRow: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            ProgressView().tint(.tronEmerald)
            Text("Loading archived sessions…")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(Color.tronTextMuted)
        }
        .padding(.horizontal, SessionDashboardLayout.headerLeadingPadding)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.headerInsets)
    }

    private func unavailableRow(_ name: String) -> some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            Image(systemName: "exclamationmark.circle")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .accessibilityHidden(true)
            Text("Archived sessions unavailable on \(name)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.tronAmber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SessionDashboardLayout.headerLeadingPadding)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(SessionDashboardLayout.headerInsets)
    }
}
