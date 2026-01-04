import SwiftUI

// MARK: - Session List View

struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [SessionInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showNewSessionSheet = false
    @State private var newSessionDirectory = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronBackground
                    .ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if sessions.isEmpty {
                    emptyView
                } else {
                    sessionsList
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSessionSheet = true
                    } label: {
                        Image(systemName: TronIcon.newSession.systemName)
                    }
                }
            }
            .sheet(isPresented: $showNewSessionSheet) {
                NewSessionSheet(
                    directory: $newSessionDirectory,
                    onCreate: createNewSession
                )
            }
            .refreshable {
                await loadSessions()
            }
            .task {
                await loadSessions()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.tronEmerald)
            Text("Loading sessions...")
                .font(.subheadline)
                .foregroundStyle(.tronTextSecondary)
        }
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            TronIconView(icon: .session, size: 48, color: .tronTextMuted)

            Text("No Sessions")
                .font(.title3.weight(.medium))
                .foregroundStyle(.tronTextPrimary)

            Text("Create a new session to get started")
                .font(.subheadline)
                .foregroundStyle(.tronTextSecondary)

            Button {
                showNewSessionSheet = true
            } label: {
                Label("New Session", systemImage: TronIcon.newSession.systemName)
                    .font(.headline)
                    .foregroundStyle(.tronBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient.tronEmeraldGradient
                    )
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        List {
            ForEach(sessions) { session in
                SessionRow(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            await viewModel.resumeSession(session)
                        }
                    }
                    .listRowBackground(Color.tronSurface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Actions

    private func loadSessions() async {
        isLoading = true
        errorMessage = nil

        // Note: This would need to be connected to the RPC client
        // For now, simulating with empty array
        do {
            // sessions = try await viewModel.rpcClient.listSessions()
            sessions = []
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func createNewSession() {
        Task {
            let directory = newSessionDirectory.isEmpty
                ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "~"
                : newSessionDirectory
            await viewModel.createNewSession(workingDirectory: directory)
            dismiss()
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(session.isActive ? Color.tronSuccess : Color.tronTextMuted)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.displayName)
                        .font(.headline)
                        .foregroundStyle(.tronTextPrimary)

                    Spacer()

                    Text(session.formattedDate)
                        .font(.caption)
                        .foregroundStyle(.tronTextMuted)
                }

                HStack(spacing: 12) {
                    Label("\(session.messageCount)", systemImage: "bubble.left.and.bubble.right")
                    Text(session.model)
                }
                .font(.caption)
                .foregroundStyle(.tronTextSecondary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - New Session Sheet

struct NewSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var directory: String
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Working Directory", text: $directory)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("Working Directory")
                } footer: {
                    Text("Leave empty to use the app's documents folder.")
                }

                Section {
                    Button {
                        onCreate()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Create Session")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.tronEmerald)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.tronSurface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview {
    SessionListView(
        viewModel: ChatViewModel(
            rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!)
        )
    )
}
