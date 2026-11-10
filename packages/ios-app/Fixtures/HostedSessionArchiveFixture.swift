#if HOSTED_TEST
import SwiftUI
import TronMobileCore

struct HostedSessionArchiveFixture: View {
    private static let profileID = "fixture"
    private static let pagesOneArchivedSessionPerRead =
        ProcessInfo.processInfo.arguments.contains("-tron-session-archive-paging-fixture")
    private static let revealFixture =
        ProcessInfo.processInfo.arguments.contains("-tron-session-archive-reveal-fixture")
    private static let gatedReadCount = pagesOneArchivedSessionPerRead || revealFixture ? 1 : 0
    private static let revealReadDelay = Duration.seconds(3)
    private static let revealLiveRowCount = 24
    private static let revealArchivedRowCount = 20
    private static let branchActivity = PresentationSurfaceActivity.covered

    @State private var live: [SessionSummary] = HostedSessionArchiveFixture.initialLive
    @State private var archived: [SessionSummary] = []
    @State private var projectionRevision = 0
    @State private var gatedReadsStarted = 0
    @State private var archiveConfirmation: SessionArchiveConfirmation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
