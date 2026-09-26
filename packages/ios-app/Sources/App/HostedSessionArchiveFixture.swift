#if HOSTED_TEST
import SwiftUI

/// Hosted journey for the dashboard's archived container. It renders the real
/// row swipe actions and the real `ArchivedSessionsContainerSection`, so the
/// journey drives the same visibility, expansion, zero-count collapse, and page
/// handling the dashboard runs. Session membership is fixture input; the
/// surfaces and the container's control flow are production code. Its paging
/// mode serves one archived session per page and refuses continuations, and
/// hangs the first page read, so the journey can also drive a reload that lands
/// while a pass is still reading and a continuation the Gateway refuses. Its
/// reveal mode fills the list with live rows and delays the first page read, so
/// the journey can expand a header that sits at the bottom of the screen, catch
/// the header's spinner, and check that the revealed rows are on screen.
struct HostedSessionArchiveFixture: View {
    private static let profileID = "fixture"
    private static let pagesOneArchivedSessionPerRead =
        ProcessInfo.processInfo.arguments.contains("-tron-session-archive-paging-fixture")
    private static let revealFixture =
        ProcessInfo.processInfo.arguments.contains("-tron-session-archive-reveal-fixture")
    /// How many of the fixture's page reads are gated. The paging mode hangs its
    /// first read so a reload retires that pass; the reveal mode only delays it,
    /// so the journey can capture the header's spinner before the rows arrive.
    private static let gatedReadCount = pagesOneArchivedSessionPerRead || revealFixture ? 1 : 0
    private static let revealReadDelay = Duration.seconds(3)
    /// Enough live rows that the archived header starts below the fold, and
    /// enough archived rows that the revealed section is taller than the screen,
    /// so the reveal is proven to stop with the header at the top.
    private static let revealLiveRowCount = 24
    private static let revealArchivedRowCount = 20
    /// The hosted harness is not the presented production dashboard, so it
    /// declares its own branch activity instead of inheriting the
    /// no-coordinator `.active` fallback. An active branch runs the dashboard's
    /// one-second row clock (a repeating `TimelineView`), and XCUI never
    /// observes app quiescence while that clock keeps the run loop busy, so every
    /// query in the journey would time out before its first assertion. The
    /// surfaces under test—row swipes and the archived container—read no
    /// presentation activity, so only the row's relative-time clock is affected.
    private static let branchActivity = PresentationSurfaceActivity.covered

    @State private var live: [SessionSummary] = HostedSessionArchiveFixture.initialLive
    @State private var archived: [SessionSummary] = []
    /// Stands in for the dashboard's own archive projection revision: it
    /// advances whenever this fixture's Gateway-owned count changes.
    @State private var projectionRevision = 0
    @State private var gatedReadsStarted = 0
    @State private var archiveConfirmation: SessionArchiveConfirmation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The fixture's Gateway-side membership. The reveal mode needs enough live
    /// rows to push the archived header below the fold, and enough archived rows
    /// that the reveal has rows to show; every other mode keeps the single pair
    /// the journeys were written against.
    private static var initialLive: [SessionSummary] {
        guard revealFixture else {
            return [session(id: "live-session", title: "Live session", archivedAt: nil)]
        }
        return (0..<revealLiveRowCount).map { index in
            session(id: "live-session-\(index)", title: "Live session \(index + 1)", archivedAt: nil)
        }
    }

    private static var initialArchived: [SessionSummary] {
        if revealFixture {
            return (0..<revealArchivedRowCount).map { index in
                session(
                    id: "archived-session-\(index)",
                    title: "Archived session \(index + 1)",
                    archivedAt: "2026-09-\(26 - index)T09:30:00Z"
                )
            }
        }
        guard pagesOneArchivedSessionPerRead else { return [] }
        return [session(id: "older-session", title: "Older archived session", archivedAt: "2026-09-25T09:30:00Z")]
    }

    init() {
        _archived = State(initialValue: Self.initialArchived)
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
            ScrollViewReader { proxy in
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
                        onRevealRows: { proxy.revealArchivedSection(reduceMotion: reduceMotion) },
                        onOpen: { _ in },
                        onUnarchive: { archiveConfirmation = SessionArchiveConfirmation(session: $0, archived: false) },
                        onDelete: { _ in }
                    )
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 38)
            }
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

    /// Gates the fixture's configured first reads. The paging mode hangs its
    /// read forever: cancelling the pass releases the sleep, and the page then
    /// reaches a retired container, which is what a response already in flight
    /// when a newer authority lands looks like. The reveal mode only delays the
    /// read, so the journey sees the header's spinner and then the rows.
    private func gateRead() async {
        guard gatedReadsStarted < Self.gatedReadCount else { return }
        gatedReadsStarted += 1
        if Self.revealFixture {
            try? await Task.sleep(for: Self.revealReadDelay)
            return
        }
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
