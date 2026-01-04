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
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("New Session")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(.tronEmerald)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .listRowBackground(Color.tronSurface)
            }

            Section {
                ForEach(sessionStore.sortedSessions) { session in
                    SessionSidebarRow(
                        session: session,
                        isSelected: session.id == selectedSessionId
                    )
                    .tag(session.id)
                    .listRowBackground(
                        session.id == selectedSessionId
                            ? Color.tronSurfaceElevated
                            : Color.tronSurface
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDeleteSession(session.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Sessions")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tronTextMuted)
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.tronBackground)
        .navigationTitle("Tron")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
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
        VStack(alignment: .leading, spacing: 4) {
            // Title row with status dot
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                if session.isActive {
                    Circle()
                        .fill(Color.tronSuccess)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                Text(session.formattedDate)
                    .font(.caption2)
                    .foregroundStyle(.tronTextMuted)
            }

            // Meta row: model badge + message count
            HStack(spacing: 6) {
                // Model badge
                Text(session.shortModel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tronTextSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tronSurfaceElevated)
                    .clipShape(Capsule())

                // Message count
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 9))
                    Text("\(session.messageCount)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tronTextMuted)

                Spacer()
            }

            // Working directory (truncated)
            Text(session.displayDirectory)
                .font(.caption2)
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - StoredSession Extension for Display

extension StoredSession {
    var displayDirectory: String {
        let path = workingDirectory
        // Show just the last two path components
        let components = path.split(separator: "/")
        if components.count >= 2 {
            return "~/" + components.suffix(2).joined(separator: "/")
        }
        return path
    }
}

// MARK: - Empty Sessions View

struct EmptySessionsView: View {
    let onNewSession: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tronTextMuted)

            VStack(spacing: 6) {
                Text("No Sessions")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tronTextPrimary)

                Text("Create a new session to start")
                    .font(.subheadline)
                    .foregroundStyle(.tronTextMuted)
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
                .background(Color.tronEmerald)
                .clipShape(Capsule())
            }
        }
        .padding(32)
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
