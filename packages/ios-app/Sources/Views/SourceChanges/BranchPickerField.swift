import SwiftUI

// MARK: - Branch Picker Field

/// Tap-to-pick local branch field. Replaces freeform text entry in the
/// Pull Remote / Finalize sub-sheets. Fetches branches via
/// `git.listLocalBranches` the first time it's opened.
@available(iOS 26.0, *)
struct BranchPickerField: View {
    let rpcClient: RPCClient
    let sessionId: String
    let accent: Color
    let placeholder: String
    @Binding var selection: String

    @State private var isPresenting = false

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
        .sheet(isPresented: $isPresenting) {
            BranchPickerSheet(
                rpcClient: rpcClient,
                sessionId: sessionId,
                accent: accent,
                selection: $selection,
                isPresenting: $isPresenting
            )
        }
    }
}

// MARK: - Branch Picker Sheet

@available(iOS 26.0, *)
struct BranchPickerSheet: View {
    let rpcClient: RPCClient
    let sessionId: String
    let accent: Color
    @Binding var selection: String
    @Binding var isPresenting: Bool

    @State private var branches: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
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
                        Text("No local branches found.")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronTextMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        ForEach(branches, id: \.self) { branch in
                            branchRow(branch)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .navigationTitle("Select Branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresenting = false }
                        .foregroundStyle(accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func branchRow(_ branch: String) -> some View {
        Button {
            selection = branch
            isPresenting = false
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
                if selection == branch {
                    Image(systemName: "checkmark")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.tronBackground.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await rpcClient.git.listLocalBranches(sessionId: sessionId)
            branches = result.branches
        } catch {
            errorMessage = "Couldn't load branches: \(error.localizedDescription)"
        }
    }
}
