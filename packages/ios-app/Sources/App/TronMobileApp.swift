import SwiftUI
import UIKit
import TronMobileCore

@main
struct TronMobileApp: App {
    #if HOSTED_TEST
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
        if ProcessInfo.processInfo.environment["TRON_UI_LOCK_RENDERING"] == "1" {
            UIView.setAnimationsEnabled(false)
        }
        _hostedModel = State(initialValue: AppModel())
        if !ProcessInfo.processInfo.arguments.contains("-preserve-dashboard-preferences") {
            DashboardServerFilterPreferences.save(DashboardServerFilterState(
                sortMode: ProcessInfo.processInfo.arguments.contains("-dashboard-view-home") ? .home : .projectServer
            ))
        }
        UserDefaults.standard.removeObject(forKey: HomeUsageCardPreferences.hiddenProvidersKey)
    }

    var body: some Scene {
        WindowGroup {
            Group {
            if ProcessInfo.processInfo.arguments.contains("-tron-tool-sheets-polish-fixture") {
                HostedToolSheetsPolishFixture().environment(hostedModel)
            } else if ProcessInfo.processInfo.arguments.contains("-tron-home-dashboard-fixture") {
                HostedHomeDashboardFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-snapshot-cache-fixture") {
                HostedSnapshotCacheFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-configuration-fixture") {
                HostedSessionConfigurationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-diagnostics-export-fixture") {
                HostedDiagnosticsExportFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-project-trust-fixture") {
                HostedProjectTrustFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-subagent-parity-fixture") {
                HostedSubagentParityFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-new-session-fixture") {
                HostedNewSessionFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-composer-upload-fixture") {
                HostedComposerUploadFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-subsheet-reliability-fixture") {
                HostedSubsheetReliabilityFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-interaction-haptics-fixture") {
                HostedInteractionHapticsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-chat-haptics-fixture") {
                HostedChatHapticsFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-notification-inbox-fixture") {
                HostedNotificationInboxFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-recovery-notice-fixture") {
                HostedRecoveryNoticeFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-keychain-locked-fixture") {
                HostedProductionScene(model: HostedKeychainLockedFixture.model)
                    .overlay(alignment: .bottom) { HostedKeychainLockedFixture.ConnectionState() }
            } else if ProcessInfo.processInfo.arguments.contains("-tron-readonly-attachment-fixture") {
                HostedReadonlyAttachmentFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-chat-display-fixture") {
                HostedChatDisplayFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-chat-annotation-fixture") {
                HostedChatAnnotationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-ask-user-fixture") {
                HostedAskUserFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-pagination-fixture") {
                HostedSessionPaginationFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-apps-install-design-fixture") {
                HostedAppsInstallDesignFixture().environment(hostedModel)
            } else if ProcessInfo.processInfo.arguments.contains("-tron-apps-design-fixture") {
                HostedAppsDesignFixture().environment(hostedModel)
            } else if ProcessInfo.processInfo.arguments.contains("-tron-automation-fixture") {
                HostedAutomationFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-archive-fixture") {
                HostedSessionArchiveFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-home-summary-typography-fixture") {
                HostedHomeSummaryTypographyFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-session-row-clock-fixture") {
                HostedSessionRowClockFixture()
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
            } else if ProcessInfo.processInfo.arguments.contains("-tron-mac-settings-fixture") {
                HostedSettingsRendererFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-extension-widgets-fixture") {
                HostedExtensionWidgetsFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-agent-instructions-fixture") {
                HostedAgentInstructionsFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-mac-terminal-fixture") {
                HostedMacTerminalFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-settings-list-refresh-fixture") {
                HostedSettingsListRefreshFixture()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-settings-renderer-fixture") {
                HostedSettingsRendererFixture()
            } else {
                HostedProductionScene(model: hostedModel)
            }
            }
            .modifier(TronSheetLoadingHostModifier())
            .modifier(TronPresentationStateRoot())
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
