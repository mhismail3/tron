import SwiftUI

// MARK: - Workspace Selector

struct WorkspaceSelector: View {
    @Binding var selectedPath: String
    let options: [WorkspaceSelectionOption]
    let connectionRepository: any AppConnectionRepository
    let workspaceBrowserRepository: any WorkspaceBrowserRepository

    @Environment(\.dismiss) private var dismiss
    @State private var currentPath = ""
    @State private var parentPath: String?
    @State private var entries: [WorkspaceDirectoryEntry] = []
    @State private var serverSuggestedPaths: [WorkspaceSuggestedPath] = []
    @State private var isLoading = false
    @State private var isNavigating = false
    @State private var errorMessage: String?
    @State private var showHidden = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isSubmittingFolder = false
    @State private var folderCreationError: String?
    @FocusState private var folderNameFieldFocused: Bool

    init(
        selectedPath: Binding<String>,
        options: [WorkspaceSelectionOption] = [],
        connectionRepository: any AppConnectionRepository,
        workspaceBrowserRepository: any WorkspaceBrowserRepository
    ) {
        self._selectedPath = selectedPath
        self.options = options
        self.connectionRepository = connectionRepository
        self.workspaceBrowserRepository = workspaceBrowserRepository
    }

    private var displayedDirectories: [WorkspaceDirectoryEntry] {
        entries.filter(\.isDirectory)
    }

    private var canSelectCurrentPath: Bool {
        !currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading && currentPath.isEmpty && entries.isEmpty {
                    ProgressView()
                        .tint(.tronEmerald)
                } else if currentPath.isEmpty, let errorMessage {
                    connectionErrorView(errorMessage)
                } else {
                    directoryBrowser
                        .opacity(isNavigating ? 0.62 : 1)
                        .animation(.easeInOut(duration: 0.16), value: isNavigating)
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

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showHidden.toggle()
                    } label: {
                        Image(systemName: showHidden ? "eye" : "eye.slash")
                            .font(TronTypography.buttonSM)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                    .foregroundStyle(.tronEmerald)
                    .disabled(currentPath.isEmpty)
                    .sensoryFeedback(.selection, trigger: showHidden)

                    Button(action: selectCurrentPath) {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                    }
                    .disabled(!canSelectCurrentPath)
                    .foregroundStyle(canSelectCurrentPath ? Color.tronEmerald : Color.tronOverlay(0.3))
                }
            }
            .task {
                await loadHome()
            }
            .onChange(of: showHidden) {
                guard !currentPath.isEmpty else { return }
                Task {
                    do {
                        try await loadDirectory(currentPath)
                    } catch {
                        errorMessage = workspaceBrowserErrorMessage(error)
                    }
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
    }

    private var directoryBrowser: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                if let errorMessage {
                    inlineError(message: errorMessage)
                }

                if !quickPathRows.isEmpty {
                    quickPathSection
                }

                pathHeader
                navigationRows
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollClipDisabled()
    }

