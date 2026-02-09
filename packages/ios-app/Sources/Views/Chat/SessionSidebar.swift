import SwiftUI

// MARK: - Session Sidebar

/// Navigation mode for the main view
enum NavigationMode: String, CaseIterable {
    case agents = "Agents"
    case voiceNotes = "Voice Notes"
    case memory = "Memory"
    case sandboxes = "Sandboxes"

    var icon: String {
        switch self {
        case .agents: "cpu"
        case .voiceNotes: "waveform"
        case .memory: "brain.fill"
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
    private var eventStoreManager: EventStoreManager { dependencies!.eventStoreManager }
    let onNewSession: () -> Void
    var onNewSessionLongPress: (() -> Void)? = nil
    let onDeleteSession: (String) -> Void
    let onSettings: () -> Void
    let onVoiceNote: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if eventStoreManager.sortedSessions.isEmpty {
                    // Empty state placeholder
                    VStack(spacing: 8) {
                        Text("No active sessions")
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedSessionId) {
                        ForEach(eventStoreManager.sortedSessions) { session in
                            CachedSessionSidebarRow(
                                session: session,
                                isSelected: session.id == selectedSessionId
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
                    .tint(.clear) // Hide iPadOS native selection border
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.top, 8)
                }
            }

            // Floating buttons - mic (smaller) and plus
            HStack(spacing: 12) {
                FloatingVoiceNotesButton(action: onVoiceNote)
                FloatingNewSessionButton(action: onNewSession, onLongPress: onNewSessionLongPress)
            }
            .padding(.trailing, 20)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(NavigationMode.allCases, id: \.self) { mode in
                        Button {
                            onNavigationModeChange?(mode)
                        } label: {
                            Label(mode.rawValue, systemImage: mode.icon)
                        }
                    }
                } label: {
                    Image("TronLogoVector")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                        .foregroundStyle(.tronEmerald)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("SESSIONS")
                    .font(TronTypography.mono(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.tronEmerald)
                    .tracking(2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .medium))
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }
}

// MARK: - Floating New Session Button (iOS 26 Liquid Glass)

@available(iOS 26.0, *)
struct FloatingNewSessionButton: View {
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil

    var body: some View {
        Image(systemName: "plus")
            .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
            .foregroundStyle(.tronEmerald)
            .frame(width: 56, height: 56)
            .contentShape(Circle())
            .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.8)).interactive(), in: .circle)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row with message count
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)

                // Forked badge
                if session.isFork == true {
                    Text("forked")
                        .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                        .foregroundStyle(.tronEmerald.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronEmerald.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                // Message count (moved to right of title)
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                        .font(TronTypography.sans(size: TronTypography.sizeSM))
                    Text("\(session.messageCount)")
                        .font(TronTypography.codeSM)
                }
                .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Text(session.formattedDate)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Recent prompt (user's last message, right-aligned)
            if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                HStack {
                    Spacer(minLength: 0)

                    HStack(alignment: .top, spacing: 6) {
                        Text(prompt)
                            .font(TronTypography.codeCaption)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.trailing)

                        Image(systemName: "person.fill")
                            .font(TronTypography.labelSM)
                            .foregroundStyle(.tronEmerald.opacity(0.6))
                            .frame(width: 12)
                            .offset(y: 2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.03))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Latest action/response or processing state
            if session.isProcessing == true {
                // Thinking indicator with pulse animation
                SessionProcessingIndicator()
            } else if let response = session.lastAssistantResponse, !response.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "cpu")
                        .font(TronTypography.labelSM)
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                        .frame(width: 12)
                        .offset(y: 2)

                    Text(response)
                        .font(TronTypography.codeCaption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    // Tool count badge
                    if let toolCount = session.lastToolCount, toolCount > 0 {
                        Text("(\(toolCount) \(toolCount == 1 ? "tool" : "tools"))")
                            .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                            .foregroundStyle(.tronEmerald.opacity(0.7))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // Bottom row: Working directory + tokens/cost
            HStack(spacing: 6) {
                Text(session.displayDirectory)
                    .font(TronTypography.codeSM)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                // Token stats with SF Symbols (matching chat view style)
                sessionTokenStats

                Text(session.formattedCost)
                    .font(TronTypography.mono(size: TronTypography.sizeSM, weight: .medium))
                    .foregroundStyle(.tronEmerald.opacity(0.5))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.tronEmerald.opacity(0.25)).interactive()
                : .regular.tint(Color.tronPhthaloGreen.opacity(0.15)).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape([.interaction, .hoverEffect], RoundedRectangle(cornerRadius: 12, style: .continuous))
        .hoverEffect(.highlight)
    }

    /// Token stats with SF Symbols (matching chat view MessageMetadataBadge style)
    @ViewBuilder
    private var sessionTokenStats: some View {
        HStack(spacing: 4) {
            // Input tokens
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(TronTypography.labelSM)
                Text(session.inputTokens.formattedTokenCount)
            }
            .foregroundStyle(.white.opacity(0.35))

            // Output tokens
            HStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(TronTypography.labelSM)
                Text(session.outputTokens.formattedTokenCount)
            }
            .foregroundStyle(.white.opacity(0.35))

            // Cache read (if non-zero)
            if session.cacheReadTokens > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(TronTypography.labelSM)
                    Text(session.cacheReadTokens.formattedTokenCount)
                }
                .foregroundStyle(.tronCyan)
            }

            // Cache write (if non-zero)
            if session.cacheCreationTokens > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "pencil")
                        .font(TronTypography.labelSM)
                    Text(session.cacheCreationTokens.formattedTokenCount)
                }
                .foregroundStyle(.tronAmber)
            }
        }
        .font(TronTypography.pill)
    }
}

// MARK: - Session Processing Indicator (Pulsing "Thinking...")

@available(iOS 26.0, *)
struct SessionProcessingIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronEmerald)
                .symbolEffect(.pulse, options: .repeating, value: isPulsing)

            Text("Thinking...")
                .font(TronTypography.filePath)
                .foregroundStyle(.tronEmerald.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.tronEmerald.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.tronEmerald.opacity(0.3), lineWidth: 0.5)
        )
        .onAppear {
            isPulsing = true
        }
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
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Sessions")
                    .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Create a new session to start")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
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
    .preferredColorScheme(.dark)
}
*/
