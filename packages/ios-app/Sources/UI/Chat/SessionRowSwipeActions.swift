import SwiftUI
import TronMobileCore

/// An archive-state change the user has requested but not yet confirmed.
/// Archive and Unarchive follow Delete's flow: a swipe reveals the action, and
/// tapping it asks for confirmation. No full swipe commits either change.
struct SessionArchiveConfirmation: Identifiable {
    let session: SessionSummary
    let archived: Bool
    var id: String { "\(archived ? "archive" : "unarchive").\(session.dashboardID)" }
}

extension View {
    /// The dashboard session row's trailing swipe. Archive is offered only where
    /// the owning Gateway advertises `session-archive.v1`. Every action needs a
    /// tap: Archive and Delete then confirm, and Rename opens its editor. One
    /// implementation, so the live dashboard and the hosted journey cannot drift.
    func sessionRowTrailingSwipe(
        session: SessionSummary,
        archiveIsAvailable: Bool,
        onArchive: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: false) {
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

    /// Confirmation for a requested archive or unarchive. It uses the same
    /// confirmation sheet as Delete; the change is sent only after the user
    /// confirms.
    func sessionArchiveConfirmation(
        _ request: Binding<SessionArchiveConfirmation?>,
        onConfirm: @escaping (SessionArchiveConfirmation) -> Void
    ) -> some View {
        tronManagedSheet(
            item: request,
            identity: { "dashboard.\($0.id)" }
        ) { request in
            TronConfirmationSheet(
                title: request.archived
                    ? "Archive \(request.session.title)?"
                    : "Unarchive \(request.session.title)?",
                message: request.archived
                    ? "This hides the session from the dashboard. It stays in search and returns when it runs again."
                    : "This returns the session to the dashboard.",
                confirmTitle: request.archived ? "Archive" : "Unarchive",
                icon: request.archived ? "archivebox" : "arrow.uturn.backward",
                onConfirm: { onConfirm(request) }
            )
        }
    }
}
