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
            if let controlFailure {
                TronPlaceholderState(title: "Home change", detail: controlFailure, icon: "exclamationmark.triangle")
            }
            HomeContextSummaryCard(snapshot: sessionID.flatMap { model.sessionContextPresentation(for: $0) }, read: read)
            if let sessionID { ManageModelConfigurationCard(sessionID: sessionID, home: true) }
            manageRows(read, unresolved: unresolved)
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
            }
        }
    }

    var manageStatus: HomeStatus? {
        guard case .manage = destination else { return nil }
        switch owner.state {
        case .loaded(let read, .manage(let manage)), .loading(let read, .some(.manage(let manage))):
            return read.identity.profileID == profileID && read.identity.surfaceToken == token ? manage.status : nil
        default: return nil
        }
    }

    @ViewBuilder func manageControls(_ status: HomeStatus) -> some View {
        let mutating = model.homeMutations.isRunning(profileID: profileID)
        if model.homeMutations.ownsUnresolvedCommand(profileID: profileID) {
            controlButton("arrow.clockwise", label: "Check completion", id: "home-manage-check-completion") { checkControlCompletion() }
                .disabled(mutating)
        } else {
            let resumes = status.memory.paused == true || status.memory.blocked != nil
            let memory: HomeManagePendingControl.Kind = resumes ? .resume : .pause
            controlButton(memory.icon, label: memory.confirmTitle, id: "home-manage-\(memory.rawValue)") { confirmControl(memory) }
                .disabled(mutating || (!resumes && !status.memory.configured))
            controlButton("house.slash", label: "Disable Home", role: .destructive, id: "home-manage-disable") { confirmControl(.disable) }
                .disabled(mutating)
        }
    }

    private func controlButton(_ icon: String, label: String, role: TronToolbarActionRole = .standard, id: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(TronTypography.buttonSM).tronToolbarAction(accent: accent, role: role)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    func controlConfirmation(_ pending: HomeManagePendingControl) -> some View {
        TronConfirmationSheet(
            title: pending.kind.title,
            message: pending.kind.message,
            confirmTitle: pending.kind.confirmTitle,
            destructiveGlyph: pending.kind == .disable ? "trash" : nil,
            icon: pending.kind.icon,
            onConfirm: { runControl(pending.kind.command, pending.admission) }
        )
    }

    private func controlAdmission() -> HomeControlAdmission? {
        guard let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return nil }
        return HomeControlAdmission(identity: identity, coordinator: coordinator, authority: authority)
    }

    private func controlPublishes(_ admission: HomeControlAdmission) -> Bool {
        identity == admission.identity && admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication
    }

    private func confirmControl(_ kind: HomeManagePendingControl.Kind) {
        guard let admission = controlAdmission() else { return }
        pendingControl = HomeManagePendingControl(kind: kind, admission: admission)
    }

    #if HOSTED_TEST
    func performControl(_ command: HomeMutationCoordinator.Command) {
        guard let admission = controlAdmission() else { return }
        runControl(command, admission)
    }
    #endif

    private func runControl(_ command: HomeMutationCoordinator.Command, _ admission: HomeControlAdmission) {
        settleControl(admission) { try await model.performHomeControl(command, authority: admission.authority) }
    }

    private func checkControlCompletion() {
        guard let admission = controlAdmission() else { return }
        settleControl(admission) { try await model.checkHomeControlCompletion(authority: admission.authority) }
    }

    private func settleControl(_ admission: HomeControlAdmission, _ operation: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
                guard controlPublishes(admission) else { return }
                controlFailure = nil
                reload()
            } catch {
                guard controlPublishes(admission), !(error is CancellationError) else { return }
                controlFailure = error.localizedDescription
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

struct HomeManagePendingControl: Identifiable {
    enum Kind: String {
        case pause, resume, disable

        var command: HomeMutationCoordinator.Command {
            switch self {
            case .pause: .pauseMemory
            case .resume: .resumeMemory
            case .disable: .disable
            }
        }

        var icon: String {
            switch self {
            case .pause: "pause"
            case .resume: "play"
            case .disable: "house.slash"
            }
        }

        var confirmTitle: String {
            switch self {
            case .pause: "Pause memory"
            case .resume: "Resume memory"
            case .disable: "Disable Home"
            }
        }

        var title: String { "\(confirmTitle)?" }

        var message: String {
            switch self {
            case .pause: "New responses are blocked while paused."
            case .resume: ""
            case .disable: "Activations stop. Home's history is preserved."
            }
        }
    }

    let kind: Kind
    let admission: HomeControlAdmission
    var id: String { kind.rawValue }
}
