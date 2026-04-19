import SwiftUI

/// Settings page for the git workflow suite (sync, finalize, switch, push,
/// conflict resolution).
///
/// Every control here has a 1:1 server field under `settings.json > git`
/// (see `settings/types/git.rs`). Changes round-trip via
/// `settings.update { git: ... }`.
struct GitWorkflowSettingsPage: View {
    @Bindable var settingsState: SettingsState
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @State private var newProtectedBranch: String = ""

    var body: some View {
        SettingsPageContainer(title: "Git Workflow") {
            targetBranchCard
            mergeStrategyCard
            gitIsolationCard
            sessionBranchPolicyCard
            protectedBranchesCard
            toggleCard
            timeoutsCard
        }
    }

    // MARK: - Target Branch

    private var targetBranchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Target Branch")

            SettingsCard {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    TextField(
                        "auto-detect (main/master)",
                        text: $settingsState.gitTargetBranch
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .onSubmit { pushTargetBranch() }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: "Override for `git.syncMain` / `worktree.finalizeSession`. Leave blank to probe `init.defaultBranch` then `main` then `master`.")
        }
    }

    private func pushTargetBranch() {
        let trimmed = settingsState.gitTargetBranch.trimmingCharacters(in: .whitespaces)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        updateServerSetting {
            ServerSettingsUpdate(git: .init(targetBranch: value))
        }
    }

    // MARK: - Merge Strategy

    private var mergeStrategyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Default Merge Strategy")

            SettingsCard {
                HStack {
                    Image(systemName: "arrow.triangle.merge")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Strategy")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    SettingsCycleToggle(
                        options: [("merge", "Merge"), ("rebase", "Rebase"), ("squash", "Squash")],
                        current: settingsState.gitMergeStrategy
                    ) { newValue in
                        settingsState.gitMergeStrategy = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(git: .init(mergeStrategy: GitMergeStrategy.from(newValue)))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: mergeStrategyCaption)
        }
    }

    private var mergeStrategyCaption: String {
        switch settingsState.gitMergeStrategy {
        case "rebase": return "Replay session commits on top of the target branch (linear history)."
        case "squash": return "Collapse all session commits into a single merge commit."
        default:       return "Standard `git merge --no-ff` with a dedicated merge commit."
        }
    }

    // MARK: - Git Isolation

    private var isolationDescription: String {
        let mode: String
        switch settingsState.isolationMode {
        case "always":
            mode = "Every session in a git repo gets its own worktree branch."
        case "lazy":
            mode = "Only create worktrees when multiple sessions target the same repo."
        case "never":
            mode = "Never create worktrees. All sessions work in the main working tree."
        default:
            return ""
        }
        return "\(mode) Override per session in the New Session sheet."
    }

    private var gitIsolationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Git Isolation")

            SettingsCard {
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Isolation Mode")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    SettingsCycleToggle(
                        options: [("always", "Always"), ("lazy", "Lazy"), ("never", "Never")],
                        current: settingsState.isolationMode
                    ) { newValue in
                        settingsState.isolationMode = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(session: .init(isolation: .init(mode: IsolationMode.from(newValue))))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: isolationDescription)
        }
    }

    // MARK: - Session Branch Policy

    private var sessionBranchPolicyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "After Finalize")

            SettingsCard {
                HStack {
                    Image(systemName: "checkmark.seal")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)
                    Text("Source Branch")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    Spacer()
                    SettingsCycleToggle(
                        options: [("keep", "Keep"), ("deleteOnFinalize", "Delete")],
                        current: settingsState.gitSessionBranchPolicy
                    ) { newValue in
                        settingsState.gitSessionBranchPolicy = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(git: .init(sessionBranchPolicy: GitSessionBranchPolicy.from(newValue)))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }

            SettingsCaption(text: settingsState.gitSessionBranchPolicy == "deleteOnFinalize"
                             ? "The old session branch is deleted once the merge and follow-up branch succeed."
                             : "The old session branch is preserved after finalize — you can delete it manually later.")
        }
    }

    // MARK: - Protected Branches

    private var protectedBranchesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Protected Branches")

            SettingsCard {
                VStack(spacing: 0) {
                    ForEach(settingsState.gitProtectedBranches, id: \.self) { branch in
                        HStack {
                            Image(systemName: "lock.shield")
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                                .foregroundStyle(.tronEmerald)
                                .frame(width: 18)
                            Text(branch)
                                .font(TronTypography.sans(size: TronTypography.sizeBody))
                            Spacer()
                            Button {
                                removeProtected(branch)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.tronError)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        if branch != settingsState.gitProtectedBranches.last {
                            SettingsRowDivider()
                        }
                    }

                    if !settingsState.gitProtectedBranches.isEmpty {
                        SettingsRowDivider()
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        TextField("add branch name", text: $newProtectedBranch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .onSubmit(addProtected)
                        Button("Add", action: addProtected)
                            .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                            .disabled(newProtectedBranch.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }

            SettingsCaption(text: "Pushes to these branches require an explicit override on the server. The `git.push` RPC without `overrideProtected` fails fast.")
        }
    }

    private func addProtected() {
        let name = newProtectedBranch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !settingsState.gitProtectedBranches.contains(name) else { return }
        settingsState.gitProtectedBranches.append(name)
        newProtectedBranch = ""
        pushProtectedBranches()
    }

    private func removeProtected(_ branch: String) {
        settingsState.gitProtectedBranches.removeAll(where: { $0 == branch })
        pushProtectedBranches()
    }

    private func pushProtectedBranches() {
        let list = settingsState.gitProtectedBranches
        updateServerSetting {
            ServerSettingsUpdate(git: .init(protectedBranches: list))
        }
    }

    // MARK: - Toggles

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Behavior")

            SettingsCard {
                toggleRow(
                    icon: "arrow.up.to.line",
                    label: "Auto Set-Upstream",
                    isOn: $settingsState.gitAutoSetUpstream
                ) { newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(autoSetUpstream: newValue))
                    }
                }

                SettingsRowDivider()

                toggleRow(
                    icon: "sparkles",
                    label: "Subagent Conflict Resolution",
                    isOn: $settingsState.gitSubagentConflictResolutionEnabled
                ) { newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(subagentConflictResolutionEnabled: newValue))
                    }
                }
            }

            SettingsCaption(text: "The conflict resolver subagent is only spawned after you tap \"Let it run\" in the Source Control sheet — this toggle only controls whether the offer appears at all.")
        }
    }

    // MARK: - Timeouts

    private var timeoutsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Timeouts")

            SettingsCard {
                SettingsRow(icon: "network", label: "Network Op") {
                    Text(formatMs(settingsState.gitOpTimeoutNetworkMs))
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                    TronStepper(
                        value: msBinding(\.gitOpTimeoutNetworkMs),
                        range: 15_000...600_000,
                        step: 15_000
                    )
                }
                .onChange(of: settingsState.gitOpTimeoutNetworkMs) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(opTimeoutNetworkMs: newValue))
                    }
                }

                SettingsRowDivider()

                SettingsRow(icon: "cpu", label: "Local Op") {
                    Text(formatMs(settingsState.gitOpTimeoutLocalMs))
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                    TronStepper(
                        value: msBinding(\.gitOpTimeoutLocalMs),
                        range: 5_000...300_000,
                        step: 5_000
                    )
                }
                .onChange(of: settingsState.gitOpTimeoutLocalMs) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(opTimeoutLocalMs: newValue))
                    }
                }

                SettingsRowDivider()

                SettingsRow(icon: "exclamationmark.arrow.triangle.2.circlepath", label: "Crash Recovery") {
                    Text(formatMs(settingsState.gitCrashRecoveryAbortTimeoutMs))
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                    TronStepper(
                        value: msBinding(\.gitCrashRecoveryAbortTimeoutMs),
                        range: (5 * 60 * 1000)...(4 * 60 * 60 * 1000),
                        step: 5 * 60 * 1000
                    )
                }
                .onChange(of: settingsState.gitCrashRecoveryAbortTimeoutMs) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(crashRecoveryAbortTimeoutMs: newValue))
                    }
                }
            }

            SettingsCaption(text: "Pending merges recovered on server restart auto-abort after the crash-recovery timeout if the user takes no action.")
        }
    }

    // MARK: - Helpers

    private func toggleRow(
        icon: String,
        label: String,
        isOn: Binding<Bool>,
        onChange: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.tronEmerald)
                .onChange(of: isOn.wrappedValue) { _, newValue in
                    onChange(newValue)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    /// Bridge a `UInt64` millisecond setting to the `Int` binding `TronStepper` expects.
    /// All git timeout ranges fit well within `Int`.
    private func msBinding(_ keyPath: ReferenceWritableKeyPath<SettingsState, UInt64>) -> Binding<Int> {
        Binding(
            get: { Int(settingsState[keyPath: keyPath]) },
            set: { settingsState[keyPath: keyPath] = UInt64($0) }
        )
    }

    private func formatMs(_ ms: UInt64) -> String {
        let seconds = ms / 1000
        if seconds >= 3600 {
            let hours = Double(seconds) / 3600.0
            return String(format: "%.1fh", hours)
        }
        if seconds >= 60 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }

}
