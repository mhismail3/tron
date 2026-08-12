import Foundation

/// Reconciles canonical session discovery with a newly created empty session.
/// Pi does not include an empty session in `session.list` until its first user
/// message, so absence from discovery alone cannot immediately clear selection.
enum SessionSelectionPolicy {
    static func reconcile(
        selected: String?,
        visibleIDs: Set<String>,
        locallyCreatedUnindexedIDs: Set<String>,
        firstVisibleID: String?
    ) -> String? {
        guard let selected else { return firstVisibleID }
        if visibleIDs.contains(selected) || locallyCreatedUnindexedIDs.contains(selected) {
            return selected
        }
        return firstVisibleID
    }
}