    private var quickPathSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("Quick paths")
            VStack(spacing: 8) {
                ForEach(quickPathRows) { row in
                    WorkspaceQuickPathRow(
                        row: row,
                        isSelected: row.path == currentPath,
                        action: { navigateTo(row.path) }
                    )
                }
            }
        }
    }

    private var pathHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .frame(width: 18)

            Text(currentPath.abbreviatingHomeDirectory)
                .font(TronTypography.codeContent)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if isNavigating {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.tronEmerald)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(0.11)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var navigationRows: some View {
        VStack(spacing: 8) {
            if parentPath != nil {
                WorkspaceDirectoryActionRow(
                    icon: "arrow.up.circle",
                    title: "Go Up",
                    subtitle: parentPath?.abbreviatingHomeDirectory,
                    isEmphasized: true,
                    action: navigateUp
                )
            }

            newFolderRow

            if displayedDirectories.isEmpty && !isLoading {
                emptyDirectoryRow
            } else {
                ForEach(displayedDirectories) { entry in
                    WorkspaceDirectoryEntryRow(entry: entry) {
                        navigateTo(entry.path)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var newFolderRow: some View {
        if isCreatingFolder {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .frame(width: 18)

                    TextField("Folder name", text: $newFolderName)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextPrimary)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($folderNameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(submitNewFolder)

                    if isSubmittingFolder {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.tronEmerald)
                    } else {
                        Button(action: cancelFolderCreation) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .foregroundStyle(.tronTextMuted)

                        Button(action: submitNewFolder) {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        .foregroundStyle(canSubmitFolder ? .tronEmerald : .tronTextDisabled)
                        .disabled(!canSubmitFolder)
                    }
                }

                if let folderCreationError {
                    Label(folderCreationError, systemImage: "exclamationmark.triangle.fill")
                        .font(TronTypography.caption)
                        .foregroundStyle(.tronError)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .glassEffect(
                .regular.tint(Color.tronEmerald.opacity(0.15)).interactive(),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .onAppear { folderNameFieldFocused = true }
        } else {
            WorkspaceDirectoryActionRow(
                icon: "folder.badge.plus",
                title: "New Folder",
                subtitle: nil,
                isEmphasized: true,
                action: startFolderCreation
            )
        }
    }

    private var emptyDirectoryRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronTextMuted)
            Text(showHidden ? "No folders here" : "No visible folders here")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            if !showHidden {
                Text("Use the hidden-files toggle to include dot folders.")
                    .font(TronTypography.caption)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .glassEffect(
            .regular.tint(Color.tronOverlay(0.04)),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var quickPathRows: [WorkspaceQuickPath] {
        var seen = Set<String>()
        var rows: [WorkspaceQuickPath] = []
        for option in options {
            guard seen.insert(option.path).inserted else { continue }
            rows.append(WorkspaceQuickPath(
                path: option.path,
                title: option.title,
                subtitle: option.subtitle,
                icon: option.source == .defaultWorkspace ? "house.fill" : "clock.arrow.circlepath"
            ))
        }
        for suggestion in serverSuggestedPaths where suggestion.exists {
            guard seen.insert(suggestion.path).inserted else { continue }
            rows.append(WorkspaceQuickPath(
                path: suggestion.path,
                title: suggestion.name,
                subtitle: suggestion.path.abbreviatingHomeDirectory,
                icon: "folder.fill"
            ))
        }
        return rows
    }

    private var canSubmitFolder: Bool {
        !isSubmittingFolder
            && FolderNameValidator.validationError(for: newFolderName) == nil
            && !currentPath.isEmpty
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(.tronTextMuted)
            .textCase(.uppercase)
    }

    private func inlineError(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(TronTypography.caption)
            .foregroundStyle(.tronError)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                .regular.tint(Color.tronError.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }

    private func connectionErrorView(_ error: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi.exclamationmark")
                .font(TronTypography.sans(size: 42, weight: .semibold))
                .foregroundStyle(.tronError)

            Text("Could not browse workspace")
                .font(TronTypography.headline)
                .foregroundStyle(.tronTextPrimary)

            Text(error)
                .font(TronTypography.subheadline)
                .foregroundStyle(.tronTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)

            Button {
                Task { await loadHome() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.tronEmerald)
        }
        .padding(26)
    }

    private func loadHome() async {
        isLoading = true
        errorMessage = nil
        do {
            await connectionRepository.connect()
            let home = try await workspaceBrowserRepository.getHome()
            serverSuggestedPaths = home.suggestedPaths
            let selected = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = selected.isEmpty ? home.homePath : selected
            do {
                try await loadDirectory(target, setNavigationState: false)
            } catch {
                try await loadDirectory(home.homePath, setNavigationState: false)
                errorMessage = "Could not open \(target.abbreviatingHomeDirectory); showing Home."
            }
        } catch {
            errorMessage = workspaceBrowserErrorMessage(error)
        }
        isLoading = false
    }

    private func loadDirectory(
        _ path: String,
        setNavigationState: Bool = true
    ) async throws {
        if setNavigationState {
            isNavigating = true
        }
        defer {
            if setNavigationState {
                isNavigating = false
            }
        }
        let result = try await workspaceBrowserRepository.listDirectory(
            path: path,
            showHidden: showHidden
        )
        withAnimation(.easeInOut(duration: 0.16)) {
            entries = result.entries
            currentPath = result.path
            parentPath = result.parent
        }
    }

    private func navigateTo(_ path: String) {
        Task {
            do {
                errorMessage = nil
                try await loadDirectory(path)
                cancelFolderCreation()
            } catch {
                errorMessage = workspaceBrowserErrorMessage(error)
            }
        }
    }

    private func navigateUp() {
        guard let parentPath else { return }
        navigateTo(parentPath)
    }

    private func startFolderCreation() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isCreatingFolder = true
            newFolderName = ""
            folderCreationError = nil
        }
    }

    private func cancelFolderCreation() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isCreatingFolder = false
            newFolderName = ""
            folderCreationError = nil
            folderNameFieldFocused = false
        }
    }

    private func submitNewFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = FolderNameValidator.validationError(for: trimmedName) {
            folderCreationError = error
            return
        }

        isSubmittingFolder = true
        folderCreationError = nil
        Task {
            do {
                let newPath = URL(fileURLWithPath: currentPath)
                    .appendingPathComponent(trimmedName)
                    .path
                let result = try await workspaceBrowserRepository.createDirectory(
                    path: newPath,
                    recursive: false,
                    idempotencyKey: .userAction("filesystem.createDir")
                )
                selectedPath = result.path
                isSubmittingFolder = false
                dismiss()
            } catch let error as EngineProtocolError {
                isSubmittingFolder = false
                folderCreationError = workspaceBrowserErrorMessage(error)
            } catch {
                isSubmittingFolder = false
                folderCreationError = workspaceBrowserErrorMessage(error)
            }
        }
    }

    private func selectCurrentPath() {
        guard canSelectCurrentPath else { return }
        selectedPath = currentPath
        dismiss()
    }

    private func workspaceBrowserErrorMessage(_ error: Error) -> String {
        guard let protocolError = error as? EngineProtocolError else {
            return error.localizedDescription
        }
        if protocolError.errorCode == .capabilityNotFound {
            return "Workspace browser is not available on this server. Restart or update Tron, then retry."
        }
        if let suggestion = protocolError.suggestion, !suggestion.isEmpty {
            return "\(protocolError.message) \(suggestion)"
        }
        return protocolError.message
    }
}
