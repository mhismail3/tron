import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var appState: AppState
    @Binding var selectedSessionId: String?
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let onSettings: () -> Void

    var body: some View {
        List(selection: $selectedSessionId) {
            Section {
                Button(action: onNewSession) {
                    Label("New Session", systemImage: TronIcon.newSession.systemName)
                        .font(.headline)
                        .foregroundStyle(.tronEmerald)
                }
                .listRowBackground(Color.tronSurface)
            }

            Section("Sessions") {
                ForEach(sessionStore.sortedSessions) { session in
                    SessionSidebarRow(
                        session: session,
                        isSelected: session.id == selectedSessionId
                    )
                    .tag(session.id)
                    .listRowBackground(
                        session.id == selectedSessionId
                            ? Color.tronEmerald.opacity(0.2)
                            : Color.tronSurface
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDeleteSession(session.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.tronBackground)
        .navigationTitle("Tron")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.tronTextSecondary)
                }
            }
        }
    }
}

// MARK: - Session Sidebar Row

struct SessionSidebarRow: View {
    let session: StoredSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                Spacer()

                if session.isActive {
                    Circle()
                        .fill(Color.tronSuccess)
                        .frame(width: 8, height: 8)
                }
            }

            HStack(spacing: 8) {
                // Model badge
                Text(session.shortModel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tronTextMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronPrimary.opacity(0.5))
                    .clipShape(Capsule())

                // Message count
                Label("\(session.messageCount)", systemImage: "bubble.left")
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)

                Spacer()

                // Relative date
                Text(session.formattedDate)
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
            }

            // Working directory
            Text(session.workingDirectory)
                .font(.caption2)
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Empty Sessions View

struct EmptySessionsView: View {
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 64))
                .foregroundStyle(.tronTextMuted)

            VStack(spacing: 8) {
                Text("No Sessions")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("Create a new session to start chatting with Tron")
                    .font(.subheadline)
                    .foregroundStyle(.tronTextSecondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onNewSession) {
                Label("New Session", systemImage: TronIcon.newSession.systemName)
                    .font(.headline)
                    .foregroundStyle(.tronBackground)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(LinearGradient.tronEmeraldGradient)
                    .clipShape(Capsule())
            }
        }
        .padding(40)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SessionSidebar(
            selectedSessionId: .constant(nil),
            onNewSession: {},
            onDeleteSession: { _ in },
            onSettings: {}
        )
        .environmentObject(SessionStore())
        .environmentObject(AppState())
    }
    .preferredColorScheme(.dark)
}
