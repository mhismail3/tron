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
        ZStack(alignment: .bottomTrailing) {
            List(selection: $selectedSessionId) {
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

            // Floating circular plus button - iOS 26 liquid glass style
            FloatingNewSessionButton(action: onNewSession)
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
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

// MARK: - Floating New Session Button

struct FloatingNewSessionButton: View {
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Outer glass layer with phthalo green tint
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.tronPhthaloGreen.opacity(0.9),
                                Color.tronPhthaloGreen.opacity(0.7)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)

                // Glass overlay for liquid effect
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.25),
                                Color.white.opacity(0.05),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)

                // Inner highlight ring
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.tronEmerald.opacity(0.6),
                                Color.tronPhthaloGreen.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 56, height: 56)

                // Plus icon
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.tronPhthaloGreen.opacity(0.5), radius: 12, x: 0, y: 6)
            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.tronFast) {
                        isPressed = true
                    }
                }
                .onEnded { _ in
                    withAnimation(.tronFast) {
                        isPressed = false
                    }
                }
        )
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
