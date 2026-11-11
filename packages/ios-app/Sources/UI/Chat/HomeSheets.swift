import SwiftUI
import TronMobileCore

enum HomeSheetDestination: Identifiable {
    case manage
    case memory(sessionID: String?, chapterOrdinal: Int?)
    case memorySummary(HomeMemoryViewLine, sessionID: String?)
    case memoryItem(HomeMemoryItem)
    case evidence(HomeMemoryEvidence)
    case chapters
    case profile
    case profileItem(HomeProfileListItem)
    case chapter(HomeChapterSummary, limits: HomeChapterListLimits)
    case tasks
    case task(String)
    case taskHistory(String)
    case checkin(HomeTaskHistoryItem)

    var id: String {
        switch self {
        case .manage: "manage"
        case .memory: "memory"
        case .memorySummary: "memory-summary"
        case .memoryItem: "memory-item"
        case .evidence: "evidence"
        case .chapters: "chapters"
        case .chapter: "chapter"
        case .profile: "profile"
        case .profileItem: "profile-item"
        case .tasks: "tasks"
        case .task: "task"
        case .taskHistory: "task-history"
        case .checkin: "checkin"
        }
    }

    var title: String {
        switch self {
        case .manage: "Manage Home"
        case .memory, .memorySummary, .memoryItem: "Memory"
        case .evidence: "Canonical transcript"
        case .chapters, .chapter: "Chapters"
        case .profile, .profileItem: "Profile"
        case .tasks, .task: "Tasks"
        case .taskHistory: "Check-ins"
        case .checkin: "Check-in"
        }
    }

    var initialQuery: HomeSheetReadQuery {
        switch self {
        case .manage: .manage
        case .memory(let sessionID, _): .memory(sessionID: sessionID, continuation: nil)
        case .memorySummary(let line, let sessionID): .memoryPart(sessionID: sessionID, line)
        case .memoryItem, .chapter, .checkin: .chapters
        case .evidence(let source): .evidence(source, offset: 0)
        case .chapters: .chapters
        case .profile, .profileItem: .profile
        case .tasks: .tasks(nil)
        case .task(let id): .task(id)
        case .taskHistory(let id): .taskHistory(id, cursor: nil)
        }
    }

    var isTaskSurface: Bool {
        switch self { case .tasks, .task, .taskHistory, .checkin: true; default: false }
    }

    var loadsPage: Bool {
        switch self { case .memoryItem, .chapter, .checkin: false; default: true }
    }
}

struct HomeControlAdmission {
    let identity: HomeSheetReadIdentity
    let coordinator: PresentationActivityCoordinator
    let authority: HomeMutationCoordinator.Authority
}

struct HomeSheetRoute: Identifiable {
    let profileID: String
    let sessionID: String
    let destination: HomeSheetDestination
    var id: String { "home.\(profileID).\(destination.id)" }
}

struct HomeSheetRequest: Hashable {
    var id = UUID()
    let query: HomeSheetReadQuery
}

struct HomeSheetTaskID: Hashable {
    let identity: HomeSheetReadIdentity?
    let active: Bool
    let request: HomeSheetRequest
}

struct HomeSheet: View {
    let destination: HomeSheetDestination
    let profileID: String
    var sessionID: String?
    var onOpenSession: ((String) -> Void)?
    var onChanged: (() -> Void)?
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    @Environment(\.tronPresentationActivityCoordinator) var coordinator
    @Environment(\.tronPresentationSurfaceToken) var token
    @Environment(\.tronPresentationActivity) var activity
    @PresentationState var owner = HomeSheetReadOwner()
    @PresentationState var request: HomeSheetRequest
    @PresentationState var childDestination: HomeSheetDestination?
    @PresentationState var reading: HomeTextReading?
    @PresentationState private var showingMemoryInfo = false
    @Environment(\.tronSettingsVisualTheme) private var visualTheme
    @PresentationState private var returnsFromBrowsing = false
    @PresentationState private var sliderPresentation = ConfigurationSliderPresentation()
    @PresentationState var profileEdit = HomeProfileEditState()

