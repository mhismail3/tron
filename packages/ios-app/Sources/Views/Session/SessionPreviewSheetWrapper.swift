import SwiftUI

// MARK: - Session Preview Sheet Wrapper

/// Validates workspace before showing session preview.
/// If workspace is deleted, shows an error state instead of the preview.
@available(iOS 26.0, *)
struct SessionPreviewSheetWrapper: View {
    let session: SessionInfo
    let rpcClient: RPCClient
    let eventStoreManager: EventStoreManager
    let onFork: (String) -> Void
    let onDismiss: () -> Void
    let onWorkspaceDeleted: () -> Void

    @State private var isValidating = true
    @State private var workspaceExists = true

    var body: some View {
        Group {
            if isValidating {
                // Loading state while checking workspace
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.tronEmerald)
                    Text("Checking workspace...")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !workspaceExists {
                // Workspace deleted state
                VStack(spacing: 16) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(TronTypography.sans(size: 48))
                        .foregroundStyle(.tronError)
                    Text("Workspace Deleted")
                        .font(TronTypography.headline)
                        .foregroundStyle(.tronTextPrimary)
                    Text("The workspace folder for this session no longer exists.")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Dismiss") {
                        onWorkspaceDeleted()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.tronEmerald)
                    .padding(.top, 8)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Normal preview
                SessionPreviewSheet(
                    session: session,
                    rpcClient: rpcClient,
                    eventStoreManager: eventStoreManager,
                    onFork: onFork,
                    onDismiss: onDismiss
                )
            }
        }
        .task {
            await validateWorkspace()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private func validateWorkspace() async {
        guard let workDir = session.workingDirectory, !workDir.isEmpty else {
            // No workspace directory - consider it deleted/invalid
            workspaceExists = false
            isValidating = false
            return
        }

        do {
            _ = try await rpcClient.filesystem.listDirectory(path: workDir, showHidden: false)
            workspaceExists = true
        } catch {
            workspaceExists = false
        }
        isValidating = false
    }
}
