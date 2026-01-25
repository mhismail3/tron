import Foundation

/// Builds tree visualization from session events.
/// Extracts presentation logic from EventDatabase.
enum EventTreeBuilder {

    // MARK: - Public API

    /// Build tree nodes from events for visualization.
    /// - Parameters:
    ///   - events: Session events to build tree from
    ///   - headEventId: The current head event ID (marked as isHead)
    /// - Returns: Array of EventTreeNode in depth-first order
    static func buildTree(from events: [SessionEvent], headEventId: String?) -> [EventTreeNode] {
        guard !events.isEmpty else { return [] }

        let childrenMap = buildChildrenMap(from: events)
        var nodes: [EventTreeNode] = []

        func buildNode(_ event: SessionEvent, depth: Int) {
            let children = childrenMap[event.id] ?? []
            let isBranchPoint = children.count > 1

            nodes.append(EventTreeNode(
                id: event.id,
                parentId: event.parentId,
                type: event.type,
                timestamp: event.timestamp,
                summary: event.summary,
                hasChildren: !children.isEmpty,
                childCount: children.count,
                depth: depth,
                isBranchPoint: isBranchPoint,
                isHead: event.id == headEventId
            ))

            for child in children {
                buildNode(child, depth: depth + 1)
            }
        }

        // Start from root events (those with nil parentId)
        let roots = childrenMap[nil] ?? []
        for root in roots {
            buildNode(root, depth: 0)
        }

        return nodes
    }

    // MARK: - Helper Methods

    /// Build a map of parent ID to child events.
    /// - Parameter events: Events to organize
    /// - Returns: Dictionary mapping parentId (nil for roots) to child events
    static func buildChildrenMap(from events: [SessionEvent]) -> [String?: [SessionEvent]] {
        var childrenMap: [String?: [SessionEvent]] = [:]

        for event in events {
            var siblings = childrenMap[event.parentId] ?? []
            siblings.append(event)
            childrenMap[event.parentId] = siblings
        }

        return childrenMap
    }
}
