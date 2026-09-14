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
                        accent: .tronTeal
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(SessionSourceControlMode.allCases.enumerated()), id: \.element) { index, mode in
                                if index > 0 { TronSettingsDivider() }
                                Button { choose(mode) } label: {
                                    HStack(alignment: .center, spacing: 12) {
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
                            accent: .tronTeal,
                            surfaceStyle: .uncontained
                        ) {
                            VStack(alignment: .leading, spacing: 10) {
                                if selection.mode == .newBranchWorktree {
                                    TextField("feature/my-work", text: branchBinding)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .tronField(
                                            monospaced: true,
                                            compact: true,
                                            surfaceTint: Color.tronTeal.opacity(0.10),
                                            border: Color.tronTeal.opacity(0.30)
                                        )

                                    TronSelectionRow(icon: "arrow.triangle.branch", title: "Start From", value: selection.base ?? "Current commit") {
                                        Button("Current commit") { selection.base = nil }
                                        Section("Local branches") {
                                            ForEach(inspection?.branches ?? []) { branch in
                                                Button(branch.name) { selection.base = "refs/heads/\(branch.name)" }
                                            }
                                        }
                                        Section("Recent commits") {
                                            ForEach(inspection?.commits ?? []) { commit in
                                                Button("\(commit.oid.prefix(8)) · \(commit.subject)") { selection.base = commit.oid }
                                            }
                                        }
                                    }
                                    .tronGlassSurface(accent: .tronTeal)
                                } else {
                                    TronSelectionRow(icon: "arrow.triangle.branch", title: "Branch", value: selection.branch ?? "Choose a branch") {
                                        ForEach(inspection?.branches ?? []) { branch in
                                            Button(branch.checkedOut ? "\(branch.name) · Already checked out" : branch.name) {
                                                selection.branch = branch.name
                                            }
                                            .disabled(branch.checkedOut)
                                        }
                                    }
                                    .disabled(inspection?.branches.contains(where: { !$0.checkedOut }) != true)
                                    .tronGlassSurface(accent: .tronTeal)
                                }
                            }
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
            return "Name the new branch, then choose its starting point. Lists show up to 200 local branches and 100 recent commits. Current commit requires a clean checkout."
        case .existingBranchWorktree:
            return inspection?.branches.contains(where: { !$0.checkedOut }) == true
                ? "Choose a local branch not already checked out by another worktree."
                : "No available local branches in this inspection. Choose New Branch or reload the workspace."
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

    private func choose(_ mode: SessionSourceControlMode) {
        guard mode == .existingCheckout || inspection?.isRepository == true else { return }
        switch mode {
        case .existingCheckout:
            selection = .existing
        case .newBranchWorktree:
            selection = SessionSourceControlSelection(
                mode: mode,
                branch: selection.mode == .newBranchWorktree ? selection.branch : nil,
                base: selection.base
            )
        case .existingBranchWorktree:
            selection = SessionSourceControlSelection(
                mode: mode,
                branch: inspection?.branches.first(where: { !$0.checkedOut && $0.name == selection.branch })?.name
                    ?? inspection?.branches.first(where: { !$0.checkedOut })?.name,
                base: nil
            )
        }
    }
}
