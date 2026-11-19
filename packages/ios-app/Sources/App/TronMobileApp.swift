import SwiftUI
import UIKit
import TronMobileCore

@main
struct TronMobileApp: App {
    #if HOSTED_TEST
    @State private var hostedModel: AppModel

    init() {
        HostedPresentationProbe.installIdleCapture()
        if ProcessInfo.processInfo.environment["TRON_UI_LOCK_RENDERING"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
        _hostedModel = State(initialValue: AppModel())
        HostedFixtureRoot.prepareLaunch()
    }

    var body: some Scene {
        WindowGroup {
            HostedFixtureRoot(hostedModel: hostedModel)
        }
    }
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var scene: ProductionSceneOwner

    init() {
        let store = IOSClientDiagnosticStore(defaults: .standard)
        let model = AppModel(client: GatewayClient(diagnosticStore: store), diagnosticStore: store,
                             notificationInbox: NotificationInboxCoordinator(defaults: .standard))
        _scene = State(initialValue: ProductionSceneOwner(model: model))
    }

    var body: some Scene {
        WindowGroup {
            ProductionSceneRoot(owner: scene, pushDelegate: appDelegate)
        }
    }
    #endif
}

#if HOSTED_TEST
struct HostedFixtureRoot: View {
    let hostedModel: AppModel

    private struct HostedProductionScene: View {
        @StateObject private var owner: ProductionSceneOwner

        init(model: AppModel) {
            _owner = StateObject(wrappedValue: ProductionSceneOwner(model: model))
        }

        var body: some View {
            ProductionSceneRoot(owner: owner, pushDelegate: nil)
        }
    }

    static func prepareLaunch() {
        if !HostedLaunch.arguments.contains("-preserve-dashboard-preferences") {
            DashboardServerFilterPreferences.save(DashboardServerFilterState(
                sortMode: HostedLaunch.arguments.contains("-dashboard-view-home") ? .home : .projectServer
            ))
        }
        UserDefaults.standard.removeObject(forKey: HomeUsageCardPreferences.hiddenProvidersKey)
    }

    var body: some View {
        Group {
            if HostedLaunch.arguments.contains("-tron-idle-control") {
                HostedIdleControlFixture()
            } else if HostedLaunch.arguments.contains("-tron-tool-sheets-polish-fixture") {
                HostedToolSheetsPolishFixture().environment(hostedModel)
            } else if HostedLaunch.arguments.contains("-tron-home-dashboard-fixture") {
                HostedHomeDashboardFixture()
            } else if HostedLaunch.arguments.contains("-tron-snapshot-cache-fixture") {
                HostedSnapshotCacheFixture()
            } else if HostedLaunch.arguments.contains("-tron-session-configuration-fixture") {
                HostedSessionConfigurationFixture()
            } else if HostedLaunch.arguments.contains("-tron-project-trust-fixture") {
                HostedProjectTrustFixture()
            } else if HostedLaunch.arguments.contains("-tron-subagent-parity-fixture") {
                HostedSubagentParityFixture()
            } else if HostedLaunch.arguments.contains("-tron-new-session-fixture") {
                HostedNewSessionFixture()
            } else if HostedLaunch.arguments.contains("-tron-composer-upload-fixture") {
                HostedComposerUploadFixture()
            } else if HostedLaunch.arguments.contains("-tron-subsheet-reliability-fixture") {
                HostedSubsheetReliabilityFixture()
            } else if HostedLaunch.arguments.contains("-tron-interaction-haptics-fixture") {
                HostedInteractionHapticsFixture()
            } else if HostedLaunch.arguments.contains("-tron-chat-haptics-fixture") {
                HostedChatHapticsFixture()
            } else if HostedLaunch.arguments.contains("-tron-notification-inbox-fixture") {
                HostedNotificationInboxFixture()
            } else if HostedLaunch.arguments.contains("-tron-recovery-notice-fixture") {
                HostedRecoveryNoticeFixture()
            } else if HostedLaunch.arguments.contains("-tron-keychain-locked-fixture") {
                HostedProductionScene(model: HostedKeychainLockedFixture.model)
                    .overlay(alignment: .bottom) { HostedKeychainLockedFixture.ConnectionState() }
            } else if HostedLaunch.arguments.contains("-tron-readonly-attachment-fixture") {
                HostedReadonlyAttachmentFixture()
            } else if HostedLaunch.arguments.contains("-tron-chat-display-fixture") {
                HostedChatDisplayFixture()
            } else if HostedLaunch.arguments.contains("-tron-chat-annotation-fixture") {
                HostedChatAnnotationFixture()
            } else if HostedLaunch.arguments.contains("-tron-ask-user-fixture") {
                HostedAskUserFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-session-pagination-fixture") {
                HostedSessionPaginationFixture()
            } else if HostedLaunch.arguments.contains("-tron-apps-install-design-fixture") {
                HostedAppsInstallDesignFixture().environment(hostedModel)
            } else if HostedLaunch.arguments.contains("-tron-apps-design-fixture") {
                HostedAppsDesignFixture().environment(hostedModel)
            } else if HostedLaunch.arguments.contains("-tron-automation-fixture") {
                HostedAutomationFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-session-archive-fixture") {
                HostedSessionArchiveFixture()
            } else if HostedLaunch.arguments.contains("-tron-home-summary-typography-fixture") {
                HostedHomeSummaryTypographyFixture()
            } else if HostedLaunch.arguments.contains("-tron-session-row-clock-fixture") {
                HostedSessionRowClockFixture()
            } else if HostedLaunch.arguments.contains("-tron-integrations-fixture") {
                HostedIntegrationsFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-dashboard-menu-fixture") {
                HostedDashboardMenuFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-accessibility-fixture") {
                HostedAccessibilityFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-settings-navigation-fixture") {
                SettingsView()
                    .environment(hostedModel)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .preferredColorScheme(.light)
            } else if HostedLaunch.arguments.contains("-tron-mac-settings-fixture") {
                HostedSettingsFixture()
            } else if HostedLaunch.arguments.contains("-tron-extension-widgets-fixture") {
                HostedExtensionWidgetsFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-agent-instructions-fixture") {
                HostedAgentInstructionsFixtureView()
            } else if HostedLaunch.arguments.contains("-tron-mac-terminal-fixture") {
                HostedMacTerminalFixture()
            } else if HostedLaunch.arguments.contains("-tron-settings-fixture") {
                HostedSettingsFixture()
            } else {
                HostedProductionScene(model: hostedModel)
            }
        }
        .modifier(TronSheetLoadingHostModifier())
        .modifier(TronPresentationStateRoot())
    }
}
#endif

struct SceneRootView: View {
    let model: AppModel
    let colorScheme: ColorScheme?
    @State private var presentationActivity = PresentationActivityCoordinator()

    var body: some View {
        RootView()
            .modifier(TronSheetLoadingHostModifier())
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
            .modifier(TronPresentationStateRoot())
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
            identity: "app.onboarding",
            presentationHaptic: nil
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
