#if HOSTED_TEST
import SwiftUI

/// Hosted journey for the dashboard's archived container. It renders the real
/// row swipe actions and the real `ArchivedSessionsContainerSection`, so the
/// journey drives the same visibility, expansion, zero-count collapse, and page
/// handling the dashboard runs. Session membership is fixture input; the
/// surfaces and the container's control flow are production code.
struct HostedSessionArchiveFixture: View {
    private static let profileID = "fixture"
    /// The hosted harness is not the presented production dashboard, so it
    /// declares its own branch activity instead of inheriting the
    /// no-coordinator `.active` fallback. An active branch runs the dashboard's
    /// one-second row clock (a repeating `TimelineView`), and XCUI never
    /// observes app quiescence while that clock keeps the run loop busy, so every
    /// query in the journey would time out before its first assertion. The
    /// surfaces under test—row swipes and the archived container—read no
    /// presentation activity, so only the row's relative-time clock is affected.
    private static let branchActivity = PresentationSurfaceActivity.covered

    @State private var live: [SessionSummary] = [
        Self.session(id: "live-session", title: "Live session", archivedAt: nil),
    ]
    @State private var archived: [SessionSummary] = []
    /// Stands in for the dashboard's own archive projection revision: it
    /// advances whenever this fixture's Gateway-owned count changes.
    @State private var projectionRevision = 0

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
                        // Mirrors the dashboard's own row: the identifier and the
                        // swipe actions belong to the row button, not to the row
                        // content, so the journey reaches the same element
                        // production exposes. The fixture has no navigation.
                        Button(action: {}) {
                            HistoricalSessionRow(session: session, activity: .idle, showsContext: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session-row-\(session.dashboardID)")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(SessionDashboardLayout.rowInsets)
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

                ArchivedSessionsContainerSection(
                    count: archived.count,
                    sources: sources,
                    profileID: Self.profileID,
                    projectionRevision: projectionRevision,
                    presentationActive: true,
                    loadPage: { _, cursor in
                        await Self.admit(archived, cursor: cursor)
                    },
                    onOpen: { _ in },
                    onUnarchive: unarchive,
                    onDelete: { _ in }
                )
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 38)
        }
        .environment(\.tronPresentationActivity, Self.branchActivity)
    }

    /// One page of the fixture's Gateway-side archived list, through the
    /// production admission so the container sees the same shape a real page
    /// read produces.
    private static func admit(
        _ sessions: [SessionSummary],
        cursor: String?
    ) async -> ArchivedSessionsLoadResult {
        let page = ArchivedSessionsLoader.PageResponse(sessions: sessions, nextCursor: nil)
        return await ArchivedSessionsLoader.admit(page, requestedCursor: cursor) { true }
    }

    private func archive(_ session: SessionSummary) {
        guard let index = live.firstIndex(where: { $0.dashboardID == session.dashboardID }) else { return }
        live.remove(at: index)
        archived.insert(
            Self.session(id: session.id, title: session.title, archivedAt: "2026-09-26T09:30:00Z"),
            at: 0
        )
        projectionRevision &+= 1
    }

    private func unarchive(_ session: SessionSummary) {
        archived.removeAll { $0.dashboardID == session.dashboardID }
        live.append(Self.session(id: session.id, title: session.title, archivedAt: nil))
        projectionRevision &+= 1
    }
}
#endif
