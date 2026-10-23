import SwiftUI
import TronMobileCore

/// The Home dashboard view's bounds. Every section is a projection of the
/// dashboard's synced session catalog: the Gateway marks Home workers on their
/// rows (`homeTaskId`), so the view issues no reads of its own.
enum HomeDashboardLayout {
    /// Recently Completed and Other Sessions show this many rows; View All lists the rest.
    static let sectionRowLimit = 5
}

/// One projection of the dashboard catalog into the view's three sections.
/// In Progress and Recently Completed hold Home's workers, identified by the
/// Gateway task ledger's `homeTaskId`. Other Sessions holds ordinary sessions,
/// independent of attention or activity. The shared user catalog already omits
/// every Home chapter using the Gateway's canonical chapter membership; do not
/// infer Home or worker identity from a title. All sections retain catalog order.
struct HomeDashboardSections: Equatable {
    let inProgress: [SessionSummary]
    let completed: [SessionSummary]
    let otherSessions: [SessionSummary]

    init(sessions: [SessionSummary]) {
        let settled = { (session: SessionSummary) in !(session.phase.isActive || session.waitingForUser) }
        inProgress = sessions.filter { $0.isHomeWorker && !settled($0) }
        completed = sessions.filter { $0.isHomeWorker && settled($0) }
        otherSessions = sessions.filter { $0.kind == .user && !$0.isHomeWorker }
    }

    enum Section: String, Hashable, Identifiable {
        case inProgress = "in-progress", completed, otherSessions = "other-sessions"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .inProgress: "In Progress"
            case .completed: "Recently Completed"
            case .otherSessions: "Other Sessions"
            }
        }
    }

    /// The rows a capped section's View All sheet lists.
    func sheetRows(_ section: Section) -> [SessionSummary] {
        switch section {
        case .inProgress: inProgress
        case .completed: completed
        case .otherSessions: otherSessions
        }
    }

    /// Each present section's place in the view's first-appearance stagger.
    /// The usage card above them is order 0; absent sections leave no gap.
    var revealOrder: [Section: Int] {
        var order: [Section: Int] = [:]
        for (section, rows) in [(Section.inProgress, inProgress), (.completed, completed), (.otherSessions, otherSessions)]
        where !rows.isEmpty {
            order[section] = order.count + 1
        }
        return order
    }
}

/// The View All sheet of a capped Home section (#1003). It is equatable on
/// its rows, so the parent's frequent updates (a running worker's summary, a
/// clock) skip it unless a listed row changed, and its rows are lazy, so
/// opening builds only the rows on screen and each row's relative-time clock
/// runs only while that row is visible. Styling is the shared filter sheet's
/// with the dashboard's `HistoricalSessionRow`. Its floating search button,
/// in the dashboard's circular glass chrome, opens the shared search pill;
/// `SessionTitleSearch` filters the rows locally, so a query never builds
/// more than the matching rows on screen.
struct HomeSectionRowsSheet: View, Equatable {
    struct Row: Equatable {
        let session: SessionSummary
        let activity: DashboardSessionActivity
    }

    let section: HomeDashboardSections.Section
    let rows: [Row]
    let onOpen: (SessionSummary) -> Void
    let onDone: () -> Void
    @State private var query = ""
    @State private var showingSearch = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.section == rhs.section && lhs.rows == rhs.rows
    }

    var body: some View {
        let visible = SessionTitleSearch.filter(rows, query: query) { $0.session.title }
        TronDashboardFilterSheet(
            title: section.title,
            accent: .tronPrimary,
            detents: [.medium, .large],
            onDone: onDone
        ) {
            if rows.isEmpty {
                TronPlaceholderState(
                    title: "No sessions",
                    detail: "There are no sessions in this section on the selected servers.",
                    icon: "bubble.left.and.bubble.right",
                    accent: .tronPrimary
                )
            } else if visible.isEmpty {
                TronPlaceholderState(
                    title: "No matches",
                    detail: "No session title matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”.",
                    icon: "magnifyingglass",
                    accent: .tronPrimary
                )
            }
            LazyVStack(alignment: .leading, spacing: TronSpacing.md) {
                ForEach(visible, id: \.session.dashboardID) { row in
                    Button {
                        onOpen(row.session)
                    } label: {
                        HistoricalSessionRow(session: row.session, activity: row.activity, showsContext: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-\(section.rawValue)-sheet-row-\(row.session.dashboardID)")
                }
            }
            // The floating search control must never cover the last row.
            .padding(.bottom, 64)
        }
        .overlay(alignment: .bottomTrailing) {
            DashboardFloatingSearch(
                text: $query,
                isPresented: $showingSearch,
                prompt: "Search titles",
                accent: .tronPrimary,
                buttonLabel: "Search \(section.title)",
                buttonIdentifier: "home-\(section.rawValue)-sheet-search",
                onDismiss: dismissSearch
            )
        }
        .animation(.snappy(duration: 0.18), value: showingSearch)
    }

    private func dismissSearch() {
        query = ""
        showingSearch = false
    }
}

/// The dashboard button's indicator. It uses the same indicator swap as
/// session rows, so state changes animate identically.
enum HomeButtonIndicatorState: Hashable {
    case resting
    case working
    case waitingForUser

    init(status: HomeStatusDTO?) {
        if status?.waitingForUser == true {
            self = .waitingForUser
        } else if status?.phase == .active {
            self = .working
        } else {
            self = .resting
        }
    }

    var accessibilityValue: String {
        switch self {
        case .resting: "Ready"
        case .working: "Working"
        case .waitingForUser: "Waiting for you"
        }
    }
}

/// The dashboard button's icon: the Tron logo at rest (Home's icon too), and
/// Home's working orb or waiting glyph while Home is busy or needs the user.
struct HomeButtonIndicator: View {
    let state: HomeButtonIndicatorState
    let accent: Color

    var body: some View {
        switch state {
        case .resting:
            Image("TronLogoVector")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(accent)
        case .working:
            ProcessActivityOrb(mode: .solving, size: 30)
        case .waitingForUser:
            Image(systemName: "questionmark.bubble.fill")
                .font(TronTypography.sans(size: 22, weight: .semibold))
                .foregroundStyle(Color.tronAmber)
        }
    }
}
