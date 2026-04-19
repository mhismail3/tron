import SwiftUI

// MARK: - Branch Picker Field

/// Source of branch names for the picker. `.local` lists every branch in
/// the session's repo (session/* branches last); `.remote` lists only
/// branches published on `origin` — used by Merge Changes so unpublished
/// local branches never appear as valid merge targets.
enum BranchPickerSource {
    case local
    case remote(remote: String? = nil)
}

/// Tap-to-pick branch field. Replaces freeform text entry in the Pull
/// Remote / Merge Changes sub-sheets. Fetches branches via
/// `git.listLocalBranches` or `git.listRemoteBranches` the first time the
/// field appears, then caches the result at this level so re-opening the
/// sheet is instant — no "Loading branches…" flicker on every tap.
@available(iOS 26.0, *)
struct BranchPickerField: View {
    let rpcClient: RPCClient
    let sessionId: String
    let accent: Color
    let placeholder: String
    @Binding var selection: String
    var source: BranchPickerSource = .local

    @State private var isPresenting = false
    @State private var branches: [String] = []
    @State private var hasLoaded = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Button {
            isPresenting = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                Text(selection.isEmpty ? placeholder : selection)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(selection.isEmpty ? .tronTextMuted : .tronTextPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task { await loadIfNeeded() }
        .onChange(of: isPresenting) { _, nowPresenting in
            if nowPresenting {
                Task { await silentRefresh() }
            }
        }
        .sheet(isPresented: $isPresenting) {
            BranchPickerSheet(
                accent: accent,
                source: source,
                branches: branches,
                isLoading: isLoading && !hasLoaded,
                errorMessage: errorMessage,
                selection: $selection,
                isPresenting: $isPresenting
            )
        }
    }

    // Loads once when the field first appears. Subsequent presentations
    // reuse the cached branch list.
    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        isLoading = true
        await fetch()
        isLoading = false
        hasLoaded = true
    }

    // Silent refresh on re-open: updates the list in-place without flashing
    // the loading spinner, so the sheet never glitches.
    private func silentRefresh() async {
        guard hasLoaded else { return }
        await fetch()
    }

    private func fetch() async {
        do {
            switch source {
            case .local:
                let result = try await rpcClient.git.listLocalBranches(sessionId: sessionId)
                branches = result.branches
                errorMessage = nil
            case .remote(let remote):
                let result = try await rpcClient.git.listRemoteBranches(
                    sessionId: sessionId,
                    remote: remote
                )
                branches = result.branches
                errorMessage = nil
            }
        } catch {
            errorMessage = friendlyGitError(error, action: .load)
        }
    }
}

// MARK: - Branch Picker Sheet

/// Branch picker uses a draft-and-confirm pattern: tapping a row stages the
/// selection (row shows a checkmark) but keeps the sheet open; the trailing
/// toolbar checkmark commits the draft back to the binding and dismisses,
/// and the leading xmark dismisses without applying. This matches the way
/// iOS system pickers (Mail signature, Settings selects) behave so a stray
/// tap doesn't immediately commit.
@available(iOS 26.0, *)
struct BranchPickerSheet: View {
    let accent: Color
    let source: BranchPickerSource
    let branches: [String]
    let isLoading: Bool
    let errorMessage: String?
    @Binding var selection: String
    @Binding var isPresenting: Bool

    @State private var draft: String = ""

    private var emptyStateText: String {
        switch source {
        case .local: "No local branches found."
        case .remote: "No remote branches found. Check that origin is configured and `git fetch` has been run."
        }
    }

    private var navTitle: String {
        switch source {
        case .local: "Select Branch"
        case .remote: "Select Remote Branch"
        }
    }

    var body: some View {
        GitSubSheetContainer(
            title: navTitle,
            accent: accent,
            trailing: {
                SheetPrimaryActionButton(
                    icon: "checkmark",
                    accent: accent,
                    isEnabled: !draft.isEmpty,
                    accessibilityLabel: "Confirm Selection"
                ) {
                    selection = draft
                    isPresenting = false
                }
            },
            content: {
                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().tint(accent)
                        Text("Loading branches…")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronTextMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronRose)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else if branches.isEmpty {
                    Text(emptyStateText)
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronTextMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 32)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(branches, id: \.self) { branch in
                            branchRow(branch)
                        }
                    }
                }
            }
        )
        .onAppear { draft = selection }
    }

    private func branchRow(_ branch: String) -> some View {
        Button {
            draft = branch
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                Text(branch)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if draft == branch {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionFill(accent, subtle: true)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
