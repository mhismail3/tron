import SwiftUI

@main
struct TronMobileApp: App {
    #if HOSTED_TEST
    var body: some Scene {
        WindowGroup {
            HostedTestRootView()
        }
    }
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var appearance = AppearanceSettings.shared
    @State private var backgroundCheckpoints = AppBackgroundCheckpointCoordinator()
    @State private var pushNotifications = PushNotificationCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    private let pendingShares = UserDefaultsPendingShareStore()

    var body: some Scene {
        WindowGroup {
            SceneRootView(
                model: model,
                colorScheme: appearance.mode.colorScheme
            )
                .environment(model)
                .environment(pushNotifications)
                .tronPresentation()
                .preferredColorScheme(appearance.mode.colorScheme)
                .task {
                    configurePushNotifications()
                    await RetiredNotificationBadge.clear()
                    await model.start(sceneIsActive: scenePhase == .active)
                    await reconcilePushNotifications()
                }
                .onChange(of: model.connectionState) { _, _ in
                    Task { await reconcilePushNotifications() }
                }
                .onChange(of: model.profileRevision) { _, _ in
                    Task { await reconcilePushNotifications() }
                }
                .onChange(of: pushNotifications.readiness) { _, readiness in
                    model.pushNotificationReadiness = readiness
                    model.pushRegistrationDiagnostic = pushNotifications.diagnostic
                }
                .onChange(of: pushNotifications.diagnostic) { _, diagnostic in
                    model.pushRegistrationDiagnostic = diagnostic
                }
                .onOpenURL { url in
                    if let invitation = PairingInvitationParser.parse(url) {
                        Task {
                            do { try await model.pair(invitation) }
                            catch is CancellationError { return }
                            catch { model.presentError(error) }
                        }
                    } else if url.host == "share",
                              let shared = pendingShares.load()?.buildSharePrompt(),
                              let target = model.mountedPresentationTarget {
                        Task {
                            do {
                                try await model.sendSharedContent(shared.prompt, target: target)
                                pendingShares.clear()
                            } catch is CancellationError {
                                return
                            } catch {
                                model.presentError(error)
                            }
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await RetiredNotificationBadge.clear()
                            await reconcilePushNotifications()
                        }
                        model.becameActive()
                    } else if phase == .inactive {
                        model.becameInactive()
                    } else if phase == .background {
                        backgroundCheckpoints.retain(model.enteredBackground())
                    }
                }
        }
    }

    @MainActor
    private func configurePushNotifications() {
        appDelegate.onDeviceToken = { token in
            pushNotifications.receiveDeviceToken(token)
        }
        appDelegate.onRegistrationFailure = {
            pushNotifications.receiveRegistrationFailure()
        }
        appDelegate.installNotificationTapHandler { tap in
            model.requestPushNavigation(tap)
        }
    }

    @MainActor
    private func reconcilePushNotifications() async {
        await pushNotifications.reconcile(
            profile: model.profiles.selected,
            connected: model.connectionState == .connected,
            client: model.client
        )
        model.pushNotificationReadiness = pushNotifications.readiness
        model.pushRegistrationDiagnostic = pushNotifications.diagnostic
    }
    #endif
}

#if HOSTED_TEST
private struct HostedTestRootView: View {
    var body: some View {
        Color.clear
            .accessibilityIdentifier("tron.hosted-test-root")
    }
}
#endif

private struct SceneRootView: View {
    let model: AppModel
    let colorScheme: ColorScheme?
    @State private var presentationActivity = PresentationActivityCoordinator()

    var body: some View {
        RootView()
            .background {
                InAppNoticeWindowInstaller(
                    model: model,
                    colorScheme: colorScheme,
                    presentationActivity: presentationActivity
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .environment(\.tronPresentationActivityCoordinator, presentationActivity)
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var onboardingDetent: PresentationDetent = .medium
    @State private var showOnboarding = false

    var body: some View {
        SessionShellView()
        .tronManagedSheet(
            isPresented: $showOnboarding,
            identity: "app.onboarding"
        ) {
            OnboardingView(selectedDetent: $onboardingDetent) {
                showOnboarding = false
            }
                .presentationDetents([.medium, .large], selection: $onboardingDetent)
                .presentationDragIndicator(.hidden)
                .presentationContentInteraction(.resizes)
                .interactiveDismissDisabled()
        }
        .background(Color.tronBackground.ignoresSafeArea())
        .onAppear { syncOnboardingPresentation() }
        .onChange(of: model.connectionState) { _, _ in syncOnboardingPresentation() }
        .onChange(of: model.hasResolvedLaunchState) { _, _ in syncOnboardingPresentation() }
    }

    private func syncOnboardingPresentation() {
        showOnboarding = OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: model.hasResolvedLaunchState,
            connectionState: model.connectionState,
            setupComplete: model.setupComplete,
            suppressSetup: model.isAddingServer
        )
    }
}

enum OnboardingPresentationPolicy {
    static func shouldPresent(
        hasResolvedLaunchState: Bool,
        connectionState: AppModel.ConnectionState,
        setupComplete: Bool,
        suppressSetup: Bool = false
    ) -> Bool {
        guard hasResolvedLaunchState, !suppressSetup else { return false }
        return connectionState == .unpaired
            || connectionState == .unauthorized
            || !setupComplete
    }
}
