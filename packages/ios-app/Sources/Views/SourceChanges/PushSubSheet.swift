import SwiftUI

// MARK: - Push Sub-Sheet

/// Pushes the current session branch to origin. Force-with-lease is tucked
/// behind an Advanced disclosure to keep the default path safe and simple.
@available(iOS 26.0, *)
struct PushSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let currentBranch: String
    let defaultAutoSetUpstream: Bool

    @State private var branch: String = ""
    @State private var setUpstream: Bool = true
    @State private var showAdvanced: Bool = false
    @State private var forceWithLease: Bool = false
    @State private var dryRun: Bool = false
    @State private var isPushing = false
    @State private var result: GitPushResult?
    @State private var errorMessage: String?

    private let accent: Color = .tronSky

    var body: some View {
        GitSubSheetContainer(title: "Push", accent: accent) {
            GitHeroCard(
                icon: "arrow.up.circle",
                title: "Push \(pushBranch)",
                description: "Pushes the session branch to origin. Force-with-lease is available behind Advanced; protected branches always require explicit override.",
                accent: accent
            )

            branchCard
            upstreamCard
            advancedCard

            GitActionButton(
                title: isPushing ? "Pushing…" : (dryRun ? "Dry Run" : "Push"),
                icon: "arrow.up",
                accent: accent,
                isBusy: isPushing,
                isEnabled: !isPushing
            ) { performPush() }

            if let result {
                resultBanner(result)
            }
        }
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
        }
    }

    private var upstreamCard: some View {
        SettingsCard(accent: accent) {
            SettingsRow(icon: "link", label: "Set Upstream", accentColor: accent) {
                Toggle("", isOn: $setUpstream)
                    .labelsHidden()
                    .tint(accent)
            }
        }
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Text("Advanced")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .rotationEffect(.degrees(showAdvanced ? -180 : 0))
                }
                .padding(.bottom, 8)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                SettingsCard(accent: accent) {
                    VStack(spacing: 0) {
                        SettingsRow(icon: "bolt.shield", label: "Force with Lease", accentColor: .tronAmber) {
                            Toggle("", isOn: $forceWithLease)
                                .labelsHidden()
                                .tint(.tronAmber)
                        }
                        SettingsRowDivider()
                        SettingsRow(icon: "eye", label: "Dry Run", accentColor: accent) {
                            Toggle("", isOn: $dryRun)
                                .labelsHidden()
                                .tint(accent)
                        }
                    }
                }
                SettingsCaption(text: "Force-with-lease safely rewrites remote history only if nobody else has pushed since your last fetch.")
            }
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
