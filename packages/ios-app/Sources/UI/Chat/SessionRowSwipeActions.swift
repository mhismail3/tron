import SwiftUI

extension View {
    /// The dashboard session row's trailing swipe. Archive is the full-swipe
    /// action and is offered only where the owning Gateway advertises
    /// `session-archive.v1`; Delete keeps its confirmation and Rename is
    /// unchanged. One implementation so the live dashboard and the hosted
    /// journey cannot drift.
    func sessionRowTrailingSwipe(
        session: SessionSummary,
        archiveIsAvailable: Bool,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: archiveIsAvailable) {
            if archiveIsAvailable {
                Button("Archive", systemImage: "archivebox") { onArchive() }
                    .tint(Color.gray)
                    .accessibilityIdentifier("session-archive-action-\(session.dashboardID)")
            }
            Button("Delete", systemImage: "trash") { onDelete() }
                .tint(Color.tronError)
                .accessibilityIdentifier("session-delete-action-\(session.dashboardID)")
            Button("Rename", systemImage: "pencil") { onRename() }
                .tint(Color.tronEmerald)
        }
    }
}
