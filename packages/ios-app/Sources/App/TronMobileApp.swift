import SwiftUI
import TronMobileCore

@main
struct TronMobileApp: App {
    #if HOSTED_TEST
    /// The hosted app's no-fixture arm: the production scene, built by the one
    /// owner the shipping arm also builds. Only this arm constructs that owner -
    /// and with it the push coordinator and the path observer - so every fixture
    /// arm below stays inert.
    private struct HostedProductionScene: View {
        @StateObject private var owner: ProductionSceneOwner

        init(model: AppModel) {
            _owner = StateObject(wrappedValue: ProductionSceneOwner(model: model))
        }

        var body: some View {
            ProductionSceneRoot(owner: owner, pushDelegate: nil)
        }
    }

    @State private var hostedModel: AppModel

    init() {
        // The fixture arms keep their own hosted views and this memory-only
        // model; the no-fixture arm renders the production scene with the same
        // owner the shipping app builds (`ProductionSceneRoot`).
        _hostedModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-tron-home-dashboard-fixture") {
                HostedHomeDashboardFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-configuration-fixture") {
                HostedSessionConfigurationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-diagnostics-export-fixture") {
                HostedDiagnosticsExportFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-project-trust-fixture") {
                HostedProjectTrustFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-subagent-parity-fixture") {
                HostedSubagentParityFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-subagent-sheet-fixture") {
                HostedSubagentSheetFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-new-session-fixture") {
                HostedNewSessionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-readonly-attachment-fixture") {
                HostedReadonlyAttachmentFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-chat-display-fixture") {
                HostedChatDisplayFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-ask-user-fixture") {
                HostedAskUserFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-pagination-fixture") {
                HostedSessionPaginationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-automation-fixture") {
                HostedAutomationFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-archive-fixture") {
                HostedSessionArchiveFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-knowledge-detail-fixture") {
                HostedKnowledgeDetailFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-integrations-fixture") {
                HostedIntegrationsFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-dashboard-menu-fixture") {
                HostedDashboardMenuFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-accessibility-fixture") {
                HostedAccessibilityFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-settings-navigation-fixture") {
                SettingsView()
                    .environment(hostedModel)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .preferredColorScheme(.light)
            } else if ProcessInfo.processInfo.arguments.contains("-tron-agent-defaults-fixture") {
                NavigationStack { AgentDefaultsSettingsView(projectCWD: nil) }
                    .environment(hostedModel)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .tronSettingsVisualTheme(accent: .tronPurple)
            } else if ProcessInfo.processInfo.arguments.contains("-tron-extension-widgets-fixture") {
                HostedExtensionWidgetsFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-agent-instructions-fixture") {
                HostedAgentInstructionsFixtureView()
            } else {
                HostedProductionScene(model: hostedModel)
            }
        }
    }
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var scene: ProductionSceneOwner

    init() {
        // Incident retention is explicitly composed by the production app owner;
        // tests and scripted clients remain memory-only unless they inject a sink.
        // Everything else the scene needs is built by its one owner below.
        let store = IOSClientDiagnosticStore(defaults: .standard)
        let model = AppModel(client: GatewayClient(diagnosticStore: store), diagnosticStore: store,
                             notificationInbox: NotificationInboxCoordinator(defaults: .standard))
        _scene = State(initialValue: ProductionSceneOwner(model: model))
    }

    var body: some Scene {
        WindowGroup {
            // The production scene, composed once in `ProductionSceneOwner`, so
            // the app a real-UI journey drives is the app the user runs.
            ProductionSceneRoot(owner: scene, pushDelegate: appDelegate)
        }
    }
    #endif
}

// Internal rather than private: the production scene owner composes it.
struct SceneRootView: View {
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
        .background(TronBackdrop().ignoresSafeArea())
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
