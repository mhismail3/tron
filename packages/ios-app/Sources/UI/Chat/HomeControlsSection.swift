import SwiftUI
import TronMobileCore

/// Pause, resume and disable, the last section of Home Settings. It owns its own
/// `home.status` read, fenced to the Home Settings surface, and re-reads after each
/// command; receipted commands stay with `HomeMutationCoordinator`. Disable needs
/// confirmation; an unresolved command leaves only the completion check.
struct HomeControlsSection: View {
    let profileID: String
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @Environment(\.tronPresentationActivity) private var activity
    @PresentationState private var owner = HomeSheetReadOwner()
    @PresentationState private var requestID = UUID()
    @PresentationState private var failure: String?
    @PresentationState private var confirmingDisable = false
    @PresentationState private var disableAdmission: HomeControlAdmission?
    #if HOSTED_TEST
    @Environment(\.hostedHomeActionProbe) private var hostedActionProbe
    #endif

    private var identity: HomeSheetReadIdentity? { model.homeSheetReadIdentity(profileID: profileID, surfaceToken: token) }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private struct TaskID: Hashable { let identity: HomeSheetReadIdentity?; let request: UUID; let active: Bool }

    var body: some View {
        Group {
            switch owner.state {
            case .idle, .loading(_, nil):
                TronLoadingState(label: "Loading Home…", accent: .tronSlate)
            case .failed(_, let message):
                TronPlaceholderState(title: "Home could not be read", detail: message, icon: "exclamationmark.triangle",
                                     actionTitle: "Reload") { requestID = UUID() }
            case .loaded(let read, .status(let status)), .loading(let read, .some(.status(let status))):
                if read.identity.profileID == profileID && read.identity.surfaceToken == token {
                    controls(status)
                }
            case .loaded, .loading:
                EmptyView()
            }
            if let failure {
                TronPlaceholderState(title: "Home change", detail: failure, icon: "exclamationmark.triangle")
            }
        }
        .task(id: TaskID(identity: identity, request: requestID, active: active)) {
            guard active, let identity, let coordinator else { owner.retireLoading(); return }
            let currentID = requestID
            // Uncovering keeps the installed status; only a new request reads again.
            if owner.holds(requestID: currentID, identity: identity) { return }
            await owner.load(requestID: currentID, identity: identity, coordinator: coordinator,
                             isCurrent: { self.identity == identity && self.requestID == currentID }) {
                try await model.readHomeSheet(.status, identity: identity, isCurrent: { self.requestID == currentID && self.active })
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
        .onPresentationRetire { owner.retire() }
        #if HOSTED_TEST
        // Retains the mounted pause action so hosted journeys can invoke it after
        // a route replacement; the identity fences inside `perform` must refuse it.
        .onAppear { hostedActionProbe?.pause = { perform(.pauseMemory) } }
        #endif
    }

    /// Pause reads as a neutral, reversible hold in the paused-state slate;
    /// Disable keeps its destructive red.
    private func controls(_ status: HomeStatusDTO) -> some View {
        let unresolved = model.homeMutations.ownsUnresolvedCommand(profileID: profileID)
        let mutating = model.homeMutations.isRunning(profileID: profileID)
        return TronGlassCard(accent: .tronSlate) {
            VStack(spacing: 0) {
                if !unresolved {
                    if status.memory.paused == true || status.memory.blocked != nil {
                        Button { perform(.resumeMemory) } label: {
                            TronSettingsRow(icon: "play.fill", title: "Resume memory", accent: .tronSlate)
                        }
                        .buttonStyle(.plain)
                        .disabled(mutating)
                        .accessibilityIdentifier("home-manage-resume")
                        TronSettingsDivider(accent: .tronSlate)
                    }
                    if status.memory.paused != true {
                        Button { perform(.pauseMemory) } label: {
                            TronSettingsRow(icon: "pause.fill", title: "Pause memory",
                                            subtitle: "New responses are blocked while paused", accent: .tronSlate,
                                            titleColor: .tronSlate, subtitleColor: .tronSlate)
                                .tronSettingsVisualTheme(accent: .tronSlate)
                        }
                        .buttonStyle(.plain)
                        .disabled(mutating || !status.memory.configured)
                        .accessibilityIdentifier("home-manage-pause")
                        TronSettingsDivider(accent: .tronSlate)
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
                            .tronSettingsVisualTheme(accent: .tronError)
                    }
                    .buttonStyle(.plain)
                    .disabled(mutating)
                    .accessibilityIdentifier("home-manage-disable")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-settings-controls")
    }

    /// Accepted domain commands keep the chat's authority rules: acquire once
    /// for the mounted profile, then let the coordinator own receipt resolution.
    private func admitControl() -> HomeControlAdmission? {
        guard let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return nil }
        return HomeControlAdmission(identity: identity, coordinator: coordinator, authority: authority)
    }

    private func perform(_ command: HomeMutationCoordinator.Command) {
        guard let admission = admitControl() else { return }
        run(command, admission)
    }

    private func run(_ command: HomeMutationCoordinator.Command, _ admission: HomeControlAdmission) {
        Task { @MainActor in
            do {
                try await model.performHomeControl(command, authority: admission.authority)
                guard self.identity == admission.identity,
                      admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication else { return }
                failure = nil
                requestID = UUID()
            } catch {
                guard self.identity == admission.identity,
                      admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func checkCompletion() {
        guard let identity, let coordinator, active,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        Task { @MainActor in
            do {
                try await model.checkHomeControlCompletion(authority: authority)
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication else { return }
                failure = nil
                requestID = UUID()
            } catch {
                guard self.identity == identity, coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
                      !(error is CancellationError) else { return }
                failure = error.localizedDescription
            }
        }
    }
}
