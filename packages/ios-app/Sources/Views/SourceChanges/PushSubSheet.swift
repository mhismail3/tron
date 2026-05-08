import SwiftUI

// MARK: - Push Branch Sub-Sheet

/// Pushes the current session branch to origin. All options (Set Upstream,
/// Force with Lease, Dry Run) are surfaced as separate containers with
/// per-option subtext so the reader never has to guess what each toggle does.
///
/// Primary action lives in the trailing toolbar slot; the leading `xmark`
/// dismisses the sheet. Protected branches always require an explicit
/// server-side override (not exposed in the UI today).
@available(iOS 26.0, *)
struct PushSubSheet: View {
    let engineClient: EngineClient
    let sessionId: String
    let currentBranch: String
    let defaultAutoSetUpstream: Bool

    @State private var branch: String = ""
    @State private var setUpstream: Bool = true
    @State private var forceWithLease: Bool = false
    @State private var dryRun: Bool = false
    @State private var runner = GitActionRunner<GitPushResult>()
    @Environment(\.dismiss) private var dismiss

    private let accent: Color = .tronSky

    var body: some View {
        GitSubSheetContainer(
            title: "Push Branch",
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: dryRun ? "eye" : "arrow.up",
                    accent: accent,
                    isBusy: runner.isRunning,
                    isEnabled: runner.isEnabled && hasBranch,
                    accessibilityLabel: dryRun ? "Dry Run Push" : "Push"
                ) { performPush() }
            },
            content: {
                GitHeroCard(
                    icon: "arrow.up.circle",
                    title: heroTitle,
                    description: heroDescription,
                    accent: accent
                )

                branchCard
                upstreamCard
                forceWithLeaseCard
                dryRunCard

                if let result = runner.result {
                    resultBanner(result)
                }
            }
        )
        .tronErrorAlert(message: $runner.errorMessage)
        .task {
            branch = currentBranch
            setUpstream = defaultAutoSetUpstream
        }
    }

    private var pushBranch: String {
        let t = branch.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? currentBranch : t
    }

    /// Whether we have a real branch name to push. Empty pushBranch can
    /// happen briefly before the task() populates it, or if the server
    /// fails to resolve the session's current branch (detached HEAD). The
    /// hero switches to a prompt-to-pick phrasing instead of producing
    /// "Push  to origin" with dangling empty strings.
    private var hasBranch: Bool {
        !pushBranch.isEmpty
    }

    // MARK: Dynamic Hero Summary

    private var heroTitle: String {
        guard hasBranch else {
            return dryRun ? "Dry-run push" : "Push branch"
        }
        return dryRun ? "Dry-run push \(pushBranch)" : "Push \(pushBranch)"
    }

    /// Real-time summary that reflects every toggle change. Protected-branch
    /// caveat stays pinned since it's always true on the server.
    private var heroDescription: String {
        let target = hasBranch ? pushBranch : "the selected branch"
        let upstreamTarget = hasBranch ? "origin/\(pushBranch)" : "the remote branch"
        let action = dryRun
            ? "Simulates a push of \(target) to origin without touching the remote"
            : "Pushes \(target) to origin"

        var modifiers: [String] = []
        if setUpstream {
            modifiers.append("sets the upstream to \(upstreamTarget)")
        }
        if forceWithLease {
            modifiers.append("force-with-lease rewrites remote history if nobody else has pushed since your last fetch")
        }

        var sentence = action
        if !modifiers.isEmpty {
            sentence += ", " + modifiers.joined(separator: ", and ")
        }
        sentence += ". Protected branches always require an explicit override."
        if !hasBranch {
            sentence = "Pick a branch to push. " + sentence
        }
        return sentence
    }

    // MARK: Cards

    private var branchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Branch")
            SettingsCard(accent: accent) {
                BranchPickerField(
                    engineClient: engineClient,
                    sessionId: sessionId,
                    accent: accent,
                    placeholder: currentBranch,
                    selection: $branch,
                    source: .local
                )
            }
            SettingsCaption(text: "Defaults to the current session branch. Any local branch can be pushed.")
        }
    }

    private var upstreamCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "link", label: "Set upstream", accentColor: accent) {
                    Toggle("", isOn: $setUpstream)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: "Configures the branch to track its remote counterpart so future pushes and pulls don't need a target.")
        }
    }

    private var forceWithLeaseCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "bolt.shield", label: "Force with lease", accentColor: .tronAmber) {
                    Toggle("", isOn: $forceWithLease)
                        .labelsHidden()
                        .tint(.tronAmber)
                }
            }
            SettingsCaption(text: "Safely rewrites remote history only if nobody else has pushed since your last fetch.")
        }
    }

    private var dryRunCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "eye", label: "Dry run", accentColor: accent) {
                    Toggle("", isOn: $dryRun)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: "Simulates the push and reports what would happen without touching the remote.")
        }
    }

    private func resultBanner(_ r: GitPushResult) -> some View {
        // Reaching here means the server returned success — any failure
        // throws a typed engine protocol error that the catch block renders as an
        // alert, not a banner.
        let detail: String = {
            var parts: [String] = []
            if r.dryRun { parts.append("Dry run — no remote state changed.") }
            if r.setUpstream { parts.append("Upstream set to \(r.remote)/\(r.branch).") }
            if let stderr = r.stderr, !stderr.isEmpty {
                parts.append(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return parts.joined(separator: "\n")
        }()
        return GitResultBanner(
            kind: .success,
            title: "Pushed \(r.branch) → \(r.remote)",
            detail: detail.isEmpty ? nil : detail
        )
    }

    // MARK: Actions

    private func performPush() {
        // Real pushes auto-dismiss; dry-runs stay open. The contract is
        // captured by GitPushResult.isCleanSuccess.
        Task {
            await runner.run(action: .push, dismiss: { dismiss() }) {
                try await engineClient.git.push(
                    sessionId: sessionId,
                    branch: pushBranch,
                    remote: nil,
                    forceWithLease: forceWithLease ? true : nil,
                    setUpstream: setUpstream,
                    dryRun: dryRun ? true : nil,
                    overrideProtected: nil,
                    protectedBranches: nil,
                    idempotencyKey: .userAction("git.push")
                )
            }
        }
    }
}
