import SwiftUI

// MARK: - Workspace Selector

struct WorkspaceSelector: View {
    let rpcClient: RPCClient
    @Binding var selectedPath: String

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var entries: [DirectoryEntry] = []
    @State private var isLoading = false
    @State private var isNavigating = false
    @State private var errorMessage: String?
    @State private var showHidden = false

    // Folder creation state
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isSubmittingFolder = false
    @State private var folderCreationError: String?
    @FocusState private var folderNameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading && entries.isEmpty {
                    // Only show full loading on initial load
                    ProgressView()
                        .tint(.tronEmerald)
                } else if let error = errorMessage {
                    // Show connection error
                    connectionErrorView(error)
                } else {
                    directoryList
                        .opacity(isNavigating ? 0.6 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: isNavigating)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Select Workspace")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedPath = currentPath
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                    }
                    .disabled(currentPath.isEmpty)
                    .foregroundStyle(currentPath.isEmpty ? .white.opacity(0.3) : .tronEmerald)
                }
            }
            .task {
                await loadHome()
            }
            .onReceive(rpcClient.$connectionState.receive(on: DispatchQueue.main)) { state in
                // React when connection transitions to connected
                if state.isConnected && errorMessage != nil {
                    // Connection established and we had an error - retry
                    errorMessage = nil
                    Task {
                        await loadHome()
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
    }

    private func connectionErrorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(TronTypography.sans(size: 48))
                .foregroundStyle(.tronError)

            Text("Connection Failed")
                .font(TronTypography.headline)
                .foregroundStyle(.tronTextPrimary)

            Text(error)
                .font(TronTypography.subheadline)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                errorMessage = nil
                Task {
                    await loadHome()
                }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(TronTypography.headline)
                    .foregroundStyle(.tronBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.tronEmerald)
                    .clipShape(Capsule())
            }

            Text("Check that the Tron server is running\nand the host/port in Settings is correct.")
                .font(TronTypography.caption)
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var directoryList: some View {
        VStack(spacing: 0) {
            // Current path header - same dark background as list
            HStack(spacing: 16) {
                Image(systemName: "folder.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(.tronEmerald)
                    .frame(width: 16)
                Text(currentPath)
                    .font(TronTypography.mono(size: TronTypography.sizeBody2))
                    .foregroundStyle(.tronEmerald.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Directory entries
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Go up
                    if !currentPath.isEmpty {
                        Button {
                            navigateUp()
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "arrow.up.circle")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                                    .frame(width: 16)
                                Text("Go Up")
                                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        Divider()
                            .background(Color.tronBorder.opacity(0.5))
                            .padding(.leading, 48)
                    }

                    // New folder row
                    newFolderRow

                    // Directories
                    ForEach(entries.filter { $0.isDirectory }) { entry in
                        Button {
                            navigateTo(entry.path)
                        } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "folder.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                                    .foregroundStyle(.tronEmerald)
                                    .frame(width: 16)
                                Text(entry.name)
                                    .font(TronTypography.mono(size: TronTypography.sizeBody3))
                                    .foregroundStyle(.tronEmerald)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                    .foregroundStyle(.tronEmerald.opacity(0.4))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        if entry.id != entries.filter({ $0.isDirectory }).last?.id {
                            Divider()
                                .background(Color.tronBorder.opacity(0.5))
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }

    private func loadHome() async {
        isLoading = true
        do {
            // Ensure connection is established first
            await rpcClient.connect()

            // Only wait briefly if not already connected
            if !rpcClient.isConnected {
                try? await Task.sleep(for: .milliseconds(100))
            }

            let home = try await rpcClient.filesystem.getHome()
            currentPath = home.homePath
            await loadDirectory(home.homePath)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadDirectory(_ path: String) async {
        do {
            let result = try await rpcClient.filesystem.listDirectory(path: path, showHidden: showHidden)
            await MainActor.run {
                withAnimation(.tronFast) {
                    entries = result.entries
                    currentPath = result.path
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func navigateTo(_ path: String) {
        Task {
            isNavigating = true
            await loadDirectory(path)
            isNavigating = false
        }
    }

    private func navigateUp() {
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        navigateTo(parent)
    }

    // MARK: - Folder Creation

    @ViewBuilder
    private var newFolderRow: some View {
        if isCreatingFolder {
            // Inline text field for folder name
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 16)

                    TextField("Folder name", text: $newFolderName)
                        .font(TronTypography.mono(size: TronTypography.sizeBody3))
                        .foregroundStyle(.tronEmerald)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($folderNameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            submitNewFolder()
                        }

                    if isSubmittingFolder {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.tronEmerald)
                    } else {
                        HStack(spacing: 8) {
                            Button {
                                cancelFolderCreation()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                                    .foregroundStyle(.white.opacity(0.4))
                            }

                            Button {
                                submitNewFolder()
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(TronTypography.sans(size: TronTypography.sizeLargeTitle))
                                    .foregroundStyle(canSubmitFolder ? .tronEmerald : .white.opacity(0.2))
                            }
                            .disabled(!canSubmitFolder)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Error message
                if let error = folderCreationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronError)
                        Text(error)
                            .font(TronTypography.mono(size: TronTypography.sizeBody2))
                            .foregroundStyle(.tronError)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.tronPhthaloGreen.opacity(0.1))
            .onAppear {
                folderNameFieldFocused = true
            }
        } else {
            // "+ New Folder" button
            Button {
                startFolderCreation()
            } label: {
                HStack(spacing: 16) {
                    Image(systemName: "folder.badge.plus")
                        .font(TronTypography.sans(size: TronTypography.sizeBody))
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                        .frame(width: 16)
                    Text("New Folder")
                        .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }

        Divider()
            .background(Color.tronBorder.opacity(0.5))
            .padding(.leading, 48)
    }

    private var canSubmitFolder: Bool {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isSubmittingFolder
    }

    private func startFolderCreation() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingFolder = true
            newFolderName = ""
            folderCreationError = nil
        }
    }

    private func cancelFolderCreation() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isCreatingFolder = false
            newFolderName = ""
            folderCreationError = nil
            folderNameFieldFocused = false
        }
    }

    private func submitNewFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Client-side validation using FolderNameValidator
        if let error = FolderNameValidator.validationError(for: trimmedName) {
            folderCreationError = error
            return
        }

        isSubmittingFolder = true
        folderCreationError = nil

        Task {
            do {
                let newPath = (currentPath as NSString).appendingPathComponent(trimmedName)
                let result = try await rpcClient.filesystem.createDirectory(path: newPath)

                await MainActor.run {
                    isSubmittingFolder = false
                    isCreatingFolder = false
                    newFolderName = ""

                    // Auto-select the new folder and dismiss
                    selectedPath = result.path
                    dismiss()
                }
            } catch let error as RPCError {
                await MainActor.run {
                    isSubmittingFolder = false
                    folderCreationError = error.message
                }
            } catch {
                await MainActor.run {
                    isSubmittingFolder = false
                    folderCreationError = error.localizedDescription
                }
            }
        }
    }
}
