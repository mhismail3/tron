import SwiftUI

// MARK: - Session Sidebar

/// Navigation mode for the main view
enum NavigationMode: String, CaseIterable {
    case agents = "Sessions"
    case engine = "Engine"

    var icon: String {
        switch self {
        case .agents: "cpu"
        case .engine: "server.rack"
        }
    }
}

@available(iOS 26.0, *)
struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.interactionPolicy) var interactionPolicy
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false
    @State private var selectedWorkspace: String?
    @State private var appearanceSettings = AppearanceSettings.shared

    // Convenience accessor
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    let onNewSession: () -> Void
    var onNewSessionLongPress: (() -> Void)? = nil
    let onDeleteSession: (String) -> Void
    let onVoiceNote: () -> Void
    let actions: DashboardToolbarActions

    private var recentWorkspaces: [(path: String, name: String)] {
        CachedSession.recentWorkspaces(from: eventStoreManager.sortedSessions)
    }

    private var filteredSessions: [CachedSession] {
        guard let workspace = selectedWorkspace else { return eventStoreManager.sortedSessions }
        return eventStoreManager.sortedSessions.filter { $0.workingDirectory == workspace }
    }

    private var filteredSessionIds: [String] {
        filteredSessions.map(\.id)
    }

    private var worktreePreloadKey: SessionSidebarWorktreePreloadKey {
        SessionSidebarWorktreePreloadKey(
            sessionIds: filteredSessionIds,
            isConnected: eventStoreManager.engineClient.connectionState.isConnected
        )
    }

    private var workspaceFilterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(recentWorkspaces, id: \.path) { workspace in
                    let isSelected = selectedWorkspace == workspace.path
                    Button {
                        withAnimation(.smooth(duration: 0.25)) {
                            selectedWorkspace = isSelected ? nil : workspace.path
                        }
                    } label: {
                        Text(workspace.name)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(isSelected ? .white : .tronEmerald)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .background {
                        Capsule().fill(Color.tronBackground)
                        Capsule().fill(Color.tronEmerald.opacity(isSelected ? 0.6 : 0.25))
                    }
                    .overlay(Capsule().strokeBorder(Color.tronEmerald.opacity(isSelected ? 0.5 : 0.3), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 8)
        }
        .mask(
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 12)
            }
            .padding(.vertical, -50)
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Always render List so NavigationSplitView can push on compact
                List(selection: $selectedSessionId) {
                    Section {
                        ForEach(filteredSessions) { session in
                            CachedSessionSidebarRow(
                                session: session,
                                isSelected: session.id == selectedSessionId,
                                streamManager: eventStoreManager.dashboardStreamManager,
                                worktreeCache: eventStoreManager.worktreeStatusCache
                            )
                            .tag(session.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .opacity(session.isDeleting ? 0.4 : 1.0)
                            .allowsHitTesting(!session.isDeleting)
                            .overlay(alignment: .trailing) {
                                if session.isDeleting {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 16)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if !session.isDeleting && (interactionPolicy?.canMutateSession ?? false) {
                                    Button {
                                        sessionToArchive = session.id
                                        showArchiveConfirmation = true
                                    } label: {
                                        Image(systemName: "archivebox")
                                    }
                                    .tint(.tronEmerald)
                                }
                            }
                        }
                    }
                }
                .tint(.clear)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8)
                .overlay {
                    if eventStoreManager.sortedSessions.isEmpty {
                        VStack(spacing: 16) {
                            Image("TronLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 80)

                            Text("Start talking")
                                .font(TronTypography.messageBody)
                                .foregroundStyle(.tronTextMuted)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .task(id: worktreePreloadKey) {
                    let key = worktreePreloadKey
                    guard key.isConnected else { return }
                    await eventStoreManager.worktreeStatusCache.ensureLoaded(sessionIds: key.sessionIds)
                }
            }

            // Bottom floating bar
            HStack(alignment: .center) {
                FloatingVoiceNotesButton(action: onVoiceNote, size: 56)

                if recentWorkspaces.count > 1 && appearanceSettings.showWorkspacePills {
                    workspaceFilterPills
                } else {
                    Spacer()
                }

                let canCreate = interactionPolicy?.canCreateSession ?? false
                FloatingNewSessionButton(action: onNewSession, onLongPress: onNewSessionLongPress, size: 56)
                    .disabled(!canCreate)
                    .opacity(canCreate ? 1.0 : 0.4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
        }
        .onChange(of: appearanceSettings.showWorkspacePills) { _, showPills in
            if !showPills {
                selectedWorkspace = nil
            }
        }
        .background {
            Color.clear
                .alert("Archive Session", isPresented: $showArchiveConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Archive", role: .destructive) {
                        if let id = sessionToArchive {
                            onDeleteSession(id)
                        }
                    }
                } message: {
                    Text("This will archive the session from your device. Server data will remain.")
                }
                .tint(.gray)
        }
        .tronScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            DashboardToolbarContent(title: eventStoreManager.sortedSessions.isEmpty ? "Tron" : "Sessions", accent: .tronEmerald, actions: actions)
        }
    }

}

private struct SessionSidebarWorktreePreloadKey: Equatable {
    let sessionIds: [String]
    let isConnected: Bool
}

// MARK: - Floating New Session Button (iOS 26 Liquid Glass)

internal enum FloatingNewSessionButtonAccessibility {
    static let label = "New Session"
    static let hint = "Opens the new session sheet"
}

@available(iOS 26.0, *)
struct FloatingNewSessionButton: View {
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil
    var size: CGFloat = 44
    var accent: Color = .tronEmerald

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(accent.opacity(0.25)).interactive(), in: .circle)
        .accessibilityLabel(FloatingNewSessionButtonAccessibility.label)
        .accessibilityHint(FloatingNewSessionButtonAccessibility.hint)
        .onLongPressGesture(minimumDuration: 0.5) {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            onLongPress?() ?? action()
        }
    }
}

