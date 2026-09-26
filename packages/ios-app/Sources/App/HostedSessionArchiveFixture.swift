#if HOSTED_TEST
import SwiftUI

/// Hosted journey for the dashboard's archived container. It renders the real
/// archived section, the real row swipe actions, and the real container state
/// with fixture-owned session lists, so archiving, expanding, and unarchiving
/// can be exercised without a Gateway. Session membership is fixture input; the
/// surfaces and their identifiers are production code.
struct HostedSessionArchiveFixture: View {
    private static let profileID = "fixture"

    @State private var container = ArchivedSessionsContainerState()
    @State private var live: [SessionSummary] = [
        Self.session(id: "live-session", title: "Live session", archivedAt: nil),
    ]
    @State private var archived: [SessionSummary] = []

    private static func session(id: String, title: String, archivedAt: String?) -> SessionSummary {
        SessionSummary(
            id: id,
            name: title,
            cwd: "/workspace/fixture-project",
            parentSessionId: nil,
            createdAt: "2026-09-25T08:00:00Z",
            updatedAt: "2026-09-26T09:00:00Z",
            messageCount: 4,
            firstMessage: title,
            phase: .idle,
            archivedAt: archivedAt,
            gatewayProfileID: profileID,
            gatewayProfileLabel: "Fixture Mac"
        )
    }

    private var sources: [ArchivedSessionsProfileSource] {
        [ArchivedSessionsProfileSource(profileID: Self.profileID, label: "Fixture Mac", isConnected: true)]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(live, id: \.dashboardID) { session in
                        HistoricalSessionRow(session: session, activity: .idle, showsContext: true)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(SessionDashboardLayout.rowInsets)
                            .accessibilityIdentifier("session-row-\(session.dashboardID)")
                            .sessionRowTrailingSwipe(
                                session: session,
                                archiveIsAvailable: true,
                                onArchive: { archive(session) },
                                onDelete: {},
                                onRename: {}
                            )
                    }
                } header: {
                    Text("Fixture workspace")
                        .font(TronTypography.code(size: TronTypography.sizeBodyLG, weight: .bold))
                        .foregroundStyle(Color.tronEmerald)
                        .textCase(nil)
                        .listRowInsets(SessionDashboardLayout.headerInsets)
                }

                if !archived.isEmpty {
                    Section {
                        if container.isExpanded {
                            ArchivedSessionsSectionRows(
                                sessions: container.rows,
                                unavailableServerNames: [],
                                isLoading: container.isLoading,
                                hasMore: container.hasMore,
                                onOpen: { _ in },
                                onUnarchive: unarchive,
                                onDelete: { _ in },
                                onShowMore: {}
                            )
                        }
                    } header: {
                        ArchivedSessionsSectionHeader(
                            count: archived.count,
                            isExpanded: container.isExpanded,
                            onToggle: toggleContainer
                        )
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 38)
        }
    }

    private func archive(_ session: SessionSummary) {
        guard let index = live.firstIndex(where: { $0.dashboardID == session.dashboardID }) else { return }
        live.remove(at: index)
        archived.insert(
            Self.session(id: session.id, title: session.title, archivedAt: "2026-09-26T09:30:00Z"),
            at: 0
        )
        publishArchivePage()
    }

    private func unarchive(_ session: SessionSummary) {
        archived.removeAll { $0.dashboardID == session.dashboardID }
        live.append(Self.session(id: session.id, title: session.title, archivedAt: nil))
        container.remove(sessionID: session.id, profileID: session.gatewayProfileID)
        if archived.isEmpty { container.collapse() }
    }

    private func toggleContainer() {
        if container.isExpanded {
            container.collapse()
            return
        }
        container.expand()
        publishArchivePage()
    }

    private func publishArchivePage() {
        container.reconcile(sources)
        guard container.isExpanded else { return }
        Task { @MainActor in
            let page = ArchivedSessionsLoader.PageResponse(sessions: archived, nextCursor: nil)
            let result = await ArchivedSessionsLoader.admit(page, requestedCursor: nil) { true }
            container.apply(result, profileID: Self.profileID, generation: container.currentGeneration)
        }
    }
}
#endif
