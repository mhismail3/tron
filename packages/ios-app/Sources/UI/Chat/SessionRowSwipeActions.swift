import SwiftUI
import TronMobileCore

struct SessionArchiveConfirmation: Identifiable {
    let session: CatalogSession
    let archived: Bool
    var id: String { "\(archived ? "archive" : "unarchive").\(session.dashboardID)" }
}

extension View {
    func sessionRowTrailingSwipe(
        session: CatalogSession,
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
                .tint(Color.tronPrimary)
        }
    }

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
