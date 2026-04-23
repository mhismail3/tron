import SwiftUI

/// Settings page for the user-mode auto-updater (Phase 5.5).
///
/// Server-authoritative fields live under `settings.json > server.update`
/// (see `packages/agent/src/settings/types/server.rs::UpdateSettings` and
/// `packages/agent/src/server/updater/mod.rs`). Round-trip via
/// `settings.update { server: { update: ... } }`.
///
/// Layout:
/// - Enabled toggle (master switch; when off, no other control has any
///   server-side effect but we keep them interactive so the user can
///   configure before opting in).
/// - Channel cycle (`stable` / `beta`).
/// - Frequency cycle (`manual` / `startup` / `hourly` / `daily` / `weekly`).
/// - Action cycle (`notify` / `download` / `install`).
/// - Rollback-on-failure toggle.
/// - Manual check button (fires `system.checkForUpdates` — wired in the
///   Phase 5.5 RPC layer; this view invokes the RPC client and surfaces
///   the result inline).
struct UpdatesSettingsPage: View {
    @Bindable var settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void
    let rpcClient: RPCClient

    @State private var isCheckingForUpdates = false
    @State private var checkResultMessage: String?
    @State private var isInstallingUpdate = false

    var body: some View {
        SettingsPageContainer(title: "Updates") {
            masterToggleCard
            channelCard
            frequencyCard
            actionCard
            safetyCard
            manualCheckCard
        }
        .alert(
            checkResultMessage ?? "",
            isPresented: Binding(
                get: { checkResultMessage != nil },
                set: { if !$0 { checkResultMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { checkResultMessage = nil }
        }
    }

    // MARK: - Master Toggle

    private var masterToggleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Auto-Update")

            SettingsCard {
                SettingsRow(icon: "arrow.down.app", label: "Automatically check for updates") {
                    Toggle("", isOn: Binding(
                        get: { settingsState.updateEnabled },
                        set: { newValue in
                            settingsState.updateEnabled = newValue
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(enabled: newValue)))
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: "When off, the server never contacts GitHub Releases. Opt in to be notified of new versions.")
        }
    }

    // MARK: - Channel

    private var channelCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Channel")

            SettingsCard {
                SettingsRow(icon: "shippingbox", label: "Release channel") {
                    SettingsCycleToggle(
                        options: UpdateChannel.allCases.map { ($0.rawValue, $0.displayName) },
                        current: settingsState.updateChannel
                    ) { newValue in
                        settingsState.updateChannel = newValue
                        if let channel = UpdateChannel.from(newValue) {
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(channel: channel)))
                            }
                        }
                    }
                }
            }

            SettingsCaption(text: "Stable tracks only `latest` GitHub releases. Beta also includes pre-release tags (e.g. `mac-v0.5.0-beta.1`).")
        }
    }

    // MARK: - Frequency

    private var frequencyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Frequency")

            SettingsCard {
                SettingsRow(icon: "clock.arrow.2.circlepath", label: "Check for updates") {
                    SettingsCycleToggle(
                        options: UpdateFrequency.allCases.map { ($0.rawValue, $0.displayName) },
                        current: settingsState.updateFrequency
                    ) { newValue in
                        settingsState.updateFrequency = newValue
                        if let frequency = UpdateFrequency.from(newValue) {
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(frequency: frequency)))
                            }
                        }
                    }
                }
            }

            SettingsCaption(text: "Manual means only the button below (and the Mac menu bar) fire checks. Startup checks once per server launch.")
        }
    }

    // MARK: - Action

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "When an update is available")

            SettingsCard {
                SettingsRow(icon: "tray.and.arrow.down", label: "Action") {
                    SettingsCycleToggle(
                        options: UpdateAction.allCases.map { ($0.rawValue, $0.displayName) },
                        current: settingsState.updateAction
                    ) { newValue in
                        settingsState.updateAction = newValue
                        if let action = UpdateAction.from(newValue) {
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(action: action)))
                            }
                        }
                    }
                }
            }

            SettingsCaption(text: "Notify surfaces a banner. Download stages the DMG and verifies its codesign. Install atomically swaps the binary with rollback on failure.")
        }
    }

    // MARK: - Safety

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Safety")

            SettingsCard {
                SettingsRow(icon: "arrow.uturn.backward.circle", label: "Auto-rollback on failed install") {
                    Toggle("", isOn: Binding(
                        get: { settingsState.updateAllowDowngradeOnRollback },
                        set: { newValue in
                            settingsState.updateAllowDowngradeOnRollback = newValue
                            updateServerSetting {
                                ServerSettingsUpdate(server: .init(update: .init(allowDowngradeOnRollback: newValue)))
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(.tronEmerald)
                }
            }

            SettingsCaption(text: "If a freshly-installed version fails its post-install self-test, revert to the previous binary. After 3 consecutive failures the action auto-downgrades to Notify.")
        }
    }

    // MARK: - Manual Check

    private var manualCheckCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Manual Check")

            SettingsCard(interactive: true) {
                Button {
                    Task { await checkForUpdatesNow() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text("Check now")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronTextPrimary)
                        Spacer()
                        if isCheckingForUpdates {
                            ProgressView().tint(.tronEmerald).scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isCheckingForUpdates)
            }

            SettingsCaption(text: "Contacts GitHub Releases now regardless of the schedule. Cached 60s server-side to avoid API rate-limit thrash.")
        }
    }

    // MARK: - Actions

    private func checkForUpdatesNow() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            let result = try await rpcClient.misc.checkForUpdates()
            if result.available, let latest = result.latestVersion {
                checkResultMessage = "Update available: \(latest)"
            } else {
                checkResultMessage = "You're up to date."
            }
        } catch {
            checkResultMessage = "Check failed: \(error.localizedDescription)"
        }
    }
}
