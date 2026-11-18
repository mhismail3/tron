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

    func manageSheet(_ read: HomeManageDTO) -> some View {
        let unresolved = model.homeMutations.ownsUnresolvedCommand(profileID: profileID)
        return TronSettingsSections(alignment: .leading, spacing: 18) {
            usageHeader(read)
            if let sessionID { ManageModelConfigurationCard(sessionID: sessionID, home: true) }
            manageRows(read, unresolved: unresolved)
        }
    }

    @ViewBuilder func usageHeader(_ read: HomeManageDTO) -> some View {
        if let sessionID, let snapshot = model.sessionContextPresentation(for: sessionID) {
            HomeContextSummaryCard(snapshot: snapshot, read: read)
        } else {
            TronLoadingState(label: "Loading Home chat…")
        }
    }

    func manageRows(_ read: HomeManageDTO, unresolved: Bool) -> some View {
        let status = read.status
        let memoryBrowser = model.gatewayInfo?.capabilities.contains("home-memory-view.v1") == true
        let chapterList = model.gatewayInfo?.capabilities.contains("home-chapter-list.v1") == true
        let profileList = model.gatewayInfo?.capabilities.contains("home-profile-list.v1") == true
        return TronGlassCard(accent: accent) {
            VStack(spacing: 0) {
                if profileList {
                    navigationRow(icon: "person.text.rectangle",
                                  subtitle: HomeManageRowPresentation.profile(read.profile),
                                  destination: .profile, id: "home-manage-profile")
                    divider()
                }
                if memoryBrowser {
                    navigationRow(icon: "brain",
                                  subtitle: HomeStatusLinePresentation.memory(status, unresolvedCommand: unresolved),
                                  destination: .memory(sessionID: nil, chapterOrdinal: nil), id: "home-manage-memory-browser")
                }
                if let chapter = status.chapter, chapterList {
                    if memoryBrowser { divider() }
                    navigationRow(icon: "book",
                                  subtitle: HomeManageRowPresentation.chapters(read.chapters, fallback: chapter),
                                  destination: .chapters, id: "home-manage-chapters")
                }
                if memoryBrowser || (status.chapter != nil && chapterList) { divider() }
                navigationRow(icon: "checklist",
                              subtitle: HomeManageRowPresentation.tasks(read.tasks, admitted: status.admitsTaskReads),
                              destination: .tasks, id: "home-manage-tasks")
                divider()
                navigationRow(icon: "switch.2", subtitle: "Pause or resume memory, or disable Home",
                              destination: .controls, id: "home-manage-controls")
                divider()
                navigationRow(icon: "lock.shield", subtitle: "Scopes and grants Home's workers may use",
                              destination: .permissions, id: "home-manage-permissions")
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

    func navigationRow(icon: String, subtitle: String? = nil,
                       destination: HomeSheetDestination, id: String) -> some View {
        Button { present(destination) } label: {
            TronSettingsRow(icon: icon, title: destination.title, subtitle: subtitle, accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .tronListMarkers(id)
    }

    func divider() -> some View {
        TronSettingsDivider(accent: accent)
    }
}
