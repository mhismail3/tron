import SwiftUI

// MARK: - Session Sidebar

@available(iOS 26.0, *)
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            // Floating circular plus button - iOS 26 liquid glass style
            FloatingNewSessionButton(action: onNewSession)
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(Color.tronPhthaloGreen).interactive(), in: .circle)
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
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen).interactive(), in: .circle)
    }
}

// MARK: - Cached Session Sidebar Row (uses CachedSession from EventDatabase)

@available(iOS 26.0, *)
struct CachedSessionSidebarRow: View {
    let session: CachedSession
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row with status dot
            HStack(spacing: 6) {
                Text(session.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)

                if session.status == .active {
                    Circle()
                        .fill(Color.tronSuccess)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                Text(session.formattedDate)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Meta row: model badge + message count
            HStack(spacing: 6) {
                // Model badge with glass effect
                Text(session.shortModel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular.tint(Color.tronPhthaloGreen), in: .capsule)

                // Message count
                HStack(spacing: 2) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 9))
                    Text("\(session.messageCount)")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.5))

                Spacer()
            }

            // Working directory (truncated)
            Text(session.displayDirectory)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .glassEffect(
            isSelected
                ? .regular.tint(Color.tronEmerald.opacity(0.3)).interactive()
                : .regular.tint(Color.tronPhthaloGreen.opacity(0.2)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
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
            }
            .buttonStyle(.plain)
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
