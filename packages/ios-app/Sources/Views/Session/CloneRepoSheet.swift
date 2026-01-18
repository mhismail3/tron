import SwiftUI

/// Sheet for cloning a GitHub repository to a local directory.
/// Validates GitHub URL, allows destination customization, and creates a session
/// in the cloned workspace upon completion.
@available(iOS 26.0, *)
struct CloneRepoSheet: View {
    let rpcClient: RPCClient
    /// Callback when clone completes with the cloned path
    let onCloned: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var repoURL = ""
    @State private var destinationPath = ""
    @State private var homePath = ""
    @State private var isCloning = false
    @State private var cloneError: String?
    @State private var showDestinationPicker = false
    @State private var isLoadingHome = true

    /// Parsed repo info from the URL (nil if invalid)
    private var parsedRepo: GitHubURLParser.ParseResult? {
        GitHubURLParser.parse(repoURL)
    }

    /// Validation error for the URL (nil if valid or empty)
    private var urlValidationError: String? {
        let trimmed = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return GitHubURLParser.validationError(for: trimmed)
    }

    /// Whether the form is valid and ready to clone
    private var canClone: Bool {
        parsedRepo != nil && !destinationPath.isEmpty && !isCloning
    }

    /// Full destination path including repo name
    private var fullDestinationPath: String {
        guard let repo = parsedRepo else { return destinationPath }
        return (destinationPath as NSString).appendingPathComponent(repo.repoName)
    }

    /// Display-friendly destination path (truncates home dir)
    private var displayDestinationPath: String {
        fullDestinationPath.replacingOccurrences(
            of: "^/Users/[^/]+/",
            with: "~/",
            options: .regularExpression
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // GitHub URL input section
                    urlInputSection

                    // Destination section (only show when URL is valid)
                    if parsedRepo != nil {
                        destinationSection
                    }

                    // Clone button
                    cloneButton

                    // Error display
                    if let error = cloneError {
                        errorView(error)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.tronEmerald)
                    }
                    .disabled(isCloning)
                }
                ToolbarItem(placement: .principal) {
                    Text("Clone Repository")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
            }
            .sheet(isPresented: $showDestinationPicker) {
                WorkspaceSelector(
                    rpcClient: rpcClient,
                    selectedPath: $destinationPath
                )
            }
            .task {
                await loadHome()
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isCloning)
    }

    // MARK: - URL Input Section

    private var urlInputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub URL")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 8) {
                TextField("github.com/owner/repo", text: $repoURL)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.clear)
                            .glassEffect(
                                .regular.tint(
                                    urlValidationError != nil
                                        ? Color.tronError.opacity(0.2)
                                        : Color.tronPhthaloGreen.opacity(0.35)
                                ),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                urlValidationError != nil ? Color.tronError.opacity(0.5) : Color.clear,
                                lineWidth: 1
                            )
                    }
                    .onChange(of: repoURL) { _, newValue in
                        // Auto-update destination when URL changes
                        if let repo = GitHubURLParser.parse(newValue), destinationPath.isEmpty || destinationPath == defaultProjectsPath {
                            destinationPath = defaultProjectsPath
                        }
                        // Clear previous error
                        cloneError = nil
                    }

                // Validation feedback
                if let error = urlValidationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronError)
                        Text(error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tronError)
                    }
                } else if let repo = parsedRepo {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tronEmerald)
                        Text(repo.repoName)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }

            Text("Paste a GitHub repository URL")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Destination Section

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Destination")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            Button {
                showDestinationPicker = true
            } label: {
                HStack {
                    Text(displayDestinationPath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("Change")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronEmerald.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.35)).interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(isCloning)

            Text("The repository will be cloned to this folder")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Clone Button

    private var cloneButton: some View {
        Button {
            cloneRepository()
        } label: {
            HStack(spacing: 10) {
                if isCloning {
                    ProgressView()
                        .scaleEffect(0.9)
                        .tint(.tronBackground)
                    Text("Cloning...")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tronBackground)
                } else {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 14))
                    Text("Clone Repository")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(canClone ? Color.tronEmerald : Color.white.opacity(0.1))
            .foregroundStyle(canClone ? .tronBackground : .white.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(!canClone)
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.tronError)
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tronError)

                Button {
                    cloneError = nil
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassEffect(.regular.tint(Color.tronError.opacity(0.3)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Computed Properties

    private var defaultProjectsPath: String {
        (homePath as NSString).appendingPathComponent("Downloads/projects")
    }

    // MARK: - Actions

    private func loadHome() async {
        isLoadingHome = true
        do {
            await rpcClient.connect()
            if !rpcClient.isConnected {
                try? await Task.sleep(for: .milliseconds(100))
            }

            let home = try await rpcClient.getHome()
            await MainActor.run {
                homePath = home.homePath
                // Set default destination to ~/Downloads/projects
                destinationPath = defaultProjectsPath
                isLoadingHome = false
            }
        } catch {
            await MainActor.run {
                // Fallback to a reasonable default
                homePath = "/Users"
                destinationPath = "/Users"
                isLoadingHome = false
            }
        }
    }

    private func cloneRepository() {
        guard let repo = parsedRepo else { return }

        isCloning = true
        cloneError = nil

        Task {
            do {
                let result = try await rpcClient.cloneRepository(
                    url: repo.normalizedURL,
                    targetPath: fullDestinationPath
                )

                await MainActor.run {
                    isCloning = false
                    if result.success {
                        onCloned(result.path)
                        dismiss()
                    } else {
                        cloneError = result.error ?? "Clone failed"
                    }
                }
            } catch let error as RPCError {
                await MainActor.run {
                    isCloning = false
                    cloneError = error.message
                }
            } catch {
                await MainActor.run {
                    isCloning = false
                    cloneError = error.localizedDescription
                }
            }
        }
    }
}
