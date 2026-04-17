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
                    cycleToggle(
                        values: ["merge", "rebase", "squash"],
                        labels: ["Merge", "Rebase", "Squash"],
                        current: settingsState.gitMergeStrategy
                    ) { newValue in
                        settingsState.gitMergeStrategy = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(git: .init(mergeStrategy: newValue))
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
                    cycleToggle(
                        values: ["keep", "deleteOnFinalize"],
                        labels: ["Keep", "Delete"],
                        current: settingsState.gitSessionBranchPolicy
                    ) { newValue in
                        settingsState.gitSessionBranchPolicy = newValue
                        updateServerSetting {
                            ServerSettingsUpdate(git: .init(sessionBranchPolicy: newValue))
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
                timeoutRow(
                    icon: "network",
                    label: "Network Op",
                    valueMs: Binding(
                        get: { settingsState.gitOpTimeoutNetworkMs },
                        set: { settingsState.gitOpTimeoutNetworkMs = $0 }
                    ),
                    step: 15_000,
                    range: 15_000...600_000
                ) { newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(opTimeoutNetworkMs: newValue))
                    }
                }

                SettingsRowDivider()

                timeoutRow(
                    icon: "cpu",
                    label: "Local Op",
                    valueMs: Binding(
                        get: { settingsState.gitOpTimeoutLocalMs },
                        set: { settingsState.gitOpTimeoutLocalMs = $0 }
                    ),
                    step: 5_000,
                    range: 5_000...300_000
                ) { newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(git: .init(opTimeoutLocalMs: newValue))
                    }
                }

                SettingsRowDivider()

                timeoutRow(
                    icon: "exclamationmark.arrow.triangle.2.circlepath",
                    label: "Crash Recovery",
                    valueMs: Binding(
                        get: { settingsState.gitCrashRecoveryAbortTimeoutMs },
                        set: { settingsState.gitCrashRecoveryAbortTimeoutMs = $0 }
                    ),
                    step: 5 * 60 * 1000,
                    range: (5 * 60 * 1000)...(4 * 60 * 60 * 1000)
                ) { newValue in
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

    private func timeoutRow(
        icon: String,
        label: String,
        valueMs: Binding<UInt64>,
        step: UInt64,
        range: ClosedRange<UInt64>,
        onChange: @escaping (UInt64) -> Void
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
            Spacer()
            Text(formatMs(valueMs.wrappedValue))
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
            Button {
                let next = valueMs.wrappedValue >= range.lowerBound + step
                    ? valueMs.wrappedValue - step : range.lowerBound
                valueMs.wrappedValue = max(range.lowerBound, next)
                onChange(valueMs.wrappedValue)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.tronEmerald)
            }
            .buttonStyle(.plain)
            Button {
                let next = valueMs.wrappedValue + step
                valueMs.wrappedValue = min(range.upperBound, next)
                onChange(valueMs.wrappedValue)
            } label: {
                Image(systemName: "plus.circle")
                    .foregroundStyle(.tronEmerald)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
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

    private func cycleToggle(
        values: [String],
        labels: [String],
        current: String,
        onCycle: @escaping (String) -> Void
    ) -> some View {
        let idx = values.firstIndex(of: current) ?? 0
        return Button {
            let next = values[(idx + 1) % values.count]
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                onCycle(next)
            }
        } label: {
            HStack(spacing: 4) {
                Text(labels[idx])
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeXS, weight: .medium))
            }
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.tronEmerald.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
