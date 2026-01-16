import SwiftUI

// MARK: - Session Sidebar

/// Navigation mode for the main view
enum NavigationMode: String, CaseIterable {
    case agents = "Agents"
    case voiceNotes = "Voice Notes"
}

@available(iOS 26.0, *)
struct SessionSidebar: View {
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @EnvironmentObject var appState: AppState
    @Binding var selectedSessionId: String?
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let onSettings: () -> Void
    let onVoiceNote: () -> Void
    var onNavigationModeChange: ((NavigationMode) -> Void)?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDeleteSession(session.id)
                        } label: {
                            Image(systemName: "archivebox")
                        }
                        .tint(.tronEmerald)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            // Floating buttons - mic (smaller) and plus
            HStack(spacing: 12) {
                FloatingVoiceNotesButton(action: onVoiceNote)
                FloatingNewSessionButton(action: onNewSession)
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(NavigationMode.allCases, id: \.self) { mode in
                        Button {
                            onNavigationModeChange?(mode)
                        } label: {
                            Label(mode.rawValue, systemImage: mode == .agents ? "cpu" : "waveform")
                        }
                    }
                } label: {
                    Image("TronLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 28)
                }
            }
            ToolbarItem(placement: .principal) {
                Text("TRON")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .tracking(2)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .medium))
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

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tronEmerald)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.8)).interactive(), in: .circle)
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
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald)
                    .lineLimit(1)

                // Forked badge
                if session.isFork == true {
                    Text("forked")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronEmerald.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tronEmerald.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                // Message count (moved to right of title)
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 9))
                    Text("\(session.messageCount)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Text(session.formattedDate)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Recent prompt (user's last message, right-aligned)
            if let prompt = session.lastUserPrompt, !prompt.isEmpty {
                HStack {
                    Spacer(minLength: 0)

                    HStack(alignment: .top, spacing: 6) {
                        Text(prompt)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.trailing)

                        Image(systemName: "person.fill")
                            .font(.system(size: 8))
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
                        .font(.system(size: 8))
                        .foregroundStyle(.tronEmerald.opacity(0.8))
                        .frame(width: 12)
                        .offset(y: 2)

                    Text(response)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    // Tool count badge
                    if let toolCount = session.lastToolCount, toolCount > 0 {
                        Text("(\(toolCount) \(toolCount == 1 ? "tool" : "tools"))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer()

                Text(session.formattedTokens)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))

                Text(session.formattedCost)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tronEmerald.opacity(0.5))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.tronEmerald.opacity(0.4)).interactive()
                : .regular.tint(Color.tronPhthaloGreen.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

// MARK: - Session Processing Indicator (Pulsing "Thinking...")

@available(iOS 26.0, *)
struct SessionProcessingIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.system(size: 10))
                .foregroundStyle(.tronEmerald)
                .symbolEffect(.pulse, options: .repeating, value: isPulsing)

            Text("Thinking...")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.4))

            VStack(spacing: 6) {
                Text("No Sessions")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Create a new session to start")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
            }

            Button(action: onNewSession) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                    Text("New Session")
                        .font(.subheadline.weight(.medium))
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

// Note: Preview requires EventStoreManager which needs RPCClient and EventDatabase
// Previews can be enabled by creating mock instances
/*
#Preview {
    NavigationStack {
        SessionSidebar(
            selectedSessionId: .constant(nil),
            onNewSession: {},
            onDeleteSession: { _ in },
            onSettings: {}
        )
        .environmentObject(EventStoreManager(...))
        .environmentObject(AppState())
    }
    .preferredColorScheme(.dark)
}
*/
