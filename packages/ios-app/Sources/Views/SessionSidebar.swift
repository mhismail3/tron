import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @EnvironmentObject var eventStoreManager: EventStoreManager
    @EnvironmentObject var appState: AppState
    @Binding var selectedSessionId: String?
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let onSettings: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(selection: $selectedSessionId) {
                ForEach(eventStoreManager.sortedSessions) { session in
                    CachedSessionSidebarRow(
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
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.tronBackground)

            // Floating circular plus button - iOS 26 liquid glass style
            FloatingNewSessionButton(action: onNewSession)
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Image("TronLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
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
                        .font(.system(size: 16))
                        .foregroundStyle(.tronTextSecondary)
                }
            }
        }
    }
}

// MARK: - Floating New Session Button (Native iOS 26 style)

struct FloatingNewSessionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .tint(Color(hex: "#123524"))
    }
}

// MARK: - Cached Session Sidebar Row (uses CachedSession from EventDatabase)

struct CachedSessionSidebarRow: View {
    let session: CachedSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row with status dot
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(1)

                if session.status == .active {
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

// MARK: - CachedSession Extension for Display

extension CachedSession {
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
