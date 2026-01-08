import SwiftUI

// MARK: - Context Audit View

struct ContextAuditView: View {
    let rpcClient: RPCClient
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var handoffs: [Handoff] = []
    @State private var searchQuery = ""
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.tronBackground.ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .tint(.tronEmerald)
                } else {
                    contentView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Context & Memory")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await loadContext()
            }
        }
        .preferredColorScheme(.dark)
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Tab", selection: $selectedTab) {
                Text("Memory").tag(0)
                Text("Handoffs").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            if selectedTab == 0 {
                memoryView
            } else {
                handoffsView
            }
        }
    }

    // MARK: - Memory View

    private var memoryView: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tronTextSecondary)
                TextField("Search memory...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(.tronTextPrimary)
                    .onSubmit {
                        Task { await searchMemory() }
                    }

                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        Task { await loadContext() }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tronTextMuted)
                    }
                }
            }
            .padding()
            .background(Color.tronSurface)

            if memoryEntries.isEmpty {
                emptyMemoryView
            } else {
                memoryList
            }
        }
    }

    private var emptyMemoryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundStyle(.tronTextMuted)

            Text("No Memory Entries")
                .font(.headline)
                .foregroundStyle(.tronTextSecondary)

            Text("Memory entries will appear here as patterns and decisions are learned.")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var memoryList: some View {
        List {
            ForEach(memoryEntries) { entry in
                MemoryEntryRow(entry: entry)
                    .listRowBackground(Color.tronSurface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Handoffs View

    private var handoffsView: some View {
        Group {
            if handoffs.isEmpty {
                emptyHandoffsView
            } else {
                handoffsList
            }
        }
    }

    private var emptyHandoffsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 48))
                .foregroundStyle(.tronTextMuted)

            Text("No Handoffs")
                .font(.headline)
                .foregroundStyle(.tronTextSecondary)

            Text("Session handoffs will appear here when you save your work context.")
                .font(.caption)
                .foregroundStyle(.tronTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var handoffsList: some View {
        List {
            ForEach(handoffs) { handoff in
                HandoffRow(handoff: handoff)
                    .listRowBackground(Color.tronSurface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Data Loading

    private func loadContext() async {
        isLoading = true

        do {
            async let memoryResult = rpcClient.searchMemory(query: nil, type: nil, limit: 50)
            async let handoffsResult = rpcClient.getHandoffs(workingDirectory: nil, limit: 20)

            let (memory, handoffList) = try await (memoryResult, handoffsResult)
            memoryEntries = memory.entries
            handoffs = handoffList
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func searchMemory() async {
        guard !searchQuery.isEmpty else {
            await loadContext()
            return
        }

        isLoading = true

        do {
            let result = try await rpcClient.searchMemory(
                query: searchQuery,
                type: nil,
                limit: 50
            )
            memoryEntries = result.entries
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Memory Entry Row

struct MemoryEntryRow: View {
    let entry: MemoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Type badge
                Text(entry.type.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(typeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeColor.opacity(0.2))
                    .clipShape(Capsule())

                // Source badge
                Text(entry.source.capitalized)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(Capsule())

                Spacer()

                // Relevance indicator
                if let relevance = entry.relevance, relevance > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                        Text(String(format: "%.0f%%", relevance * 100))
                            .font(.caption2)
                    }
                    .foregroundStyle(.tronTextMuted)
                }
            }

            Text(entry.content)
                .font(.subheadline)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(4)

            if let timestamp = entry.timestamp {
                Text(formatTimestamp(timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding(.vertical, 8)
    }

    private var typeColor: Color {
        switch entry.type {
        case "pattern": return .tronEmerald
        case "decision": return .tronPrimaryVivid
        case "lesson": return .orange
        case "error": return .tronError
        default: return .tronTextSecondary
        }
    }

    private func formatTimestamp(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: timestamp) {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .abbreviated
            return relative.localizedString(for: date, relativeTo: Date())
        }
        return timestamp
    }
}

// MARK: - Handoff Row

struct HandoffRow: View {
    let handoff: Handoff

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.tronEmerald)

                Text("Session Handoff")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                Text(formatDate(handoff.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
            }

            Text(handoff.summary)
                .font(.subheadline)
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(6)

            Text("Session: \(String(handoff.sessionId.prefix(8)))...")
                .font(.caption2)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.vertical, 8)
    }

    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .abbreviated
            return relative.localizedString(for: date, relativeTo: Date())
        }
        return dateString
    }
}

// MARK: - Preview

#Preview {
    ContextAuditView(
        rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
        sessionId: "test"
    )
}
