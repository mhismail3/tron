import SwiftUI

/// Body-free Home metadata. Response cancellation is injected by ChatView so
/// the menu and composer always use the same canonical operation authority.
struct HomeChatHeader: View {
    let status: HomeStatusDTO
    /// The mounted chat owns this identity; a delayed menu callback must not
    /// acquire authority from a successor profile selected in the meantime.
    let profileID: String
    let canStop: Bool
    let onStop: () -> Void
    /// The chat presents Home sheets: this header is removed while the projection
    /// is cleared (a connection change), and a sheet must outlive that.
    let onPresent: (HomeSheetDestination) -> Void
    @Environment(AppModel.self) private var model
    @State private var failure: String?
    #if HOSTED_TEST
    @Environment(\.hostedHomeHeaderActionProbe) private var hostedActionProbe
    #endif

    private var stateLabel: String {
        switch status.phase {
        case .ready: "Ready"
        case .active: "Working"
        case .paused: "Paused"
        case .blocked: status.memory.configured ? "Memory blocked" : "Memory setup needed"
        case .rolloverPending, .missingSession, .unavailable: "Recovery needed"
        case .disabled: "Disabled"
        case .undesignated: "Not set up"
        }
    }

    private var memoryLabel: String {
        if model.homeMutations.hasUnresolvedCommand { return "Home change unresolved · Check completion" }
        if status.memory.paused == true { return "Memory paused · New responses are blocked" }
        if let blocked = status.memory.blocked { return "Memory blocked · \(blocked)" }
        if !status.memory.configured { return "Choose a memory model before sending" }
        return status.memory.open ? "Memory available" : "Memory configured"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Home · \(stateLabel)")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronEmerald)
                    .accessibilityIdentifier("home-header-state")
                Text(memoryLabel)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home-header-memory")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Memory settings", systemImage: "cpu") { onPresent(.settings) }
                if status.taskRecovery != nil {
                    Button("Tasks and permissions", systemImage: "checklist") { onPresent(.tasks) }
                }
                Button("Home context", systemImage: "doc.text.magnifyingglass") { onPresent(.context) }
                if model.gatewayInfo?.capabilities.contains("home-memory-browser.v1") == true {
                    Button("Browse memory", systemImage: "brain") { onPresent(.memory) }
                }
                Button("Stop response", systemImage: "stop.fill", action: onStop)
                    .disabled(!canStop)
                Group {
                if model.homeMutations.hasUnresolvedCommand {
                    Button("Check completion", systemImage: "arrow.clockwise") { checkCompletion() }
                } else {
                    if status.memory.paused == true || status.memory.blocked != nil {
                        Button("Resume memory", systemImage: "play.fill") { perform(.resumeMemory) }
                    }
                    if status.memory.paused != true {
                        Button("Pause memory", systemImage: "pause.fill") { perform(.pauseMemory) }
                            .disabled(!status.memory.configured)
                    }
                    Button("Disable Home", systemImage: "house.slash", role: .destructive) { perform(.disable) }
                }
                }
                .disabled(model.homeMutations.isRunning)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(TronTypography.headline)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Home controls")
            .accessibilityIdentifier("home-controls")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: 12, tintOpacity: 0.14)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .alert("Home change", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        #if HOSTED_TEST
        .onAppear { hostedActionProbe?.pause = { perform(.pauseMemory) } }
        #endif
        .onChange(of: model.homeMutations.hasUnresolvedCommand) { _, unresolved in
            if unresolved { failure = "Completion is unresolved. Check completion on the original Gateway; do not repeat the change." }
        }
    }

    private func perform(_ command: HomeMutationCoordinator.Command) {
        // An unstructured accepted domain task is intentionally not a View.task:
        // navigation/background retires reads, not command receipt ownership.
        guard let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        Task { @MainActor in
            do { try await model.performHomeControl(command, authority: authority) }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }

    private func checkCompletion() {
        guard let authority = try? model.homeMutations.authority(profileID: profileID) else { return }
        Task { @MainActor in
            do { try await model.checkHomeControlCompletion(authority: authority) }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
