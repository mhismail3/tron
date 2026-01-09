import SwiftUI

// MARK: - Context Audit View

struct ContextAuditView: View {
    let rpcClient: RPCClient
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var contextSnapshot: ContextSnapshotResult?

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
                    Text("Context Manager")
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

    /// Get session token usage from EventStoreManager
    private var sessionTokenUsage: (input: Int, output: Int) {
        guard let session = eventStoreManager.sessions.first(where: { $0.id == sessionId }) else {
            return (0, 0)
        }
        return (session.inputTokens, session.outputTokens)
    }

    private var contentView: some View {
        contextView
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

                        // Accumulated session tokens
                        SessionTokensView(
                            inputTokens: sessionTokenUsage.input,
                            outputTokens: sessionTokenUsage.output
                        )
                        .padding(.horizontal)

                        // Info about context vs session tokens
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tronTextMuted)
                            Text("Context % shows current memory usage and decreases after compaction. Session tokens show cumulative API usage for this session.")
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

    // MARK: - Data Loading

    private func loadContext() async {
        isLoading = true

        do {
            contextSnapshot = try await rpcClient.getContextSnapshot(sessionId: sessionId)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Session Tokens View

struct SessionTokensView: View {
    let inputTokens: Int
    let outputTokens: Int

    private var totalTokens: Int {
        inputTokens + outputTokens
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
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 14))
                    .foregroundStyle(.tronEmerald)

                Text("Session Tokens")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Spacer()

                Text(formatTokenCount(totalTokens))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
            }

            // Token breakdown
            HStack(spacing: 16) {
                // Input tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.cyan)
                        Text("Input")
                            .font(.caption)
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Text(formatTokenCount(inputTokens))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tronTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.cyan.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                // Output tokens
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tronEmerald)
                        Text("Output")
                            .font(.caption)
                            .foregroundStyle(.tronTextSecondary)
                    }
                    Text(formatTokenCount(outputTokens))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.tronTextPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.tronEmerald.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color.tronSurfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
