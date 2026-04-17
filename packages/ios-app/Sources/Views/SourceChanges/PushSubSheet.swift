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
    let rpcClient: RPCClient
    let sessionId: String
    let currentBranch: String
    let defaultAutoSetUpstream: Bool

    @State private var branch: String = ""
    @State private var setUpstream: Bool = true
    @State private var forceWithLease: Bool = false
    @State private var dryRun: Bool = false
    @State private var isPushing = false
    @State private var result: GitPushResult?
    @State private var errorMessage: String?

    private let accent: Color = .tronSky

    var body: some View {
        GitSubSheetContainer(
            title: "Push Branch",
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: dryRun ? "eye" : "arrow.up",
                    accent: accent,
                    isBusy: isPushing,
                    isEnabled: !isPushing,
                    accessibilityLabel: dryRun ? "Dry Run Push" : "Push"
                ) { performPush() }
            },
            content: {
                GitHeroCard(
                    icon: "arrow.up.circle",
                    title: "Push \(pushBranch)",
                    description: "Pushes the session branch to origin. Protected branches always require an explicit override.",
                    accent: accent
                )

                branchCard
                upstreamCard
                forceWithLeaseCard
                dryRunCard

                if let result {
                    resultBanner(result)
                }
            }
        )
        .tronErrorAlert(message: $errorMessage)
        .task {
            branch = currentBranch
            setUpstream = defaultAutoSetUpstream
        }
    }

    private var pushBranch: String {
        let t = branch.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? currentBranch : t
    }

    // MARK: Cards

    private var branchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Branch")
            SettingsCard(accent: accent) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(accent)
                        .frame(width: 18)
                    TextField(currentBranch, text: $branch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            SettingsCaption(text: "Defaults to the current session branch.")
        }
    }

    private var upstreamCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(accent: accent) {
                SettingsRow(icon: "link", label: "Set Upstream", accentColor: accent) {
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
                SettingsRow(icon: "bolt.shield", label: "Force with Lease", accentColor: .tronAmber) {
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
                SettingsRow(icon: "eye", label: "Dry Run", accentColor: accent) {
                    Toggle("", isOn: $dryRun)
                        .labelsHidden()
                        .tint(accent)
                }
            }
            SettingsCaption(text: "Simulates the push and reports what would happen without touching the remote.")
        }
    }

    private func resultBanner(_ r: GitPushResult) -> some View {
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
            kind: r.success ? .success : .failure,
            title: r.success ? "Pushed \(r.branch) → \(r.remote)" : "Push rejected",
            detail: detail.isEmpty ? nil : detail
        )
    }

    // MARK: Actions

    private func performPush() {
        Task {
            isPushing = true
            defer { isPushing = false }
            result = nil
            do {
                result = try await rpcClient.git.push(
                    sessionId: sessionId,
                    branch: pushBranch,
                    remote: nil,
                    forceWithLease: forceWithLease ? true : nil,
                    setUpstream: setUpstream,
                    dryRun: dryRun ? true : nil,
                    overrideProtected: nil,
                    protectedBranches: nil
                )
            } catch {
                errorMessage = "Push failed: \(error.localizedDescription)"
            }
        }
    }
}
