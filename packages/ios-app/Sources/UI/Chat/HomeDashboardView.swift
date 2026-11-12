import SwiftUI
import TronMobileCore

enum HomeDashboardLayout {
    static let sectionRowLimit = 5
}

struct HomeDashboardSections: Equatable {
    let inProgress: [CatalogSession]
    let completed: [CatalogSession]
    let otherSessions: [CatalogSession]

    init(sessions: [CatalogSession]) {
        let settled = { (session: CatalogSession) in !(session.phase.isActive || session.waitingForUser) }
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

    func sheetRows(_ section: Section) -> [CatalogSession] {
        switch section {
        case .inProgress: inProgress
        case .completed: completed
        case .otherSessions: otherSessions
        }
    }

    var revealOrder: [Section: Int] {
        var order: [Section: Int] = [:]
        for (section, rows) in [(Section.inProgress, inProgress), (.completed, completed), (.otherSessions, otherSessions)]
        where !rows.isEmpty {
            order[section] = order.count + 1
        }
        return order
    }
}

struct HomeSectionRowsSheet: View, Equatable {
    struct Row: Equatable {
        let session: CatalogSession
        let activity: DashboardSessionActivity
    }

    let section: HomeDashboardSections.Section
    let rows: [Row]
    let onOpen: (CatalogSession) -> Void
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

enum HomeButtonIndicatorState: Hashable {
    case resting
    case working
    case waitingForUser

    init(status: HomeStatus?) {
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
            ProcessActivityOrb(mode: .solving, size: 30, accent: accent)
        case .waitingForUser:
            Image(systemName: "questionmark.bubble.fill")
                .font(TronTypography.sans(size: 22, weight: .semibold))
                .foregroundStyle(Color.tronAmber)
        }
    }
}