    init(destination: HomeSheetDestination, profileID: String, sessionID: String? = nil,
         onOpenSession: ((String) -> Void)? = nil, onChanged: (() -> Void)? = nil) {
        self.destination = destination
        self.profileID = profileID
        self.sessionID = sessionID
        self.onOpenSession = onOpenSession
        self.onChanged = onChanged
        _request = PresentationState(wrappedValue: HomeSheetRequest(query: destination.initialQuery))
    }

    var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    var accent: Color { visualTheme?.accent ?? .tronPrimary }
    private var isEvidence: Bool { if case .evidence = destination { true } else { false } }
    private var detents: Set<PresentationDetent> { [.medium, .large] }
    var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    var body: some View {
        Group {
            if case .memory = destination {
                HomePagedListSheet(destination: destination, profileID: profileID, onOpenSession: onOpenSession)
            } else if case .tasks = destination {
                HomePagedListSheet(destination: destination, profileID: profileID, onOpenSession: onOpenSession)
            } else if case .taskHistory = destination {
                HomePagedListSheet(destination: destination, profileID: profileID, onOpenSession: onOpenSession)
            } else if case .checkin(let item) = destination {
                HomeTaskCheckinSheet(item: item)
            } else if destination.isTaskSurface {
                HomeTaskSheet(destination: destination, profileID: profileID, onOpenSession: onOpenSession)
            } else if isEvidence {
                TronDocumentSheet(title: destination.title, detents: detents) { sheetContent }
            } else {
                NavigationStack { sheetContent }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents(detents)
        .presentationDragIndicator(.hidden)
        .environment(\.tronSettingsVisualTheme, visualTheme ?? TronSettingsVisualTheme(
            accent: .tronPrimary, surfaceAccent: .tronPrimarySurface))
        .tint(accent)
        .onPresentationRetire { owner.retire() }
    }

    private var sheetContent: some View {
        Group {
            if let list = emptyProfileList {
                emptyProfile(list)
            } else {
                ScrollView {
                    TronSettingsSections(alignment: .leading, spacing: 18) {
                        content
                    }
                    .padding(18)
                }
                .tronScrollEdgeChrome()
            }
        }
        .environment(\.tronSettingsSecondaryTextSizeAdjustment, SessionSummaryTypography.metadataSizeAdjustment)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if memoryMetadata != nil {
                ToolbarItem(placement: .topBarLeading) {
                    TronSheetInfoButton(accessibilityLabel: "Technical details", accent: accent) {
                        showingMemoryInfo = true
                    }
                    .accessibilityIdentifier("home-memory-info")
                }
            }
            if !isEvidence {
            ToolbarItem(placement: .principal) { TronSheetTitle(title: destination.title, accent: accent) }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    if let editor = sliderPresentation.session {
                        _ = sliderPresentation.beginClosing(editor)
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: accent)
                }
                .accessibilityLabel("Done")
                .accessibilityIdentifier("home-sheet-done-\(destination.id)")
            }
            }
        }
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignposts)
        .task(id: HomeSheetTaskID(identity: identity, active: active, request: request)) {
            guard destination.loadsPage else { return }
            guard active, let identity, let coordinator else { owner.retireLoading(); return }
            let query = request.query
            let requestID = request.id
            if owner.holds(requestID: requestID, identity: identity) {
                if refreshesBehindChildren, !returnsFromBrowsing { } else {
                    returnsFromBrowsing = false
                    return
                }
            }
            await owner.load(requestID: requestID, identity: identity, coordinator: coordinator,
                             isCurrent: { self.identity == identity && self.request.id == requestID }) {
                try await fetch(query: query, identity: identity, requestID: requestID)
            }
        }
        .tronManagedSheet(item: $childDestination, identity: { "home.\(profileID).\($0.id)" }) { child in
            HomeSheet(destination: child, profileID: profileID, sessionID: sessionID, onOpenSession: onOpenSession,
                      onChanged: { returnsFromBrowsing = false; onChanged?() })
                .tronSettingsVisualTheme(accent: accent, surfaceAccent: visualTheme?.surfaceAccent ?? .tronPrimarySurface)
        }
        .tronManagedSheet(isPresented: $showingMemoryInfo, identity: "home.\(profileID).memory-info.\(destination.id)") {
            if let metadata = memoryMetadata {
                TronDocumentSheet(title: "Technical details", detents: [.medium, .large]) {
                    ScrollView {
                        TronTechnicalMetadataSection(title: "Memory", items: metadata, accent: accent)
                            .padding(18)
                            .accessibilityIdentifier("home-memory-technical-details")
                    }
                    .tronScrollEdgeChrome()
                }
                .tronSettingsVisualTheme(accent: accent, surfaceAccent: visualTheme?.surfaceAccent ?? .tronPrimarySurface)
            }
        }
        .tronManagedSheet(item: $reading, identity: { "home.\(profileID).reading.\($0.id)" }) { reading in
            HomeTextReader(reading: reading).tronSettingsVisualTheme(accent: accent, surfaceAccent: visualTheme?.surfaceAccent ?? .tronPrimarySurface)
        }
    }

    @ViewBuilder private var content: some View {
        switch destination {
        case .memoryItem(let item): memoryDetail(item)
        case .chapter(let chapter, let limits): chapterDetail(chapter, limits: limits)
        case .profileItem(let item): profileItemDetail(loadedProfileItem(item))
        default:
            loadedContent
        }
    }

    private var emptyProfileList: HomeProfileList? {
        switch owner.state {
        case .loaded(let read, .profile(let list)), .loading(let read, .some(.profile(let list))):
            return read.identity.profileID == profileID && read.identity.surfaceToken == token && list.items.isEmpty ? list : nil
        default: return nil
        }
    }

    @ViewBuilder private var loadedContent: some View {
        switch owner.state {
        case .idle, .loading(_, nil):
            TronSheetLoadingState(label: "Loading Home…", accent: accent)
        case .failed(_, let error):
            TronPlaceholderState(title: "Home could not be read", detail: error, icon: "exclamationmark.triangle",
                                 actionTitle: "Reload") { reload() }
        case .loaded(let read, let content), .loading(let read, .some(let content)):
            if read.identity.profileID == profileID && read.identity.surfaceToken == token {
                switch content {
                case .manage(let manage): manageSheet(manage)
                case .chapters(let list): chapters(list)
                case .profile(let list): profile(list)
                case .memory(let view): memory(view)
                case .evidence(let page):
                    evidenceSheet(page)
                case .status, .tasks, .task, .taskHistory, .permissions: EmptyView()
                }
            } else {
                TronSheetLoadingState(label: "Waiting for Home…", accent: accent)
            }
        }
    }

    private func fetch(query: HomeSheetReadQuery, identity: HomeSheetReadIdentity, requestID: UUID) async throws -> HomeSheetContent {
        try await model.readHomeSheet(query, identity: identity, isCurrent: { self.request.id == requestID && self.active })
    }

    func reload() {
        request = HomeSheetRequest(query: destination.initialQuery)
    }

    func present(_ child: HomeSheetDestination) {
        switch child {
        case .memory, .chapters, .profile, .profileItem: returnsFromBrowsing = true
        default: returnsFromBrowsing = false
        }
        childDestination = child
    }

    private var refreshesBehindChildren: Bool {
        switch destination { case .manage, .profile: true; default: false }
    }

    func refreshAfterMutation() {
        request = HomeSheetRequest(query: destination.initialQuery)
    }
}

struct HomeTextReading: Identifiable, Hashable {
    let id: String
    let title: String
    let text: String
}

struct HomeTextReader: View {
    let reading: HomeTextReading

    var body: some View {
        TronDocumentSheet(title: reading.title, detents: [.medium, .large]) {
            ScrollView {
                TronMarkdownView(text: reading.text, streaming: false)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home-reading-text")
            }
            .tronScrollEdgeChrome()
        }
    }
}
