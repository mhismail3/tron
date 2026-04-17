import SwiftUI

// MARK: - Finalize Session Sub-Sheet

/// Merges the session branch into main (or the configured target branch) and
/// rebranches the worktree onto a fresh session branch for continued work.
///
/// On conflicts, the sub-sheet swaps its payload to the `ConflictResolverSubSheet`
/// flow, keeping the user in the same sheet for the full resolution cycle.
@available(iOS 26.0, *)
struct FinalizeSessionSubSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let suggestedTargetBranch: String?
    let defaultStrategy: String
    let defaultSessionBranchPolicy: String
    var onConflicts: ((WorktreeFinalizeSessionResult) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var targetBranch: String = ""
    @State private var strategy: MergeStrategy = .merge
    @State private var deleteOldBranch: Bool = false
    @State private var isFinalizing = false
    @State private var result: WorktreeFinalizeSessionResult?
    @State private var errorMessage: String?

    private let accent: Color = .tronCoral

    enum MergeStrategy: String, CaseIterable, Identifiable {
        case merge, rebase, squash
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .merge: "arrow.triangle.merge"
            case .rebase: "arrow.triangle.2.circlepath"
            case .squash: "square.stack.3d.down.forward"
            }
        }
    }

    var body: some View {
        GitSubSheetContainer(title: "Finalize Session", accent: accent) {
            GitHeroCard(
                icon: "checkmark.seal",
                title: "Merge to \(displayTarget)",
                description: "Merges this session's work into \(displayTarget), then creates a fresh session branch so new changes stay isolated.",
                accent: accent
            )

            targetBranchCard
            strategyCard
            policyCard

            GitActionButton(
                title: isFinalizing ? "Finalizing…" : "Finalize",
                icon: "checkmark.seal",
                accent: accent,
                isBusy: isFinalizing,
                isEnabled: !isFinalizing && result == nil
            ) { performFinalize() }

            if let result {
                if result.conflicts == true {
                    GitResultBanner(
                        kind: .warning,
                        title: "Conflicts detected",
                        detail: result.error ?? "Launch the Conflict Resolver to continue."
                    )
                    Button {
                        dismiss()
                        onConflicts?(result)
                    } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Open Conflict Resolver")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        }
                        .foregroundStyle(.tronRose)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.tronRose.opacity(0.12))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    finalizeSuccessBanner(result)
                }
            }
        }
        .tronErrorAlert(message: $errorMessage)
        .task {
            targetBranch = suggestedTargetBranch ?? ""
            strategy = MergeStrategy(rawValue: defaultStrategy) ?? .merge
            deleteOldBranch = (defaultSessionBranchPolicy == "deleteOnFinalize")
        }
    }

    private var displayTarget: String {
        let t = targetBranch.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? (suggestedTargetBranch ?? "main") : t
    }

    // MARK: Cards

    private var targetBranchCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Target Branch")
            SettingsCard(accent: accent) {
                BranchPickerField(
                    rpcClient: rpcClient,
                    sessionId: sessionId,
                    accent: accent,
                    placeholder: "main",
                    selection: $targetBranch
                )
            }
        }
    }

    private var strategyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Merge Strategy")
            SettingsCard(accent: accent) {
                HStack(spacing: 0) {
                    ForEach(MergeStrategy.allCases) { s in
                        Button {
                            strategy = s
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: s.icon)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody3))
                                Text(s.label)
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            }
                            .foregroundStyle(strategy == s ? accent : .tronTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background {
                                if strategy == s {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(accent.opacity(0.15))
                                        .padding(4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var policyCard: some View {
        SettingsCard(accent: accent) {
            SettingsRow(icon: "trash", label: "Delete Old Session Branch", accentColor: accent) {
                Toggle("", isOn: $deleteOldBranch)
                    .labelsHidden()
                    .tint(accent)
            }
        }
    }

    @ViewBuilder
    private func finalizeSuccessBanner(_ r: WorktreeFinalizeSessionResult) -> some View {
        let detail = successDetail(r)
        GitResultBanner(
            kind: .success,
            title: "Finalized to \(displayTarget)",
            detail: detail.isEmpty ? nil : detail
        )
        if deleteOldBranch, r.oldBranchDeleted == false {
            GitResultBanner(
                kind: .warning,
                title: "Old branch not deleted",
                detail: r.oldBranchDeleteError ?? "Git refused to delete the old session branch."
            )
        }
    }

    private func successDetail(_ r: WorktreeFinalizeSessionResult) -> String {
        var detail = ""
        if let newBranch = r.newBranch {
            detail += "New session branch: \(newBranch)"
        }
        if let commit = r.mergeCommit {
            if !detail.isEmpty { detail += "\n" }
            detail += "Merge commit: \(String(commit.prefix(7)))"
        }
        return detail
    }

    // MARK: Actions

    private func performFinalize() {
        Task {
            isFinalizing = true
            defer { isFinalizing = false }
            result = nil
            do {
                let trimmed = targetBranch.trimmingCharacters(in: .whitespaces)
                let r = try await rpcClient.worktree.finalizeSession(
                    sessionId: sessionId,
                    targetBranch: trimmed.isEmpty ? nil : trimmed,
                    strategy: strategy.rawValue,
                    preserveOld: !deleteOldBranch
                )
                result = r
            } catch {
                errorMessage = "Finalize failed: \(error.localizedDescription)"
            }
        }
    }
}
