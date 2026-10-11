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
            // #758: the settings approvals section (`.settingsApprovals(.home)`) inserts
            // here, before the model card, once that epic lands.
            SessionModelConfigurationCard(sessionID: sessionID, snapshot: snapshot,
                                          onError: { mutationFailure = $0.localizedDescription }) {
                memoryModelRow(status)
            }
        } else {
            TronLoadingState(label: "Loading Home chat…")
        }
    }

    /// The memory model is a row of the model card: its picker is the ordinary
    /// model picker, and a choice is the `home.configureMemory` receipt.
    func memoryModelRow(_ status: HomeStatusDTO) -> some View {
        let name = SessionModelSelectionPresentation.modelName(status.memory.model, catalog: models)
        let spend = status.memory.spentTokens.map { "\($0.formatted(.number.notation(.compactName))) tokens used" }
        return TronProgressiveSheetLink(
            accessibilityLabel: "Memory model",
            identity: "home.\(profileID).memory-model",
            accent: .tronPurple,
            detents: .contentFit
        ) {
            memoryModelPicker(status)
        } label: {
            // The identifier sits on the row inside the link: a card-level identifier
            // would replace the link's own (SessionModelSummaryCard names its container).
            TronSettingsRow(icon: "cpu", title: "Memory model",
                            subtitle: status.memory.configured ? spend : "Choose a memory model before sending",
                            accent: .tronPurple) {
                TronInlineActionLabel(name)
            }
            .accessibilityIdentifier("home-memory-model-row")
            .accessibilityValue(name)
        }
    }

    /// The picker is its own managed child: a choice is admitted under the picker's
    /// surface, so it stays valid while this sheet is covered by the picker.
    func memoryModelPicker(_ status: HomeStatusDTO) -> some View {
        HomeMemoryModelPicker(profileID: profileID, current: status.memory.model, models: models,
                              availability: modelSelectionAvailability) {
            refreshAfterMutation()
        }
    }

    var modelSelectionAvailability: ModelSelectionAvailability {
        if model.homeMutations.ownsUnresolvedCommand(profileID: profileID) { return .blocked("Check the pending Home change first") }
        guard !model.homeMutations.isRunning(profileID: profileID),
              case .loaded(let read, .manage(_)) = owner.state,
              read.requestID == request.id, read.identity == identity else { return .applying }
        return .ready
    }

    /// The Home sub-sheets, each a standard chevron row in the rows container. A row's
    /// secondary line is read from this sheet's load, never from a sub-sheet.
    func manageRows(_ read: HomeManageDTO, unresolved: Bool) -> some View {
        let status = read.status
        let summaries = read.context.breakdown?.sections.first { $0.id == .memory }?.count
        let memoryBrowser = model.gatewayInfo?.capabilities.contains("home-memory-browser.v1") == true
        let chapterList = model.gatewayInfo?.capabilities.contains("home-chapter-list.v1") == true
        return TronGlassCard(accent: .tronSessionTeal) {
            VStack(spacing: 0) {
                navigationRow(icon: "doc.text.magnifyingglass", title: "Home Context",
                              subtitle: "What Home's requests carry", destination: .context, id: "home-manage-context")
                if memoryBrowser {
                    divider()
                    navigationRow(icon: "brain", title: "Memory",
                                  subtitle: HomeStatusLinePresentation.memory(status, summaries: summaries, unresolvedCommand: unresolved),
                                  destination: .memory(sessionID: nil), id: "home-manage-memory-browser")
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

/// The memory model picker: the ordinary ModelPicker over the physical catalog.
/// A choice is the `home.configureMemory` receipt, admitted under this picker's own
/// presentation surface; a refused choice is raised here, where it was made.
struct HomeMemoryModelPicker: View {
    let profileID: String
    let current: ModelRef?
    let models: [ModelSummary]
    let availability: ModelSelectionAvailability
    /// Called once the choice is accepted, so the presenting sheet re-reads its status.
    let onApplied: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @State private var failure: String?
    /// The choice being applied. It is shown at once and released when the status
    /// converges on it, or when the Gateway refuses it.
    @State private var pending: ModelRef?

    private var shown: ModelRef? { pending ?? current }

    var body: some View {
        Group {
            if models.isEmpty {
                TronPlaceholderState(title: "No available memory models", detail: "Register a physical model on this Gateway.",
                                     icon: "cpu")
            } else {
                ModelPicker(selection: Binding(get: { shown }, set: { choose($0) }),
                            models: models, selectionAvailability: availability)
            }
        }
        .onChange(of: current) { _, value in
            if value == pending { pending = nil }
        }
        .tronNavigationTitle("Memory Model", accent: .tronPurple)
        .environment(\.tronSettingsSecondaryTextSizeAdjustment, 0)
        .controlSize(.regular)
        .alert("Home change", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func choose(_ selection: ModelRef?) {
        // Receipt retirement is not projection convergence: the installed status must
        // own the current intent, so a choice is refused until it is available.
        guard availability.canSelect, let selection, selection != shown,
              models.contains(where: { $0.ref == selection }),
              let identity = model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token),
              let coordinator,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        pending = selection
        Task { @MainActor in
            do {
                try await model.performHomeControl(.configureMemory(selection), authority: authority)
                guard coordinator.activity(for: identity.surfaceToken).allowsDataPublication else { return }
                failure = nil
                onApplied()
            } catch {
                pending = nil
                guard coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
    }
}
