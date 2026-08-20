import SwiftUI

struct NewSessionQuickSelection: Identifiable, Hashable, Sendable {
    let path: String
    let projectName: String
    let serverID: String
    let serverName: String

    var id: String { "\(serverID)|\(path)" }
}

struct NewSessionSourceControlSheet: View {
    @Binding var selection: SessionSourceControlSelection
    let inspection: GitInspection?
    let inspectionFailed: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    TronSettingsGroup(
                        "Checkout Strategy",
                        detail: inspectionDetail,
                        detailRole: .dynamicValue,
                        accent: .tronTeal
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(SessionSourceControlMode.allCases.enumerated()), id: \.element) { index, mode in
                                if index > 0 { TronSettingsDivider() }
                                Button { choose(mode) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: selection.mode == mode ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selection.mode == mode ? Color.tronTeal : Color.tronTextMuted)
                                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                            .frame(width: 22)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(mode.title)
                                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                                .foregroundStyle(Color.tronTextPrimary)
                                            Text(mode.summary)
                                                .font(TronTypography.secondaryDescription)
                                                .foregroundStyle(Color.tronTextSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(mode != .existingCheckout && (inspectionFailed || inspection?.isRepository != true))
                            }
                        }
                    }

                    if selection.mode != .existingCheckout {
                        TronSettingsGroup(
                            selection.mode == .newBranchWorktree ? "New Branch" : "Existing Branch",
                            detail: branchDetail,
                            accent: .tronTeal
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField(
                                    selection.mode == .newBranchWorktree ? "feature/my-work" : "Branch name",
                                    text: branchBinding
                                )
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(TronTypography.codeContent)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .glassEffect(
                                    .regular.tint(Color.tronTeal.opacity(0.10)).interactive(),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )

                                if selection.mode == .newBranchWorktree {
                                    TextField(
                                        "Start from current commit",
                                        text: baseBinding
                                    )
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .font(TronTypography.codeContent)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 44)
                                    .glassEffect(
                                        .regular.tint(Color.tronTeal.opacity(0.10)).interactive(),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                }
                            }
                            .padding(12)
                        }
                    }

                    if let inspection, inspection.isRepository, inspection.isDirty,
                       selection.mode == .newBranchWorktree,
                       selection.base?.isEmpty != false {
                        Label(
                            "The selected checkout has uncommitted changes. Choose a committed base branch before creating a worktree.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronAmber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(20)
                .padding(.bottom, 28)
            }
            .tronScrollEdgeChrome()
            .tronNavigationTitle("Source Control")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
    }

    private var inspectionDetail: String {
        if inspectionFailed { return "Git inspection failed. Use the existing checkout or try again after reconnecting." }
        guard let inspection else { return "Checking the selected workspace…" }
        guard inspection.isRepository else { return "The selected workspace is not a Git repository." }
        let branch = inspection.branch ?? "detached HEAD"
        return "Current branch: \(branch)"
    }

    private var branchDetail: String {
        switch selection.mode {
        case .newBranchWorktree:
            return "A new worktree is created outside the checkout. Leave the base empty to use the current commit when clean."
        case .existingBranchWorktree:
            return "The branch must exist locally and not already be checked out by another worktree."
        case .existingCheckout:
            return ""
        }
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: { selection.branch ?? "" },
            set: { selection.branch = $0 }
        )
    }

    private var baseBinding: Binding<String> {
        Binding(
            get: { selection.base ?? "" },
            set: { selection.base = $0.isEmpty ? nil : $0 }
        )
    }

    private func choose(_ mode: SessionSourceControlMode) {
        guard mode == .existingCheckout || inspection?.isRepository == true else { return }
        let currentBranch = inspection?.branch
        switch mode {
        case .existingCheckout:
            selection = .existing
        case .newBranchWorktree:
            selection = SessionSourceControlSelection(
                mode: mode,
                branch: selection.branch,
                base: selection.base
            )
        case .existingBranchWorktree:
            selection = SessionSourceControlSelection(
                mode: mode,
                branch: selection.branch ?? currentBranch,
                base: nil
            )
        }
    }
}
