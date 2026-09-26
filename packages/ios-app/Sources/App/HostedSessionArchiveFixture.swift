#if HOSTED_TEST
import SwiftUI

/// Hosted journey for the dashboard's archived container. It renders the real
/// row swipe actions and the real `ArchivedSessionsContainerSection`, so the
/// journey drives the same visibility, expansion, zero-count collapse, and page
/// handling the dashboard runs. Session membership is fixture input; the
/// surfaces and the container's control flow are production code. Its paging
/// mode serves one archived session per page and refuses continuations, and
/// hangs the first page read, so the journey can also drive a reload that lands
/// while a pass is still reading and a continuation the Gateway refuses.
struct HostedSessionArchiveFixture: View {
    private static let profileID = "fixture"
    private static let pagesOneArchivedSessionPerRead =
        ProcessInfo.processInfo.arguments.contains("-tron-session-archive-paging-fixture")
    /// How many of the fixture's page reads hang. The first read is the one a
    /// reload retires, so the journey decides which pass publishes without
    /// racing a real network.
    private static let stalledReadCount = pagesOneArchivedSessionPerRead ? 1 : 0
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
    @State private var stalledReadsStarted = 0
    @State private var archiveConfirmation: SessionArchiveConfirmation?

    init() {
        guard Self.pagesOneArchivedSessionPerRead else { return }
        _archived = State(initialValue: [
            Self.session(id: "older-session", title: "Older archived session", archivedAt: "2026-09-25T09:30:00Z"),
        ])
    }

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
                            onArchive: { archiveConfirmation = SessionArchiveConfirmation(session: session, archived: true) },
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
                        // The page a real read answers with is the projection at
                        // read time, so a pass that a reload retires can never
                        // publish the newer rows either.
                        let snapshot = archived
                        await self.gateRead()
                        return try await Self.page(archived: snapshot, cursor: cursor)
                    },
                    onOpen: { _ in },
                    onUnarchive: { archiveConfirmation = SessionArchiveConfirmation(session: $0, archived: false) },
                    onDelete: { _ in }
                )
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 38)
            .sessionArchiveConfirmation($archiveConfirmation) { request in
                if request.archived { archive(request.session) } else { unarchive(request.session) }
            }
        }
        .environment(\.tronPresentationActivity, Self.branchActivity)
    }

    /// One page of the fixture's Gateway-side archived list, through the
    /// production admission so the container sees the same shape a real page
    /// read produces. The paging fixture serves one session per page and refuses
    /// every continuation, which is what an expired cursor looks like.
    private static func page(
        archived: [SessionSummary],
        cursor: String?
    ) async throws -> ArchivedSessionsLoadResult {
        if cursor != nil, pagesOneArchivedSessionPerRead {
            throw GatewayFailure(
                code: "invalid_request",
                message: "The session list cursor is invalid or expired",
                retryable: true,
                details: nil
            )
        }
        let response = pagesOneArchivedSessionPerRead
            ? ArchivedSessionsLoader.PageResponse(sessions: Array(archived.prefix(1)), nextCursor: "fixture-next")
            : ArchivedSessionsLoader.PageResponse(sessions: archived, nextCursor: nil)
        return await ArchivedSessionsLoader.admit(response, requestedCursor: cursor) { true }
    }

    /// Hangs the configured first reads. Cancelling the pass releases the sleep
    /// immediately and the page then reaches a retired container, which is what a
    /// response already in flight when a newer authority lands looks like. The
    /// retirement, not the cancellation, is what keeps that page out.
    private func gateRead() async {
        guard stalledReadsStarted < Self.stalledReadCount else { return }
        stalledReadsStarted += 1
        try? await Task.sleep(for: .seconds(3_600))
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
