import SwiftUI
import TronMobileCore

/// Manage Home's context ring, state and workers, its sub-sheet destinations,
/// consolidated settings, and pause/disable controls.
extension HomeSheet {
    /// The state pill's accent: a working or ready Home reads as success, a blocked
    /// or recovering one as an error, and a paused or disabled one as idle.
    static func statusAccent(_ status: HomeStatusDTO) -> Color {
        switch status.phase {
        case .ready, .active: .tronEmerald
        case .paused, .disabled, .undesignated: .tronSlate
        case .blocked, .rolloverPending, .missingSession, .unavailable: .tronError
        }
    }

    func manageSheet(_ read: HomeManageDTO) -> some View {
        let unresolved = model.homeMutations.ownsUnresolvedCommand(profileID: profileID)
        let mutating = model.homeMutations.isRunning(profileID: profileID)
        return TronSettingsSections(alignment: .leading, spacing: 18) {
            usageHeader(read)
            if let sessionID { ManageModelConfigurationCard(sessionID: sessionID, home: true) }
            manageRows(read, unresolved: unresolved)
            settingsRow
            manageControls(read.status, unresolved: unresolved, mutating: mutating)
        }
    }

    @ViewBuilder func usageHeader(_ read: HomeManageDTO) -> some View {
        if let sessionID, let snapshot = model.sessionContextPresentation(for: sessionID) {
            HomeContextSummaryCard(snapshot: snapshot, read: read)
        } else {
            TronLoadingState(label: "Loading Home chat…")
        }
    }

    /// The Home sub-sheets, each a standard row in the rows container. A row's
    /// secondary line is read from this sheet's load, never from a sub-sheet.
    func manageRows(_ read: HomeManageDTO, unresolved: Bool) -> some View {
        let status = read.status
        let memoryBrowser = model.gatewayInfo?.capabilities.contains("home-memory-view.v1") == true
        let chapterList = model.gatewayInfo?.capabilities.contains("home-chapter-list.v1") == true
        let profileList = model.gatewayInfo?.capabilities.contains("home-profile-list.v1") == true
        return TronGlassCard(accent: accent) {
            VStack(spacing: 0) {
                // What Home has learned about you sits above what it remembers.
                if profileList {
                    navigationRow(icon: "person.text.rectangle",
                                  subtitle: HomeManageRowPresentation.profile(read.profile),
                                  destination: .profile, id: "home-manage-profile")
                    if memoryBrowser || (status.chapter != nil && chapterList) || status.taskRecovery != nil { divider() }
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
                if status.taskRecovery != nil {
                    if memoryBrowser || (status.chapter != nil && chapterList) { divider() }
                    navigationRow(icon: "checklist",
                                  subtitle: HomeManageRowPresentation.tasks(read.tasks, admitted: status.admitsTaskReads),
                                  destination: .tasks, id: "home-manage-tasks")
                }
            }
        }
    }

    static func hostPressureAccent(_ level: HomeStatusDTO.HostPressure.Level) -> Color {
        switch level {
        case .normal: .tronEmerald
        case .elevated: .tronWarning
        case .critical: .tronError
        }
    }

    /// Every setting Home uses, in its own container below the Home sub-sheets.
    @ViewBuilder var settingsRow: some View {
        if let sessionID {
            let title = "Home Settings"
            TronGlassCard(accent: accent) {
                TronProgressiveSheetLink(accessibilityLabel: title, identity: "home.settings", accent: accent,
                                         surfaceAccent: .tronPrimarySurface) {
                    SessionSettingsView(sessionID: sessionID, ownedLayers: ["session"], homeProfileID: profileID)
                        .tronNavigationTitle(title, accent: accent)
                } label: {
                    TronSettingsRow(icon: "slider.horizontal.3", title: title,
                                    subtitle: "Assistant profile and worker launch choices", accent: accent)
                }
                .accessibilityIdentifier("home-manage-settings")
            }
        }
    }

    /// Pause, resume and disable, in the bottom container Manage Session uses for
    /// its export and archive rows. Disable needs confirmation; an unresolved
    /// command leaves only the completion check.
    func manageControls(_ status: HomeStatusDTO, unresolved: Bool, mutating: Bool) -> some View {
        TronGlassCard(accent: .tronSlate) {
            VStack(spacing: 0) {
                if !unresolved {
                    if status.memory.paused == true || status.memory.blocked != nil {
                        Button { perform(.resumeMemory) } label: {
                            TronSettingsRow(icon: "play.fill", title: "Resume memory", accent: .tronSlate)
                        }
                        .buttonStyle(.plain)
                        .disabled(mutating)
                        .accessibilityIdentifier("home-manage-resume")
                        divider(accent: .tronSlate)
                    }
                    if status.memory.paused != true {
                        Button { perform(.pauseMemory) } label: {
                            TronSettingsRow(icon: "pause.fill", title: "Pause memory",
                                            subtitle: "New responses are blocked while paused", accent: .tronSlate)
                        }
                        .buttonStyle(.plain)
                        .disabled(mutating || !status.memory.configured)
                        .accessibilityIdentifier("home-manage-pause")
                        divider(accent: .tronSlate)
                    }
                }
                if unresolved {
                    Button { checkCompletion() } label: {
                        TronSettingsRow(icon: "arrow.clockwise", title: "Check completion",
                                        subtitle: "Resolve the pending Home change first", accent: .tronSlate)
                    }
                    .buttonStyle(.plain)
                    .disabled(mutating)
                    .accessibilityIdentifier("home-manage-check-completion")
                } else {
                    Button {
                        guard let admission = admitControl() else { return }
                        disableAdmission = admission
                        confirmingDisable = true
                    } label: {
                        TronSettingsRow(icon: "house.slash", title: "Disable Home",
                                        subtitle: "Stops activations; history is preserved",
                                        accent: .tronError, titleColor: .tronError, subtitleColor: .tronError)
                    }
                    .buttonStyle(.plain)
                    .disabled(mutating)
                    .accessibilityIdentifier("home-manage-disable")
                }
            }
        }
        .tronManagedSheet(isPresented: $confirmingDisable, identity: "home.\(profileID).disable-confirmation") {
            TronConfirmationSheet(
                title: "Disable Home?",
                message: "Activations stop. Home's history is preserved.",
                confirmTitle: "Disable Home",
                destructive: true,
                icon: "house.slash",
                onConfirm: { if let disableAdmission { run(.disable, disableAdmission) } }
            )
        }
    }

    /// A row that presents a managed child sheet, labeled with that sheet's title.
    func navigationRow(icon: String, subtitle: String? = nil,
                       destination: HomeSheetDestination, id: String) -> some View {
        Button { present(destination) } label: {
            TronSettingsRow(icon: icon, title: destination.title, subtitle: subtitle, accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    func divider(accent: Color? = nil) -> some View {
        TronSettingsDivider(accent: accent ?? self.accent)
    }
}
