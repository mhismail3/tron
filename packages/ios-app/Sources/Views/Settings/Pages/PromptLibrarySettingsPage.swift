import SwiftUI

/// Settings page for the Prompt Library.
///
/// Server-authoritative fields live under `settings.json > promptLibrary`
/// (see `packages/agent/src/settings/types/prompt_library.rs`). Changes
/// round-trip via `settings.update { promptLibrary: ... }`.
struct PromptLibrarySettingsPage: View {
    @Bindable var settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void
    let rpcClient: RPCClient

    @State private var isClearingHistory = false
    @State private var showClearAlert = false
    @State private var clearResultMessage: String?

    var body: some View {
        SettingsPageContainer(title: "Prompt Library") {
            historyEnabledCard
            limitsCard
            autoPruneCard
            dangerZoneCard
        }
        .alert(
            clearResultMessage ?? "",
            isPresented: Binding(
                get: { clearResultMessage != nil },
                set: { if !$0 { clearResultMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { clearResultMessage = nil }
        }
        .alert("Clear all history?", isPresented: $showClearAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { Task { await clearHistory() } }
        } message: {
            Text("This permanently removes every entry in your prompt history.")
        }
    }

    // MARK: - History Enabled

    private var historyEnabledCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Capture")

            SettingsCard {
                SettingsRow(icon: "clock.arrow.circlepath", label: "Record prompt history") {
                    Toggle("", isOn: $settingsState.promptHistoryEnabled)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            }
            .onChange(of: settingsState.promptHistoryEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(promptLibrary: .init(historyEnabled: newValue))
                }
            }

            SettingsCaption(text: "When off, new prompts are not saved. Existing history is retained until cleared.")
        }
    }

    // MARK: - Limits

    private var maxEntriesDisplay: String {
        settingsState.promptHistoryMaxEntries == 0 ? "Unlimited" : "\(settingsState.promptHistoryMaxEntries)"
    }

    private var maxAgeDisplay: String {
        settingsState.promptHistoryMaxAgeDays == 0 ? "Unlimited" : "\(settingsState.promptHistoryMaxAgeDays)d"
    }

    private var limitsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Retention")

            SettingsCard {
                SettingsRow(icon: "tray.full", label: "Max Entries") {
                    Text(maxEntriesDisplay)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                    TronStepper(
                        value: $settingsState.promptHistoryMaxEntries,
                        range: 0...100_000,
                        step: 1_000
                    )
                }
                .onChange(of: settingsState.promptHistoryMaxEntries) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(promptLibrary: .init(historyMaxEntries: newValue))
                    }
                }

                SettingsRowDivider()

                SettingsRow(icon: "calendar", label: "Max Age (days)") {
                    Text(maxAgeDisplay)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)
                    TronStepper(
                        value: $settingsState.promptHistoryMaxAgeDays,
                        range: 0...365,
                        step: 7
                    )
                }
                .onChange(of: settingsState.promptHistoryMaxAgeDays) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(promptLibrary: .init(historyMaxAgeDays: newValue))
                    }
                }
            }

            SettingsCaption(text: "0 means unlimited. Retention rules only apply when auto-prune is enabled.")
        }
    }

    // MARK: - Auto Prune

    private var autoPruneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Auto-Prune")

            SettingsCard {
                SettingsRow(icon: "scissors", label: "Prune on record / startup") {
                    Toggle("", isOn: $settingsState.promptHistoryAutoPrune)
                        .labelsHidden()
                        .tint(.tronEmerald)
                }
            }
            .onChange(of: settingsState.promptHistoryAutoPrune) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(promptLibrary: .init(historyAutoPrune: newValue))
                }
            }

            SettingsCaption(text: "Opportunistically remove entries that exceed the retention limits.")
        }
    }

    // MARK: - Danger Zone

    private var dangerZoneCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Danger Zone", color: .tronError)

            SettingsCard(accent: .tronError) {
                Button {
                    showClearAlert = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronError)
                            .frame(width: 18)
                        Text("Clear History Now")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronError)
                        Spacer()
                        if isClearingHistory {
                            ProgressView().tint(.tronError).scaleEffect(0.7)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isClearingHistory)
            }

            SettingsCaption(text: "Permanently removes every prompt-history entry on the server.")
        }
    }

    private func clearHistory() async {
        isClearingHistory = true
        do {
            let result = try await rpcClient.promptLibrary.clearHistory()
            clearResultMessage = "Cleared \(result.deletedCount) entr\(result.deletedCount == 1 ? "y" : "ies")."
        } catch {
            clearResultMessage = "Failed to clear history: \(error.localizedDescription)"
        }
        isClearingHistory = false
    }
}
