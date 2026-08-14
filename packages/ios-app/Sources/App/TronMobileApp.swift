import SwiftUI

@main
struct TronMobileApp: App {
    @State private var model = AppModel()
    @State private var appearance = AppearanceSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    private let pendingShares = UserDefaultsPendingShareStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tronPresentation()
                .preferredColorScheme(appearance.mode.colorScheme)
                .task {
                    await RetiredNotificationBadge.clear()
                    await model.start()
                }
                .onOpenURL { url in
                    if let invitation = PairingInvitationParser.parse(url) {
                        Task {
                            do { try await model.pair(invitation) }
                            catch is CancellationError { return }
                            catch { model.lastError = error.localizedDescription }
                        }
                    } else if url.host == "share", let shared = pendingShares.load()?.buildSharePrompt() {
                        pendingShares.clear()
                        Task { try? await model.send(shared.prompt) }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await RetiredNotificationBadge.clear() }
                        model.becameActive()
                    }
                }
        }
    }

}

private struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var onboardingDetent: PresentationDetent = .medium
    @State private var showOnboarding = false

    var body: some View {
        SessionShellView()
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(selectedDetent: $onboardingDetent) {
                showOnboarding = false
            }
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large], selection: $onboardingDetent)
                .presentationDragIndicator(.hidden)
                .presentationContentInteraction(.resizes)
                .interactiveDismissDisabled()
        }
        .background(Color.tronBackground.ignoresSafeArea())
        .onAppear { syncOnboardingPresentation() }
        .onChange(of: model.connectionState) { _, _ in syncOnboardingPresentation() }
        .onChange(of: model.hasResolvedLaunchState) { _, _ in syncOnboardingPresentation() }
        .alert("Tron", isPresented: Binding(
            get: { !showOnboarding && model.lastError != nil },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private func syncOnboardingPresentation() {
        showOnboarding = OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: model.hasResolvedLaunchState,
            connectionState: model.connectionState,
            setupComplete: model.setupComplete
        )
    }
}

enum OnboardingPresentationPolicy {
    static func shouldPresent(
        hasResolvedLaunchState: Bool,
        connectionState: AppModel.ConnectionState,
        setupComplete: Bool
    ) -> Bool {
        guard hasResolvedLaunchState else { return false }
        return connectionState == .unpaired
            || connectionState == .unauthorized
            || !setupComplete
    }
}
