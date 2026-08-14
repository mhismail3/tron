import Foundation

/// Reconciles the explicitly mounted session with canonical discovery.
/// An empty session is absent from `session.list` until its first user message,
/// but dashboard discovery must never select a transcript implicitly.
enum SessionSelectionPolicy {
    static func reconcile(
        selected: String?,
        visibleIDs: Set<String>,
        locallyCreatedUnindexedIDs: Set<String>
    ) -> String? {
        guard let selected else { return nil }
        if visibleIDs.contains(selected) || locallyCreatedUnindexedIDs.contains(selected) {
            return selected
        }
        return nil
    }
}
