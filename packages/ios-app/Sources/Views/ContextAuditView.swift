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
    @State private var contextSnapshot: ContextSnapshotResult?
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
                Text("Context").tag(0)
                Text("Memory").tag(1)
                Text("Handoffs").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedTab {
            case 0:
                contextView
            case 1:
                memoryView
            case 2:
                handoffsView
            default:
                memoryView
            }
        }
    }

    // MARK: - Context View

    private var contextView: some View {
        Group {
            if let snapshot = contextSnapshot {
                ScrollView {
                    VStack(spacing: 16) {
                        // Usage gauge
                        ContextUsageGaugeView(snapshot: snapshot)
                            .padding(.horizontal)

                        // Info about context vs session tokens
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tronTextMuted)
                            Text("Context % shows current memory usage. Total tokens in the chat pill show cumulative API usage and don't decrease after compaction.")
                                .font(.caption2)
                                .foregroundStyle(.tronTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal)

                        // Breakdown section
                        ContextBreakdownView(breakdown: snapshot.breakdown)
                            .padding(.horizontal)

                        // Threshold info
                        ContextThresholdView(level: snapshot.thresholdLevel, usagePercent: snapshot.usagePercent)
                            .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.cyan)

                    Text("Loading context...")
                        .font(.caption)
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            async let snapshotResult = rpcClient.getContextSnapshot(sessionId: sessionId)

            let (memory, handoffList, snapshot) = try await (memoryResult, handoffsResult, snapshotResult)
            memoryEntries = memory.entries
            handoffs = handoffList
            contextSnapshot = snapshot
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

// MARK: - Context Usage Gauge View

struct ContextUsageGaugeView: View {
    let snapshot: ContextSnapshotResult

    private var usageColor: Color {
        switch snapshot.thresholdLevel {
        case "critical":
            return .red
        case "high":
            return .orange
        case "moderate":
            return .yellow
        default:
            return .cyan
        }
    }

    private var formattedTokens: String {
        formatTokenCount(snapshot.currentTokens)
    }

    private var formattedLimit: String {
        formatTokenCount(snapshot.contextLimit)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14))
                    .foregroundStyle(usageColor)

                Text("Context Usage")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                Text("\(Int(snapshot.usagePercent * 100))%")
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(usageColor)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.tronSurface)

                    // Fill
                    RoundedRectangle(cornerRadius: 6)
                        .fill(usageColor.opacity(0.8))
                        .frame(width: geometry.size.width * min(snapshot.usagePercent, 1.0))
                }
            }
            .frame(height: 12)

            // Token counts
            HStack {
                Text("\(formattedTokens) / \(formattedLimit) tokens")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.tronTextSecondary)

                Spacer()

                Text("\(formatTokenCount(snapshot.contextLimit - snapshot.currentTokens)) remaining")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .padding()
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Context Breakdown View

struct ContextBreakdownView: View {
    let breakdown: ContextSnapshotResult.ContextBreakdown

    private func formatTokens(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "chart.pie")
                    .font(.system(size: 14))
                    .foregroundStyle(.cyan)

                Text("Token Breakdown")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()
            }

            VStack(spacing: 8) {
                BreakdownRow(
                    icon: "gearshape.fill",
                    label: "System Prompt",
                    tokens: breakdown.systemPrompt,
                    color: .purple
                )

                BreakdownRow(
                    icon: "hammer.fill",
                    label: "Tools",
                    tokens: breakdown.tools,
                    color: .orange
                )

                BreakdownRow(
                    icon: "bubble.left.and.bubble.right.fill",
                    label: "Messages",
                    tokens: breakdown.messages,
                    color: .cyan
                )
            }
        }
        .padding()
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct BreakdownRow: View {
    let icon: String
    let label: String
    let tokens: Int
    let color: Color

    private var formattedTokens: String {
        if tokens >= 1000 {
            return String(format: "%.1fk", Double(tokens) / 1000)
        }
        return "\(tokens)"
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 24)

            Text(label)
                .font(.caption)
                .foregroundStyle(.tronTextSecondary)

            Spacer()

            Text(formattedTokens)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.tronTextPrimary)

            Text("tokens")
                .font(.caption2)
                .foregroundStyle(.tronTextMuted)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Context Threshold View

struct ContextThresholdView: View {
    let level: String
    let usagePercent: Double

    private var statusInfo: (icon: String, color: Color, message: String) {
        switch level {
        case "critical":
            return ("exclamationmark.triangle.fill", .red, "Context critically full. Compaction required.")
        case "high":
            return ("exclamationmark.circle.fill", .orange, "Context usage high. Consider compacting soon.")
        case "moderate":
            return ("info.circle.fill", .yellow, "Context usage moderate. Compaction available.")
        default:
            return ("checkmark.circle.fill", .green, "Context usage healthy.")
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusInfo.icon)
                .font(.system(size: 18))
                .foregroundStyle(statusInfo.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(level.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusInfo.color)

                Text(statusInfo.message)
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
            }

            Spacer()
        }
        .padding()
        .background(statusInfo.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusInfo.color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    ContextAuditView(
        rpcClient: RPCClient(serverURL: URL(string: "ws://localhost:8080/ws")!),
        sessionId: "test"
    )
}