// MARK: - Cached Session Sidebar Row (uses CachedSession from EventDatabase)

@available(iOS 26.0, *)
struct CachedSessionSidebarRow: View {
    let session: CachedSession
    let isSelected: Bool
    let streamManager: DashboardStreamManager
    let worktreeCache: WorktreeStatusCache

    private func accessibilityLabel(worktree: WorktreeInfo?) -> String {
        let metadata = SessionTitleIcons.accessibilityDescriptors(
            isFork: session.isFork == true,
            worktree: worktree
        )
        let metadataText = metadata.isEmpty ? "" : ", \(metadata.joined(separator: ", "))"
        return "\(session.displayTitle)\(metadataText), \(session.messageCount) messages, \(session.formattedDate)"
    }

    var body: some View {
        let worktree = worktreeCache.status(for: session.id)?.worktree
        VStack(alignment: .leading, spacing: 4) {
            // Header: title
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    SessionTitleIcons(
                        isFork: session.isFork == true,
                        worktree: worktree
                    )
                    Text(session.displayTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)

                    Spacer()
                }
                .animation(.smooth(duration: 0.25),
                           value: worktree)
            }

            // Mini-chat content — single data source for both live and persisted
            let activityLines = streamManager.activityLines(for: session.id, persisted: session.lastActivityLines)
            if !activityLines.isEmpty {
                MiniChatActivityView(lines: activityLines)
            }

            // Processing bar
            if session.isProcessing == true {
                ProcessingBar()
            }

            HStack {
                Text(session.displayDirectory)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                HStack(spacing: 4) {
                    Text("↑\(session.totalInputTokens.formattedTokenCount)")
                    Text("↓\(session.outputTokens.formattedTokenCount)")
                    Text(session.formattedCost)
                    Text("·")
                    Text(session.shortModel)
                    Text("·")
                    Text(session.compactDate)
                }
                .fixedSize()
            }
            .font(TronTypography.sans(size: TronTypography.sizeXS))
            .foregroundStyle(.tronTextMuted.opacity(0.5))
            .padding(.top, 2)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .padding(.horizontal, 14)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.tronEmerald.opacity(0.25)).interactive()
                : .regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(worktree: worktree))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Mini-Chat Activity View

