import SwiftUI

// MARK: - Session Sidebar

/// Navigation mode for the main view
enum NavigationMode: String, CaseIterable {
    case agents = "Sessions"
    case voiceNotes = "Voice Notes"
    case automations = "Automations"
    case sandboxes = "Sandboxes"

    var icon: String {
        switch self {
        case .agents: "cpu"
        case .voiceNotes: "waveform"
        case .automations: "clock.badge.checkmark"
        case .sandboxes: "shippingbox"
        }
    }
}

@available(iOS 26.0, *)
struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false

    // Convenience accessor
    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    let onNewSession: () -> Void
    var onNewSessionLongPress: (() -> Void)? = nil
    let onDeleteSession: (String) -> Void
    let onVoiceNote: () -> Void
    let actions: DashboardToolbarActions

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Always render List so NavigationSplitView can push on compact
                List(selection: $selectedSessionId) {
                    // Hidden chat anchor — enables programmatic navigation to chat on compact
                    if let chat = eventStoreManager.chatSession, eventStoreManager.sortedSessions.isEmpty {
                        Color.clear
                            .frame(height: 0)
                            .tag(chat.id)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    Section {
                        ForEach(eventStoreManager.sortedSessions) { session in
                            CachedSessionSidebarRow(
                                session: session,
                                isSelected: session.id == selectedSessionId,
                                streamManager: eventStoreManager.dashboardStreamManager
                            )
                            .tag(session.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
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
                .tint(.clear)
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.top, 8)
                .overlay {
                    if eventStoreManager.sortedSessions.isEmpty {
                        // Tron placeholder when no non-chat sessions
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
            }

            // Bottom floating bar
            HStack {
                Spacer()
                FloatingVoiceNotesButton(action: onVoiceNote)
                FloatingNewSessionButton(action: onNewSession, onLongPress: onNewSessionLongPress)
                if let chat = eventStoreManager.chatSession {
                    FloatingChatPill(
                        session: chat,
                        isSelected: chat.id == selectedSessionId,
                        streamManager: eventStoreManager.dashboardStreamManager,
                        onTap: { selectedSessionId = chat.id }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
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

// MARK: - Floating Chat Pill

@available(iOS 26.0, *)
struct FloatingChatPill: View {
    let session: CachedSession
    let isSelected: Bool
    let streamManager: DashboardStreamManager
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                .foregroundStyle(.tronMint)

            Text("Chat")
                .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronMint)

            if session.isProcessing == true {
                Image(systemName: "brain")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronMint)
                    .symbolEffect(.pulse, options: .repeating)

                if let lastLine = streamManager.activityLines(for: session.id, persisted: session.lastActivityLines, count: 1).last {
                    Text(lastLine.text)
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronMint.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 120)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.tronMint.opacity(0.25)).interactive()
                : .regular.tint(Color.tronMint.opacity(0.2)).interactive(),
            in: .capsule
        )
        .contentShape([.interaction, .hoverEffect], Capsule())
        .hoverEffect(.highlight)
        .onTapGesture { onTap() }
    }
}

// MARK: - Floating New Session Button (iOS 26 Liquid Glass)

@available(iOS 26.0, *)
struct FloatingNewSessionButton: View {
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Image(systemName: "plus")
            .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
            .foregroundStyle(.tronEmerald)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.25)).interactive(), in: .circle)
            .onTapGesture { action() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: title, stats, path
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if session.isFork == true {
                        Image(systemName: "tuningfork")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 11, height: 11)
                            .foregroundStyle(.tronPurple)
                    }
                    Text(session.displayTitle)
                        .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                        .lineLimit(1)

                    Spacer()

                    HStack(spacing: 4) {
                        Text("↑\(session.totalInputTokens.formattedTokenCount)")
                        Text("↓\(session.outputTokens.formattedTokenCount)")
                        Text(session.formattedCost)
                        Text("·")
                        Text(session.compactDate)
                    }
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .fixedSize()
                }

                Text(session.displayDirectory)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.tronTextMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
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
        }
        .padding(.vertical, 10)
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
        .accessibilityLabel("\(session.displayTitle)\(session.isFork == true ? ", forked" : ""), \(session.messageCount) messages, \(session.formattedDate)")
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

        case .toolStart, .toolEnd:
            MiniToolChip(
                name: line.displayName ?? line.text,
                icon: line.icon ?? "gearshape",
                color: (line.iconColor ?? .tronTextMuted).color,
                summary: line.summary,
                duration: line.duration,
                status: line.status ?? .success
            )

        case .subagentSpawn:
            MiniToolChip(
                name: "Subagent",
                icon: "person.2",
                color: .tronAmber,
                summary: line.text.hasPrefix("Agent: ") ? String(line.text.dropFirst(7)) : line.text,
                status: .running
            )

        case .subagentDone:
            MiniToolChip(
                name: "Subagent",
                icon: "checkmark.circle.fill",
                color: .tronSuccess,
                summary: line.text,
                status: .success
            )

        case .subagentFailed:
            MiniToolChip(
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
            .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .medium))
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
                    .font(TronTypography.mono(size: Self.captionSize, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.55)
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
struct MiniToolChip: View {
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
                .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(statusColor)

            if let summary, !summary.isEmpty {
                Text(summary)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(statusColor.opacity(0.6))
                    .lineLimit(1)
            }

            if let duration {
                Text(duration)
                    .font(TronTypography.mono(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(statusColor.opacity(0.4))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .chipStyle(statusColor, tintOpacity: 0.2, strokeOpacity: 0.25)
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

// MARK: - CachedSession Extension for Display

extension CachedSession {
    var displayDirectory: String {
        let path = workingDirectory

        // Replace /Users/<username>/ with ~/
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if components.count >= 3,
           components[0] == "",
           components[1] == "Users" {
            // Path is /Users/<username>/...
            let afterUser = components.dropFirst(3).joined(separator: "/")
            return afterUser.isEmpty ? "~" : "~/" + afterUser
        }
        return path
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
                .foregroundStyle(.tronTextMuted)

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
