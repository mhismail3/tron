import SwiftUI

struct WorkspaceShortcut: Identifiable, Hashable, Sendable {
    let path: String
    let title: String
    let icon: String
    var id: String { path }
}

/// Gateway-backed port of Tron's historical workspace selector. The Mac
/// filesystem remains authoritative; this view only owns navigation state.
struct WorkspaceBrowser: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let shortcuts: [WorkspaceShortcut]
    let initialPath: String?
    let onSelect: (String) -> Void

    @State private var includeHidden = false
    @State private var loadOwner = WorkspaceBrowserOwner()
    @State private var creatingFolder = false
    @State private var newFolderName = ""
    @FocusState private var folderFieldFocused: Bool

    init(
        shortcuts: [WorkspaceShortcut] = [],
        initialPath: String? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.shortcuts = shortcuts
        self.initialPath = initialPath
        self.onSelect = onSelect
    }

    private var listing: WorkspaceListing? { model.workspace }
    private var currentPath: String { listing?.path ?? "" }
    private var loading: Bool { loadOwner.loading }
    private var navigating: Bool { loadOwner.navigating }
    private var errorMessage: String? { loadOwner.errorMessage }
    private var submittingFolder: Bool { loadOwner.submittingFolder }
    private var directories: [WorkspaceEntry] {
        (listing?.entries ?? []).filter {
            $0.kind == .directory && (includeHidden || !$0.hidden)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && listing == nil {
                    TronLoadingState(label: "Loading folders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    browser
                        .opacity(navigating ? 0.62 : 1)
                        .animation(.easeInOut(duration: 0.16), value: navigating)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: currentPath.isEmpty ? "Select Workspace" : abbreviated(currentPath))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { selectCurrentPath() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(currentPath.isEmpty ? Color.tronTextDisabled : Color.tronEmerald)
                    }
                    .disabled(currentPath.isEmpty)
                    .accessibilityLabel("Use current folder")
                }
            }
            .task { await load(path: initialPath) }
            .onChange(of: includeHidden) { _, _ in
                guard !currentPath.isEmpty else { return }
                Task { await load(path: currentPath, navigation: true) }
            }
            .onDisappear { loadOwner.cancel() }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tint(Color.tronEmerald)
    }

    private var browser: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                if let errorMessage, !isTransientConnectionError(errorMessage) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronError)
                        .padding(TronSpacing.xl)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: .tronError, tintOpacity: 0.12)
                }

                if !shortcutRows.isEmpty {
                    browserGroup("Shortcuts") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TronSpacing.md) {
                                ForEach(shortcutRows) { shortcut in
                                    Button { Task { await load(path: shortcut.path, navigation: true) } } label: {
                                        HStack(spacing: 7) {
                                            Image(systemName: shortcut.icon)
                                            Text(shortcut.title).lineLimit(1)
                                            if shortcut.path == currentPath {
                                                Image(systemName: "checkmark.circle.fill")
                                            }
                                        }
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                        .foregroundStyle(Color.tronAccentText)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                        .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(
                                        .regular.tint(Color.tronEmerald.opacity(shortcut.path == currentPath ? 0.20 : 0.08)).interactive(),
                                        in: Capsule()
                                    )
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .scrollClipDisabled()
                    }
                }

                browserGroup("Actions") {
                    if creatingFolder {
                        newFolderRow
                    } else {
                        HStack(spacing: TronSpacing.md) {
                            if let parent = listing?.parent {
                                actionPill(icon: "arrow.up.circle", title: "Go Up") {
                                    Task { await load(path: parent, navigation: true) }
                                }
                            }
                            actionPill(icon: "folder.badge.plus", title: "New Folder") {
                                withAnimation(.easeInOut(duration: 0.16)) { creatingFolder = true }
                                folderFieldFocused = true
                            }
                            actionPill(icon: includeHidden ? "eye" : "eye.slash", title: "Hidden") {
                                includeHidden.toggle()
                            }
                        }
                    }
                }

                browserGroup("Folders") {
                    if directories.isEmpty && !loading {
                        VStack(spacing: TronSpacing.md) {
                            Image(systemName: "folder")
                                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .medium))
                                .foregroundStyle(Color.tronTextMuted)
                            Text(includeHidden ? "No folders here" : "No visible folders here")
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.06)
                    } else {
                        ForEach(directories) { entry in
                            Button { Task { await load(path: entry.path, navigation: true) } } label: {
                                HStack(spacing: TronSpacing.xl) {
                                    Image(systemName: "folder.fill")
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                        .foregroundStyle(Color.tronEmerald)
                                        .frame(width: 18)
                                    Text(entry.name)
                                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                        .foregroundStyle(Color.tronTextPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: TronSpacing.md)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tronGlassSurface(accent: .tronSlate, cornerRadius: 14, tintOpacity: 0.07, interactive: true)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .scrollClipDisabled()
        .tronScrollEdgeChrome()
    }

    @ViewBuilder
    private func browserGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            Text(title.uppercased())
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextMuted)
            content()
        }
    }

    private func actionPill(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).lineLimit(1)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(Color.tronAccentText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.09)).interactive(), in: Capsule())
    }

    private var newFolderRow: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            HStack(spacing: TronSpacing.xl) {
                Image(systemName: "folder.badge.plus")
                    .foregroundStyle(Color.tronEmerald)
                TextField("Folder name", text: $newFolderName)
                    .tronInlineField()
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($folderFieldFocused)
                    .onSubmit { createFolder() }
                if submittingFolder {
                    ProgressView().controlSize(.mini).tint(.tronEmerald)
                } else {
                    Button { cancelFolder() } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Cancel new folder")
                    Button { createFolder() } label: { Image(systemName: "checkmark.circle.fill") }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Create folder")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: 14, tintOpacity: 0.15, interactive: true)
    }

    private var shortcutRows: [WorkspaceShortcut] {
        var seen = Set<String>()
        return ([model.defaultWorkspace].compactMap { $0 }.map {
            WorkspaceShortcut(path: $0, title: "Default", icon: "house.fill")
        } + shortcuts).filter { seen.insert($0.path).inserted }
    }

    private func load(path: String?, navigation: Bool = false) async {
        await loadOwner.load(
            navigation: navigation,
            operation: { try await model.loadWorkspace(path: path) },
            onTransientError: { model.becameActive() }
        )
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !currentPath.isEmpty, !submittingFolder else { return }
        let parent = currentPath
        Task {
            await loadOwner.createFolder(
                operation: { try await model.createFolder(parent: parent, name: name) },
                onSuccess: { cancelFolder() },
                onTransientError: { model.becameActive() }
            )
        }
    }

    private func cancelFolder() {
        creatingFolder = false
        newFolderName = ""
        folderFieldFocused = false
    }

    private func selectCurrentPath() {
        guard !currentPath.isEmpty else { return }
        onSelect(currentPath)
        dismiss()
    }

    private func isTransientConnectionError(_ value: String) -> Bool {
        WorkspaceBrowserOwner.isTransientConnectionError(value)
    }

    private func abbreviated(_ path: String) -> String {
        let home = "/Users/" + NSUserName()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
