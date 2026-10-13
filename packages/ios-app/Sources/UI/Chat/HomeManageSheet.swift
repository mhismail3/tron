import SwiftUI
import TronMobileCore

/// The Manage Home main sheet: the Home chat's stats card with the state pill,
/// its model card with the memory model row, the rows container of Home
/// sub-sheets, and the pause and disable controls.
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
        return VStack(alignment: .leading, spacing: 18) {
            statsAndModel(read.status)
            manageRows(read, unresolved: unresolved)
            settingsRow
            manageControls(read.status, unresolved: unresolved, mutating: mutating)
        }
    }

    @ViewBuilder func statsAndModel(_ status: HomeStatusDTO) -> some View {
        if let sessionID, let snapshot = model.sessionContextPresentation(for: sessionID) {
            SessionContextUsageCard(
                snapshot: snapshot,
                accessory: TronStatusPill(text: HomeStatusLinePresentation.state(status),
                                          accent: Self.statusAccent(status))
                    .accessibilityIdentifier("home-manage-state")
            )
            // Home-originated and Home-task settings requests belong to Manage Home.
            .settingsApprovals(.home)
            SessionModelConfigurationCard(sessionID: sessionID, snapshot: snapshot,
                                          onError: { error in
                // A model choice belongs to the Home chat. Keep its notice above Models.
                if let target = model.presentationTarget(for: sessionID) {
                    model.presentError(error, scope: .session(id: target.sessionID, generation: target.generation))
                }
            }) {
                // Home's memory model is part of its configuration: Home cannot
                // answer until it is set. Every other Home setting is in the card below.
                SettingsRendererView(
                    target: SettingsTarget.sessionGatewayTarget(sessionID), writeLayer: nil, ownedLayers: ["chat", "profile"],
                    presentation: .keys(["model.ref[role=memory]"])
                )
            }
        } else {
            TronLoadingState(label: "Loading Home chat…")
        }
    }

    /// The Home sub-sheets, each a standard chevron row in the rows container. A row's
    /// secondary line is read from this sheet's load, never from a sub-sheet.
    func manageRows(_ read: HomeManageDTO, unresolved: Bool) -> some View {
        let status = read.status
        let summaries = read.context.breakdown?.sections.first { $0.id == .memory }?.count
        let memoryBrowser = model.gatewayInfo?.capabilities.contains("home-memory-view.v1") == true
        let chapterList = model.gatewayInfo?.capabilities.contains("home-chapter-list.v1") == true
        return TronGlassCard(accent: .tronSessionTeal) {
            VStack(spacing: 0) {
                navigationRow(icon: "doc.text.magnifyingglass", title: "Home Context",
                              subtitle: "Next request and delivered context", destination: .context, id: "home-manage-context")
                if memoryBrowser {
                    divider()
                    navigationRow(icon: "brain", title: "Memory",
                                  subtitle: HomeStatusLinePresentation.memory(status, summaries: summaries, unresolvedCommand: unresolved),
                                  destination: .memory(sessionID: nil, chapterOrdinal: nil), id: "home-manage-memory-browser")
                }
                if let chapter = status.chapter, chapterList {
                    divider()
                    navigationRow(icon: "book", title: "Chapters",
                                  subtitle: HomeManageRowPresentation.chapters(read.chapters, fallback: chapter),
                                  destination: .chapters, id: "home-manage-chapters")
                }
                if status.taskRecovery != nil {
                    divider()
                    navigationRow(icon: "checklist", title: "Tasks",
                                  subtitle: HomeManageRowPresentation.tasks(read.tasks, admitted: status.admitsTaskReads),
                                  destination: .tasks, id: "home-manage-tasks")
                    divider()
                    navigationRow(icon: "lock.shield", title: "Permissions",
                                  subtitle: HomeManageRowPresentation.permissions(read.permissions),
                                  destination: .permissions, id: "home-manage-permissions")
                }
            }
        }
    }

    /// Every setting Home uses, in its own container below the Home sub-sheets.
    @ViewBuilder var settingsRow: some View {
        if let sessionID {
            TronGlassCard(accent: .tronSessionTeal) {
                TronProgressiveSheetLink(accessibilityLabel: "Home Settings", identity: "home.settings", accent: .tronSessionTeal) {
                    ChatSettingsView(sessionID: sessionID, ownedLayers: ["chat", "profile"], changesScope: .home(sessionID),
                                     onOpenSession: onOpenSession.map { callback in { route in callback(route.sessionID) } })
                        .tronNavigationTitle("Home Settings")
                } label: {
                    TronSettingsRow(icon: "slider.horizontal.3", title: "Home Settings",
                                    subtitle: "Every setting Home uses", accent: .tronSessionTeal) {
                        Image(systemName: "chevron.right")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronSessionTeal)
                    }
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
                                        accent: .tronError, titleColor: .tronError)
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

    /// A chevron row that presents a managed child sheet.
    func navigationRow(icon: String, title: String, subtitle: String? = nil,
                       destination: HomeSheetDestination, id: String) -> some View {
        Button { present(destination) } label: {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle, accent: .tronSessionTeal) {
                Image(systemName: "chevron.right")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronSessionTeal)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    func divider(accent: Color = .tronSessionTeal) -> some View {
        TronSettingsDivider(accent: accent)
    }
}
