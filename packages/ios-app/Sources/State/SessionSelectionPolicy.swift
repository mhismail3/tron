import Foundation

/// Reconciles the explicitly mounted session with canonical discovery.
/// A newly created empty session is projected while its Gateway runtime slot
/// remains live. Local admission still bridges the bounded interval before a
/// list traversal publishes that canonical runtime-owned row. Dashboard
/// discovery must never select a transcript implicitly.
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