@available(iOS 26.0, *)
struct MiniChatActivityView: View {
    let lines: [ActivityLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                miniChatLine(line)
            }
        }
    }

    @ViewBuilder
    private func miniChatLine(_ line: ActivityLine) -> some View {
        switch line.kind {
        case .userPrompt:
            MiniMessageRow(text: line.text, isUser: true)

        case .text:
            MiniMessageRow(text: line.text, isUser: false)

        case .capabilityInvocationStarted, .capabilityInvocationCompleted:
            MiniCapabilityChip(
                name: line.displayName ?? line.text,
                icon: line.icon ?? "gearshape",
                color: (line.iconColor ?? .tronTextMuted).color,
                summary: line.summary,
                duration: line.duration,
                status: line.status ?? .success
            )

        case .subagentSpawn:
            MiniCapabilityChip(
                name: "Subagent",
                icon: "person.2",
                color: .tronAmber,
                summary: line.text.hasPrefix("Agent: ") ? String(line.text.dropFirst(7)) : line.text,
                status: .running
            )

        case .subagentDone:
            MiniCapabilityChip(
                name: "Subagent",
                icon: "checkmark.circle.fill",
                color: .tronSuccess,
                summary: line.text,
                status: .success
            )

        case .subagentFailed:
            MiniCapabilityChip(
                name: "Subagent",
                icon: "xmark.circle.fill",
                color: .tronError,
                summary: line.text,
                status: .error
            )

        case .thinking:
            MiniThinkingRow()

        case .error:
            HStack(spacing: 4) {
                Text("⚠").foregroundStyle(.red.opacity(0.8))
                Text(line.text).foregroundStyle(.red.opacity(0.8))
            }
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
            .lineLimit(1).truncationMode(.tail)
        }
    }
}

// MARK: - Mini-Chat Shared Components

@available(iOS 26.0, *)
struct MiniMessageRow: View {
    let text: String
    let isUser: Bool

    private static let captionSize = TronTypography.sizeCaption

    var body: some View {
        if isUser {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(text)
                    .font(TronTypography.sans(size: Self.captionSize, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                accentBar(color: .tronEmerald.opacity(0.3))
                    .padding(.leading, 8)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 0) {
                accentBar(color: .tronEmerald)
                    .padding(.trailing, 8)
                Text(inlineMarkdown(from: text, size: Self.captionSize))
                    .foregroundStyle(.tronEmeraldDark.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accentBar(color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: 2)
    }
}

@available(iOS 26.0, *)
struct MiniThinkingRow: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.tronTextMuted.opacity(0.4))
                .frame(width: 2)
                .padding(.trailing, 8)

            Text("Thinking")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tronTextMuted.opacity(0.5))
                .italic()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

@available(iOS 26.0, *)
struct MiniCapabilityChip: View {
    let name: String
    let icon: String
    let color: Color
    var summary: String?
    var duration: String?
    var status: ActivityLineStatus?

    private var statusColor: Color {
        status == .error ? .tronError : color
    }

    var body: some View {
        HStack(spacing: 4) {
            // Status icon
            if status == .running {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 10, height: 10)
                    .tint(color)
            } else if status == .error {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tronError)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(color)
            }

            Text(name)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(statusColor)

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(statusColor.opacity(0.6))
                    .lineLimit(1)
            }

            if let duration {
                Text(duration)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(statusColor.opacity(0.4))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .chipStyle(statusColor, tintOpacity: 0.2)
        .animation(.smooth(duration: 0.3), value: summary)
        .animation(.smooth(duration: 0.3), value: duration)
        .animation(.smooth(duration: 0.3), value: status)
    }
}

@available(iOS 26.0, *)
struct ProcessingBar: View {
    @State private var isPulsing = false

    var body: some View {
        Rectangle()
            .fill(Color.tronEmerald)
            .frame(height: 2)
            .opacity(isPulsing ? 0.3 : 0.8)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Empty Sessions View

@available(iOS 26.0, *)
struct EmptySessionsView: View {
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(TronTypography.sans(size: 48, weight: .light))
                .foregroundStyle(.tronEmerald)

            VStack(spacing: 6) {
                Text("No Sessions")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("Create a new session to start")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronTextMuted)
            }

            Button(action: onNewSession) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(TronTypography.buttonSM)
                    Text("New Session")
                        .font(TronTypography.subheadline)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .contentShape(Capsule())
            }
            .glassEffect(.regular.tint(Color.tronEmerald).interactive(), in: .capsule)
        }
        .padding(32)
    }
}

// MARK: - Preview

// Note: Preview requires DependencyContainer
// Previews can be enabled by creating mock instances
/*
#Preview {
    NavigationStack {
        SessionSidebar(
            selectedSessionId: .constant(nil),
            onNewSession: {},
            onDeleteSession: { _ in },
            onSettings: {},
            onVoiceNote: {}
        )
        .environment(\.dependencies, DependencyContainer())
    }
}
*/
