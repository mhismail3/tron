import SwiftUI
import TronMobileCore

extension HomeSheet {
    static func statusAccent(_ status: HomeStatus) -> Color {
        switch status.phase {
        case .ready, .active: .tronEmerald
        case .paused, .disabled, .undesignated: .tronSlate
        case .blocked, .rolloverPending, .missingSession, .unavailable: .tronError
        }
    }

    func manageSheet(_ read: HomeManageDTO?) -> some View {
        let unresolved = model.homeMutations.ownsUnresolvedCommand(profileID: profileID)
        return TronSettingsSections(alignment: .leading, spacing: 18) {
            HomeContextSummaryCard(snapshot: sessionID.flatMap { model.sessionContextPresentation(for: $0) }, read: read)
            if let sessionID { ManageModelConfigurationCard(sessionID: sessionID, home: true) }
            manageRows(read, unresolved: unresolved).tronSheetBottomContainer()
        }
        .animation(.smooth(duration: 0.3), value: read)
    }

    func manageRows(_ read: HomeManageDTO?, unresolved: Bool) -> some View {
        let status = read?.status
        let memoryBrowser = model.gatewayInfo?.capabilities.contains("home-memory-view.v1") == true
        let chapterList = model.gatewayInfo?.capabilities.contains("home-chapter-list.v1") == true
        let profileList = model.gatewayInfo?.capabilities.contains("home-profile-list.v1") == true
        return TronGlassCard(accent: accent) {
            VStack(spacing: 0) {
                if profileList {
                    navigationRow(icon: "person.text.rectangle",
                                  subtitle: read.map { HomeManageRowPresentation.profile($0.profile) },
                                  loading: read == nil, destination: .profile, id: "home-manage-profile")
                    divider()
                }
                if memoryBrowser {
                    navigationRow(icon: "brain",
                                  subtitle: status.map { HomeStatusLinePresentation.memory($0, unresolvedCommand: unresolved) },
                                  loading: read == nil, destination: .memory(sessionID: nil, chapterOrdinal: nil), id: "home-manage-memory-browser")
                }
                let showsChapters = chapterList && (read == nil || status?.chapter != nil)
                if showsChapters {
                    if memoryBrowser { divider() }
                    navigationRow(icon: "book",
                                  subtitle: read.flatMap { HomeManageRowPresentation.chapters($0.chapters, fallback: $0.status.chapter) },
                                  loading: read == nil, destination: .chapters, id: "home-manage-chapters")
                }
                if memoryBrowser || showsChapters { divider() }
                navigationRow(icon: "checklist",
                              subtitle: read.map { HomeManageRowPresentation.tasks($0.tasks, admitted: $0.status.admitsTaskReads) },
                              loading: read == nil, destination: .tasks, id: "home-manage-tasks")
                divider()
                navigationRow(icon: "switch.2", subtitle: "Pause or resume memory, or disable Home",
                              destination: .controls, id: "home-manage-controls")
            }
        }
    }

    static func hostPressureAccent(_ level: HomeStatusHostPressureLevel) -> Color {
        switch level {
        case .normal: .tronEmerald
        case .elevated: .tronAmber
        case .critical: .tronError
        }
    }

    func navigationRow(icon: String, subtitle: String?, loading: Bool = false,
                       destination: HomeSheetDestination, id: String) -> some View {
        Button { present(destination) } label: {
            TronSettingsRow(icon: icon, title: destination.title, subtitle: loading ? "Loading Home details" : subtitle,
                            accent: accent, subtitleIsLoading: loading) { EmptyView() }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .tronListMarkers(id)
    }

    func divider() -> some View {
        TronSettingsDivider(accent: accent)
    }
}
